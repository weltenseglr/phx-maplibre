defmodule GsdTrackerWeb.MapLive do
  @moduledoc false

  use GsdTrackerWeb, :live_view
  use PhxMaplibre.LiveView

  require Logger

  alias GsdTracker.GSD
  alias GsdTracker.Repo
  alias GsdTracker.Tracking
  alias GsdTrackerWeb.Components.StatsSidebar

  @map_id_prefix "map-tracker"
  # Accent and page ink from assets/css/app.css, mirrored here because the pin
  # colors travel to the browser as GeoJSON feature properties, not as CSS.
  @pin_color "#e08878"
  @pin_stroke_color "#1a1d26"
  @topic "gsd_updates"
  @center %{lng: 13.405, lat: 52.52}
  @zoom 11

  @impl true
  def mount(_params, session, socket) do
    # One map id per viewer. PubSub topics are derived from the map id, so a
    # shared id would put every connected viewer on the same topics: one
    # viewer's viewport-filtered `set_features` would overwrite everyone
    # else's map, and every map event would be delivered to every session.
    # The suffix is the cookie-session viewer id (stable across reloads and
    # reconnects), with a random fallback for sessionless mounts (tests).
    suffix = session["viewer_id"] || Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    map_id = @map_id_prefix <> "-" <> suffix

    socket =
      socket
      |> assign(:page_title, "GSD Tracker")
      |> assign(:map_id, map_id)
      |> assign(:center, @center)
      |> assign(:zoom, @zoom)
      |> assign(:viewport_bounds, nil)
      |> assign(:all_positions, [])
      |> assign(:stats, empty_stats())
      |> assign(:selected_gsd, nil)
      |> assign(:gsd_detail, nil)
      |> assign(:map_ready, false)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(GsdTracker.PubSub, @topic)

      socket =
        socket
        |> PhxMaplibre.LiveView.attach_map(map_id, pubsub: GsdTracker.PubSub)
        |> assign(:all_positions, Tracking.latest_positions())

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-full min-h-0 w-full flex-1 flex-col lg:flex-row">
        <div class="h-1/2 w-full lg:h-full lg:w-2/3">
          <PhxMaplibre.Components.map
            id={@map_id}
            center={@center}
            zoom={@zoom}
            cluster_color={pin_color()}
            class="h-full w-full"
          />
        </div>

        <aside
          aria-label="Fleet monitoring console"
          class="gsd-scroll h-1/2 w-full overflow-y-auto border-t border-accent/60 bg-ink p-4 lg:h-full lg:w-1/3 lg:border-l lg:border-t-0"
        >
          <StatsSidebar.stats_sidebar stats={@stats} />
          <StatsSidebar.gsd_detail :if={@gsd_detail} detail={@gsd_detail} />
        </aside>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:update, %{positions: positions, stats: stats}}, socket) do
    socket =
      socket
      |> assign(:all_positions, positions)
      |> assign(:stats, stats)
      |> refresh_detail(positions)
      |> push_positions()

    {:noreply, socket}
  end

  def handle_info(%PhxMaplibre.Event{event: :ready, payload: %{bounds: bounds}}, socket) do
    socket =
      socket
      |> assign(:map_ready, true)
      |> assign(:viewport_bounds, normalize_bounds(bounds))
      |> push_positions()

    {:noreply, socket}
  end

  def handle_info(%PhxMaplibre.Event{event: :move_end, payload: %{bounds: bounds}}, socket) do
    socket =
      socket
      |> assign(:viewport_bounds, normalize_bounds(bounds))
      |> push_positions()

    {:noreply, socket}
  end

  def handle_info(%PhxMaplibre.Event{event: :feature_selected, payload: %{id: id}}, socket) do
    {selected_gsd, gsd_detail} = fetch_gsd_detail(id)

    socket =
      socket
      |> assign(:selected_gsd, selected_gsd)
      |> assign(:gsd_detail, gsd_detail)

    {:noreply, socket}
  end

  def handle_info(%PhxMaplibre.Event{event: :feature_deselected}, socket) do
    socket =
      socket
      |> assign(:selected_gsd, nil)
      |> assign(:gsd_detail, nil)

    {:noreply, socket}
  end

  def handle_info(%PhxMaplibre.Event{}, socket), do: {:noreply, socket}

  def handle_info(message, socket) do
    Logger.debug("MapLive: ignoring unexpected message: #{inspect(message)}")
    {:noreply, socket}
  end

  ## Feature pushing

  defp push_positions(%{assigns: %{map_ready: false}} = socket), do: socket

  defp push_positions(socket) do
    features =
      socket.assigns.all_positions
      |> filter_by_viewport(socket.assigns.viewport_bounds)
      |> positions_to_geojson()

    # Deliberately uses the PubSub command form rather than the faster
    # socket form (set_features/4): this demo exists to show that any BEAM
    # process can drive the map through PubSub alone. The map id is
    # per session, so the broadcast reaches only this LiveView.
    PhxMaplibre.set_features(socket.assigns.map_id, features, pubsub: GsdTracker.PubSub)

    socket
  end

  defp filter_by_viewport(positions, nil), do: positions

  defp filter_by_viewport(positions, bounds) do
    Enum.filter(positions, fn position ->
      PhxMaplibre.Geo.within?(%{lng: position.lng, lat: position.lat}, bounds)
    end)
  end

  defp positions_to_geojson(positions) do
    %{type: "FeatureCollection", features: Enum.map(positions, &position_to_feature/1)}
  end

  defp position_to_feature(position) do
    status = normalize_status(position.status)

    properties = %{
      # Presentation only. The library's point layer prefers a feature's own
      # style property over its default (see priv/js/sources_layers.js), so
      # the units render in the portal's accent instead of the default
      # indigo-on-white, without touching the map component or its attrs.
      "circle-color" => @pin_color,
      "circle-stroke-color" => @pin_stroke_color,
      "circle-stroke-width" => 1.5,
      "circle-radius" => 5,
      id: position.gsd_id,
      kind: "gsd",
      title: "GSD " <> short_id(position.gsd_id),
      description: humanize(status),
      status: Atom.to_string(status),
      flock_id: position.flock_id,
      speed_kmh: round_number(Map.get(position, :speed_kmh)),
      bearing: bearing(Map.get(position, :movement_vector))
    }

    # The library's selection behavior also flags the feature named by
    # "linked-id" (the partner) with a `linked` feature-state.
    properties =
      case Map.get(position, :partner_id) do
        nil -> properties
        partner_id -> Map.put(properties, "linked-id", partner_id)
      end

    %{
      type: "Feature",
      id: position.gsd_id,
      geometry: %{
        type: "Point",
        coordinates: [round_coordinate(position.lng), round_coordinate(position.lat)]
      },
      properties: properties
    }
  end

  # One source of truth for the accent that reaches the map: module attributes
  # are not readable as `@pin_color` inside ~H (that namespace is assigns).
  defp pin_color, do: @pin_color

  defp round_coordinate(value), do: Float.round(to_float(value) || 0.0, 6)

  defp round_number(nil), do: nil

  defp round_number(value) do
    case to_float(value) do
      nil -> nil
      float -> Float.round(float, 1)
    end
  end

  defp bearing(%{} = vector) do
    lat = vector_component(vector, :lat)
    lng = vector_component(vector, :lng)

    cond do
      is_nil(lat) or is_nil(lng) -> nil
      lat == 0.0 and lng == 0.0 -> nil
      true -> Float.round(normalize_degrees(:math.atan2(lng, lat) * 180.0 / :math.pi()), 1)
    end
  end

  defp bearing(_vector), do: nil

  defp normalize_degrees(degrees) do
    degrees
    |> Kernel.+(360.0)
    |> :math.fmod(360.0)
  end

  defp vector_component(vector, key) do
    vector
    |> Map.get(key, Map.get(vector, Atom.to_string(key)))
    |> to_float()
  end

  ## Selection

  defp refresh_detail(%{assigns: %{gsd_detail: nil}} = socket, _positions), do: socket

  defp refresh_detail(socket, positions) do
    selected = to_string(socket.assigns.selected_gsd)

    case Enum.find(positions, &(to_string(&1.gsd_id) == selected)) do
      nil ->
        socket

      position ->
        movement_vector = Map.get(position, :movement_vector)

        detail =
          Map.merge(socket.assigns.gsd_detail, %{
            status: normalize_status(position.status),
            speed_kmh: to_float(Map.get(position, :speed_kmh)),
            movement_vector: movement_vector,
            bearing: bearing(movement_vector),
            last_update_at: Map.get(position, :last_update_at)
          })

        assign(socket, :gsd_detail, detail)
    end
  end

  defp fetch_gsd_detail(gsd_id) do
    GSD
    |> Ash.Query.for_read(:by_id, %{id: gsd_id})
    |> Ash.read_one(domain: GsdTracker.Ash)
    |> case do
      {:ok, nil} ->
        {nil, nil}

      {:ok, gsd} ->
        {gsd.id, build_detail(gsd)}

      {:error, error} ->
        Logger.debug("fetch_gsd_detail/1 failed for #{inspect(gsd_id)}: #{inspect(error)}")
        {nil, nil}
    end
  rescue
    error ->
      Logger.debug("fetch_gsd_detail/1 raised for #{inspect(gsd_id)}: #{inspect(error)}")
      {nil, nil}
  end

  defp build_detail(gsd) do
    %{
      gsd_id: gsd.id,
      title: "GSD " <> short_id(gsd.id),
      status: normalize_status(gsd.status),
      speed_kmh: to_float(gsd.speed_kmh),
      movement_vector: nil,
      bearing: nil,
      total_distance_m: total_distance_m(gsd.id),
      service_time: service_time(gsd.commissioning_date),
      last_update_at: nil,
      flock_id: gsd.flock_id,
      partner_id: gsd.partner_id
    }
  end

  @total_distance_sql """
  SELECT COALESCE(SUM(distance), 0)
  FROM (
    SELECT ST_DistanceSphere(
             location,
             lag(location) OVER (PARTITION BY gsd_id ORDER BY timestamp)
           ) AS distance
    FROM gsd_stats
    WHERE gsd_id = $1
  ) distances
  """

  defp total_distance_m(gsd_id) do
    with {:ok, uuid} <- uuid_param(gsd_id),
         {:ok, %{rows: [[distance]]}} <- Repo.query(@total_distance_sql, [uuid]) do
      to_float(distance) || 0.0
    else
      _other -> 0.0
    end
  rescue
    error ->
      Logger.debug("total_distance_m/1 raised for #{inspect(gsd_id)}: #{inspect(error)}")
      0.0
  end

  defp uuid_param(<<_::128>> = uuid), do: {:ok, uuid}
  defp uuid_param(uuid) when is_binary(uuid), do: Ecto.UUID.dump(uuid)
  defp uuid_param(_uuid), do: :error

  defp service_time(nil), do: "0d 0h"

  defp service_time(%DateTime{} = commissioning_date) do
    DateTime.utc_now()
    |> DateTime.diff(commissioning_date, :second)
    |> max(0)
    |> format_service_time()
  end

  defp service_time(_commissioning_date), do: "0d 0h"

  defp format_service_time(seconds) do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)
    "#{days}d #{hours}h"
  end

  ## Shared helpers

  defp normalize_bounds(%{} = bounds) do
    %{
      north: bounds_value(bounds, :north),
      south: bounds_value(bounds, :south),
      east: bounds_value(bounds, :east),
      west: bounds_value(bounds, :west)
    }
  end

  defp normalize_bounds(_bounds), do: nil

  defp bounds_value(bounds, key) do
    value =
      bounds
      |> Map.get(key, Map.get(bounds, Atom.to_string(key)))
      |> to_float()

    value || 0.0
  end

  defp normalize_status(nil), do: :unknown
  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> :unknown
  end

  defp normalize_status(_status), do: :unknown

  defp humanize(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp short_id(nil), do: "?"
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp to_float(nil), do: nil
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp to_float(_value), do: nil

  defp empty_stats do
    %{
      total: 0,
      couples: 0,
      flocks: 0,
      largest_flock: 0,
      smallest_flock: 0,
      avg_flock_size: 0,
      by_state: %{
        ground: %{maintenance: 0, charging: 0, surveillance: 0, simulating: 0},
        flight: %{target_tracking: 0, aerial_surveillance: 0, moving_to_new_target: 0}
      }
    }
  end
end
