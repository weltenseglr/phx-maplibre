defmodule DemoWeb.MapLive do
  @moduledoc false
  use DemoWeb, :live_view
  use PhxMaplibre.LiveView

  alias Demo.Map, as: MapCtx
  alias Demo.Map.BerlinDistricts
  alias PhxMaplibre.Event

  @geolocation_map_id_prefix "map-geolocation"
  @pois_map_id_prefix "map-pois"
  @districts_map_id_prefix "map-districts"

  @geolocation_events [:ready, :geolocation_success, :geolocation_error]
  @pois_events [:ready, :feature_selected, :feature_deselected, :cluster_selected]
  @districts_events [
    :ready,
    :feature_selected,
    :feature_deselected,
    :feature_hovered,
    :feature_unhovered
  ]

  @impl true
  def mount(_params, session, socket) do
    default_center = MapCtx.default_center()

    poi_features =
      MapCtx.MockData.all_pois()
      |> Enum.map(&MapCtx.MockData.to_point_feature/1)

    {berlin_areas, berlin_error} =
      case BerlinDistricts.fetch() do
        {:ok, areas} -> {areas, nil}
        {:error, reason} -> {[], format_error(reason)}
      end

    # One set of map ids per viewer. PubSub topics are derived from the map
    # id, so fixed ids would put every connected viewer on the same topics:
    # commands meant for one viewer's map would drive everyone's, and every
    # map event would be delivered to every session. The suffix comes from the
    # cookie session (see DemoWeb.Router.ensure_viewer_id/2), so it is stable
    # across reloads and reconnects for one browser while staying unique per
    # viewer; the random fallback covers mounts without a session (tests).
    viewer_id =
      session["viewer_id"] || Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    suffix = viewer_id
    geolocation_map_id = @geolocation_map_id_prefix <> "-" <> suffix
    pois_map_id = @pois_map_id_prefix <> "-" <> suffix
    districts_map_id = @districts_map_id_prefix <> "-" <> suffix

    socket =
      socket
      |> assign(:geolocation_map_id, geolocation_map_id)
      |> assign(:pois_map_id, pois_map_id)
      |> assign(:districts_map_id, districts_map_id)
      |> assign(:geolocation_events, @geolocation_events)
      |> assign(:pois_events, @pois_events)
      |> assign(:districts_events, @districts_events)
      |> assign(:default_center, default_center)
      |> assign(:poi_features, poi_features)
      |> assign(:berlin_areas, berlin_areas)
      |> assign(:berlin_error, berlin_error)
      |> assign(:district_hover_events, [])
      |> assign(:district_hover_event_count, 0)
      |> assign(:viewer_id, viewer_id)
      |> PhxMaplibre.LiveView.attach_map(geolocation_map_id,
        pubsub: Demo.PubSub,
        events: @geolocation_events
      )
      |> PhxMaplibre.LiveView.attach_map(pois_map_id, pubsub: Demo.PubSub, events: @pois_events)
      |> PhxMaplibre.LiveView.attach_map(districts_map_id,
        pubsub: Demo.PubSub,
        events: @districts_events
      )

    {:ok, socket}
  end

  # The ids are per session, so which map an event belongs to is resolved
  # against the assigns rather than matched on a module attribute.
  @impl true
  def handle_info(%Event{map_id: map_id} = event, socket) do
    handle_map_event(map_role(socket, map_id), event, socket)
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp map_role(socket, map_id) do
    cond do
      map_id == socket.assigns.pois_map_id -> :pois
      map_id == socket.assigns.districts_map_id -> :districts
      map_id == socket.assigns.geolocation_map_id -> :geolocation
      true -> :unknown
    end
  end

  defp handle_map_event(:pois, %Event{event: :ready}, socket) do
    {:noreply,
     PhxMaplibre.set_features(socket, socket.assigns.pois_map_id, socket.assigns.poi_features)}
  end

  defp handle_map_event(:districts, %Event{event: :ready}, socket) do
    areas = socket.assigns.berlin_areas
    districts_map_id = socket.assigns.districts_map_id

    socket = PhxMaplibre.set_area_features(socket, districts_map_id, areas)

    socket =
      if areas == [] do
        socket
      else
        PhxMaplibre.fit_bounds(socket, districts_map_id, areas, padding: 24)
      end

    {:noreply, socket}
  end

  # The geolocation map has nothing to push on ready — the GeolocateControl
  # renders the user position itself.
  defp handle_map_event(:geolocation, %Event{event: :ready}, socket) do
    {:noreply, socket}
  end

  # Hover test harness: records the exact-once hover transition contract so the
  # Playwright spec can assert on it.
  defp handle_map_event(:districts, %Event{event: event, payload: payload}, socket)
       when event in [:feature_hovered, :feature_unhovered] do
    hover_event = %{event: Atom.to_string(event), payload: payload}
    events = Enum.take(socket.assigns.district_hover_events ++ [hover_event], -3)

    {:noreply,
     socket
     |> assign(:district_hover_events, events)
     |> update(:district_hover_event_count, &(&1 + 1))}
  end

  defp handle_map_event(_role, %Event{}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fluid={true}>
      <div class="map-showcase">
        <div class="map-showcase-header">
          <h1 class="text-2xl font-bold">MapLibre + Phoenix LiveView</h1>
          <p class="text-sm opacity-70 mt-1">
            Three independent map instances — each with its own PubSub event and command scope.
          </p>
        </div>

        <div class="map-grid">
          <div class="map-card">
            <div class="map-card-header">
              <h2 class="text-sm font-semibold">Your Location</h2>
              <p class="text-xs opacity-60">Blank map, geolocates on load</p>
            </div>
            <div class="map-card-body">
              <PhxMaplibre.Components.map
                id={@geolocation_map_id}
                center={@default_center}
                zoom={14.0}
                cluster={false}
                geolocation={true}
                navigation={true}
                events={@geolocation_events}
                class="h-full w-full"
              />
            </div>
          </div>

          <div class="map-card">
            <div class="map-card-header">
              <h2 class="text-sm font-semibold">POIs in Berlin</h2>
              <p class="text-xs opacity-60">{length(@poi_features)} points of interest</p>
            </div>
            <div class="map-card-body">
              <PhxMaplibre.Components.map
                id={@pois_map_id}
                center={@default_center}
                zoom={11.0}
                cluster={true}
                geolocation={false}
                navigation={true}
                events={@pois_events}
                class="h-full w-full"
              />
            </div>
          </div>

          <div class="map-card">
            <div class="map-card-header">
              <h2 class="text-sm font-semibold">Berlin Districts</h2>
              <p class="text-xs opacity-60">
                <%= if @berlin_error do %>
                  Failed to load ({@berlin_error})
                <% else %>
                  {length(@berlin_areas)} district polygons
                <% end %>
              </p>
            </div>
            <div class="map-card-body">
              <PhxMaplibre.Components.map
                id={@districts_map_id}
                center={@default_center}
                zoom={10.0}
                cluster={false}
                geolocation={false}
                navigation={true}
                events={@districts_events}
                class="h-full w-full"
              />
              <pre id="district-hover-events" class="hidden">{Jason.encode!(@district_hover_events)}</pre>
              <div id="district-hover-event-count" class="hidden">{@district_hover_event_count}</div>
            </div>
          </div>
        </div>

        <div class="map-showcase-footer">
          <div class="text-xs font-mono opacity-60" id="viewer-session-id">
            Viewer session: {@viewer_id}
          </div>

          <.link navigate={~p"/explore"} class="btn btn-primary btn-sm">
            Full interactive map <span aria-hidden="true">&rarr;</span>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
