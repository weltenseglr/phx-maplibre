defmodule DemoWeb.ExploreLive do
  @moduledoc false
  use DemoWeb, :live_view
  use PhxMaplibre.LiveView

  alias Demo.Map, as: MapCtx
  alias PhxMaplibre.Event

  @map_id_prefix "map-explore"
  @events [
    :ready,
    :move_end,
    :feature_selected,
    :feature_deselected,
    :cluster_selected,
    :geolocation_success,
    :geolocation_error
  ]

  @impl true
  def mount(_params, session, socket) do
    default_center = MapCtx.default_center()

    # One map id per viewer: PubSub topics are derived from it, so a fixed id
    # would make every connected viewer share this map's event and command
    # topics. The suffix is the cookie-session viewer id (stable across
    # reloads), with a random fallback for sessionless mounts (tests).
    suffix = session["viewer_id"] || Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    map_id = @map_id_prefix <> "-" <> suffix

    socket =
      socket
      |> assign(:map_id, map_id)
      |> assign(:events, @events)
      |> assign(:map_ready, false)
      |> assign(:geolocation_status, :pending)
      |> assign(:center, default_center)
      |> assign(:zoom, MapCtx.default_zoom())
      |> assign(:viewport, nil)
      |> assign(:point_features, [])
      |> assign(:selected_feature_id, nil)
      |> assign(:selected_feature, nil)
      |> assign(:detail_visible, false)
      |> assign(:geolocation_error, nil)
      |> stream(:feature_cards, [])
      |> PhxMaplibre.LiveView.attach_map(map_id, pubsub: Demo.PubSub)

    {:ok, socket}
  end

  ## Map events

  # The map id is per session, so events are matched against the assigns
  # rather than against a module attribute.
  @impl true
  def handle_info(%Event{map_id: map_id} = event, socket) do
    if map_id == socket.assigns.map_id do
      handle_map_event(event, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp handle_map_event(%Event{event: :ready}, socket) do
    center = socket.assigns.center

    {points, _areas} =
      MapCtx.search_by_center_radius(center.lat, center.lng, MapCtx.default_radius_m())

    socket =
      socket
      |> assign(:map_ready, true)
      |> put_features(points)
      |> push_features()
      |> PhxMaplibre.request_geolocation(socket.assigns.map_id)

    {:noreply, socket}
  end

  defp handle_map_event(
         %Event{
           event: :move_end,
           payload: %{bounds: %{north: north, east: east, south: south, west: west}} = payload
         },
         socket
       ) do
    {points, _areas} = MapCtx.search_by_bounds(north, east, south, west)

    center = payload[:center] || socket.assigns.center

    socket =
      socket
      |> assign(:center, %{lat: center[:lat], lng: center[:lng]})
      |> assign(:zoom, payload[:zoom] || socket.assigns.zoom)
      |> put_features(points)
      |> push_features()

    {:noreply, socket}
  end

  defp handle_map_event(%Event{event: :feature_selected, payload: payload}, socket) do
    id = payload[:id]
    updated = mark_selected(socket.assigns.point_features, id)

    socket =
      socket
      |> assign(:selected_feature_id, id)
      |> assign(:selected_feature, detail_from_payload(payload))
      |> assign(:detail_visible, true)
      |> assign(:point_features, updated)
      |> PhxMaplibre.set_features(socket.assigns.map_id, fc(updated))

    {:noreply, socket}
  end

  defp handle_map_event(%Event{event: :geolocation_success, payload: payload}, socket) do
    {points, _areas} =
      MapCtx.search_by_center_radius(payload[:lat], payload[:lng], MapCtx.default_radius_m())

    socket =
      socket
      |> assign(:geolocation_status, :success)
      |> assign(:center, %{lat: payload[:lat], lng: payload[:lng]})
      |> put_features(points)
      |> push_features()

    {:noreply, socket}
  end

  defp handle_map_event(%Event{event: :geolocation_error, payload: payload}, socket) do
    center = MapCtx.default_center()

    {points, _areas} =
      MapCtx.search_by_center_radius(center.lat, center.lng, MapCtx.default_radius_m())

    socket =
      socket
      |> assign(:geolocation_status, :error)
      |> assign(:geolocation_error, payload[:message] || "Geolocation unavailable")
      |> put_features(points)
      |> push_features()

    {:noreply, socket}
  end

  defp handle_map_event(%Event{}, socket), do: {:noreply, socket}

  ## UI events

  @impl true
  def handle_event("select_card", %{"id" => id}, socket) do
    feature = Enum.find(socket.assigns.point_features, fn f -> f[:id] == id end)

    socket =
      if feature do
        coords = feature[:geometry][:coordinates]
        props = feature[:properties]
        updated = mark_selected(socket.assigns.point_features, id)
        center = %{lat: Enum.at(coords, 1), lng: Enum.at(coords, 0)}

        socket
        |> assign(:selected_feature_id, id)
        |> assign(:selected_feature, %{
          "title" => props[:title],
          "subtitle" => props[:description],
          "kind" => props[:kind],
          "category" => props[:category],
          "lat" => center.lat,
          "lng" => center.lng
        })
        |> assign(:detail_visible, true)
        |> assign(:point_features, updated)
        |> PhxMaplibre.set_features(socket.assigns.map_id, fc(updated))
        |> PhxMaplibre.fly_to(socket.assigns.map_id, center, zoom: 15)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("close_detail", _params, socket) do
    updated = mark_selected(socket.assigns.point_features, nil)

    socket =
      socket
      |> assign(:selected_feature_id, nil)
      |> assign(:selected_feature, nil)
      |> assign(:detail_visible, false)
      |> assign(:point_features, updated)
      |> PhxMaplibre.set_features(socket.assigns.map_id, fc(updated))

    {:noreply, socket}
  end

  def handle_event("recenter", _params, socket) do
    {:noreply,
     PhxMaplibre.fly_to(socket, socket.assigns.map_id, socket.assigns.center,
       zoom: MapCtx.default_zoom()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fluid={true}>
      <div class="map-page">
        <section class="map-container-wrapper">
          <PhxMaplibre.Components.map
            id={@map_id}
            center={@center}
            zoom={@zoom}
            cluster={true}
            cluster_spiderfy_zoom={15}
            geolocation={true}
            navigation={true}
            events={@events}
            class="h-full w-full"
          />

          <button
            id="recenter-btn"
            phx-click="recenter"
            class="map-recenter-btn"
            aria-label="Recenter map"
          >
            <.icon name="hero-arrow-path" class="w-5 h-5" />
          </button>

          <%= if @geolocation_status == :error do %>
            <div class="map-geo-fallback">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              <span>Using default location (Berlin). Geolocation unavailable.</span>
            </div>
          <% end %>

          <%= if @detail_visible and @selected_feature do %>
            <div class="map-detail-panel" id="detail-panel">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="text-base font-bold">{@selected_feature["title"]}</h3>
                  <p class="text-sm opacity-70">{@selected_feature["subtitle"]}</p>
                </div>
                <button
                  phx-click="close_detail"
                  class="btn btn-ghost btn-sm btn-circle"
                  aria-label="Close details"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>
              <dl class="mt-4 grid grid-cols-2 gap-2 text-sm">
                <dt class="opacity-50">Type</dt>
                <dd class="font-medium uppercase">{@selected_feature["kind"]}</dd>
                <dt class="opacity-50">Category</dt>
                <dd class="font-medium capitalize">{@selected_feature["category"]}</dd>
                <dt class="opacity-50">Latitude</dt>
                <dd class="font-mono text-xs">{format_coordinate(@selected_feature["lat"])}</dd>
                <dt class="opacity-50">Longitude</dt>
                <dd class="font-mono text-xs">{format_coordinate(@selected_feature["lng"])}</dd>
              </dl>
            </div>
          <% end %>
        </section>

        <section class="map-sidebar">
          <div class="map-sidebar-header">
            <h2 class="text-lg font-bold">Venues & POIs</h2>
            <p class="text-sm opacity-70">
              {Enum.count(@streams.feature_cards.inserts)} places nearby
            </p>
          </div>

          <div
            id="feature-cards"
            phx-update="stream"
            class="map-card-list"
            role="list"
            tabindex="0"
            aria-label="Venue and POI list"
          >
            <div
              :for={{dom_id, card} <- @streams.feature_cards}
              id={dom_id}
              role="listitem"
              class={["map-card", @selected_feature_id == card.id && "map-card--selected"]}
              phx-click="select_card"
              phx-value-id={card.id}
              tabindex="0"
            >
              <div class="flex items-start gap-3">
                <span class={[
                  "map-card-icon",
                  card.kind == "venue" && "map-card-icon--venue",
                  card.kind == "poi" && "map-card-icon--poi"
                ]}>
                  <.icon name="hero-map-pin" class="w-4 h-4" />
                </span>
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-semibold truncate">{card.title}</p>
                  <p class="text-xs opacity-60 truncate">{card.description}</p>
                  <p class="text-xs opacity-50 mt-1 uppercase tracking-wide">{card.category}</p>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  ## Helpers

  # The mock data also carries coverage-area polygons; the explore page shows
  # only the points — the district polygons on /map stay the area showcase.
  defp put_features(socket, points) do
    socket
    |> assign(:point_features, points)
    |> stream(:feature_cards, build_feature_cards(points), reset: true)
  end

  defp push_features(socket) do
    PhxMaplibre.set_features(socket, socket.assigns.map_id, fc(socket.assigns.point_features))
  end

  defp detail_from_payload(payload) do
    props = get_in(payload, [:feature, "properties"]) || %{}

    %{
      "title" => props["title"],
      "subtitle" => props["description"],
      "kind" => props["kind"],
      "category" => props["category"],
      "lat" => payload[:lat],
      "lng" => payload[:lng]
    }
  end

  defp build_feature_cards(points) do
    Enum.map(points, fn f ->
      coords = f[:geometry][:coordinates]
      props = f[:properties]

      %{
        id: f[:id],
        title: props[:title],
        description: props[:description],
        kind: props[:kind],
        category: props[:category],
        lng: Enum.at(coords, 0),
        lat: Enum.at(coords, 1)
      }
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp fc(features), do: %{type: "FeatureCollection", features: features}

  defp format_coordinate(value) when is_float(value), do: Float.round(value, 4)
  defp format_coordinate(value) when is_integer(value), do: value
  defp format_coordinate(_value), do: "—"

  defp mark_selected(features, nil) do
    Enum.map(features, fn f -> put_in(f, [:properties, :selected], false) end)
  end

  defp mark_selected(features, selected_id) do
    Enum.map(features, fn f -> put_in(f, [:properties, :selected], f[:id] == selected_id) end)
  end
end
