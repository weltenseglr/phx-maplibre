defmodule PhxMaplibre do
  @moduledoc """
  PubSub-first MapLibre GL JS integration for Phoenix LiveView.

  Render a map with `PhxMaplibre.Components.map/1`, wire it into its parent
  LiveView with `PhxMaplibre.LiveView`, and the two sides talk over
  Phoenix.PubSub from then on:

    * map interactions arrive as `%PhxMaplibre.Event{}` structs on the map's
      events topic, gated by the component's `events` whitelist;
    * commands sent through this module go out as `%PhxMaplibre.Command{}`
      structs on the map's commands topic, so any process can drive the map.

  ## Commands

  Every command comes in two forms:

    * `fly_to(map_id, center, opts)` broadcasts over PubSub. It works from any
      process — a GenServer, a task, another LiveView — and returns
      `:ok | {:error, reason}`.
    * `fly_to(socket, map_id, center, opts)` pushes straight to the browser
      from the LiveView that owns the map, bypassing PubSub, and returns the
      socket. Reach for it when the payload is large and the path is hot, say
      `set_features/3` with thousands of features every few seconds.

  ## Example

      # From anywhere:
      PhxMaplibre.fly_to("tracker-map", %{lng: 13.405, lat: 52.52},
        zoom: 13, pubsub: MyApp.PubSub)

      # Observe a map from any process:
      PhxMaplibre.subscribe("tracker-map", pubsub: MyApp.PubSub)
      # ... then handle %PhxMaplibre.Event{} messages.

  Set `config :phx_maplibre, pubsub: MyApp.PubSub` to omit the `:pubsub`
  option everywhere.
  """

  alias Phoenix.LiveView.Socket
  alias PhxMaplibre.{Command, Config, Geo, Topics}

  @typedoc "The map component's DOM id, used to derive its PubSub topics."
  @type map_id :: String.t()
  @typedoc "A GeoJSON FeatureCollection map, or a list of Feature maps."
  @type geojson :: map() | [map()]

  ## set_features

  @doc """
  Replaces the map's point features.

  `geojson` is a FeatureCollection (string or atom keys) or a list of
  Features. Give each point an `id` property — MapLibre tracks hover and
  selection state by it. Flat MapLibre paint properties on a feature (say
  `circle-color`) override the layer default for that feature alone.

  The shape is checked before anything is sent: anything that isn't one of
  those two returns `{:error, :invalid_geojson}` here, and raises
  `ArgumentError` in the socket form. Only the outer structure is checked —
  geometries are yours.

  At zooms at or above the component's `animate_min_zoom` (default `12`),
  consecutive updates render as smooth position transitions: features matched
  by `id` tween from where they were displayed to their new position over the
  measured interval between updates. See the README's "Animated updates"
  section.
  """
  @spec set_features(map_id(), geojson()) :: :ok | {:error, term()}
  def set_features(map_id, geojson) when is_binary(map_id),
    do: set_features(map_id, geojson, [])

  @doc """
  Broadcast form of `set_features/2`.

  `opts` accepts `:pubsub` and `:topic_prefix`; each falls back to the
  application configuration described in `PhxMaplibre.Config`.
  """
  @spec set_features(map_id(), geojson(), keyword()) :: :ok | {:error, term()}
  def set_features(map_id, geojson, opts) when is_binary(map_id) and is_list(opts),
    do: broadcast_command(map_id, :set_features, %{geojson: normalize_geojson(geojson)}, opts)

  @spec set_features(Socket.t(), map_id(), geojson()) :: Socket.t()
  def set_features(%Socket{} = socket, map_id, geojson),
    do: push_command(socket, map_id, :set_features, %{geojson: normalize_geojson(geojson)})

  ## set_area_features

  @doc """
  Replaces the map's area (polygon) features. Same `geojson` contract as
  `set_features/3`.
  """
  @spec set_area_features(map_id(), geojson()) :: :ok | {:error, term()}
  def set_area_features(map_id, geojson) when is_binary(map_id),
    do: set_area_features(map_id, geojson, [])

  @doc """
  Broadcast form of `set_area_features/2`.

  `opts` accepts `:pubsub` and `:topic_prefix`; each falls back to the
  application configuration described in `PhxMaplibre.Config`.
  """
  @spec set_area_features(map_id(), geojson(), keyword()) :: :ok | {:error, term()}
  def set_area_features(map_id, geojson, opts) when is_binary(map_id) and is_list(opts),
    do:
      broadcast_command(map_id, :set_area_features, %{geojson: normalize_geojson(geojson)}, opts)

  @spec set_area_features(Socket.t(), map_id(), geojson()) :: Socket.t()
  def set_area_features(%Socket{} = socket, map_id, geojson),
    do: push_command(socket, map_id, :set_area_features, %{geojson: normalize_geojson(geojson)})

  ## fly_to

  @doc """
  Flies the map to `center` (`%{lng: _, lat: _}`).

  Options: `:zoom` (default 14), `:duration` in ms (default 1500).
  """
  @spec fly_to(map_id(), %{lng: number(), lat: number()}) :: :ok | {:error, term()}
  def fly_to(map_id, center) when is_binary(map_id), do: fly_to(map_id, center, [])

  @doc """
  Broadcast form of `fly_to/2`.

  Alongside `:zoom` and `:duration`, `opts` accepts `:pubsub` and
  `:topic_prefix`; each falls back to application configuration.
  """
  @spec fly_to(map_id(), %{lng: number(), lat: number()}, keyword()) :: :ok | {:error, term()}
  def fly_to(map_id, center, opts) when is_binary(map_id) and is_list(opts),
    do: broadcast_command(map_id, :fly_to, fly_to_params(center, opts), opts)

  @spec fly_to(Socket.t(), map_id(), %{lng: number(), lat: number()}) :: Socket.t()
  def fly_to(%Socket{} = socket, map_id, center), do: fly_to(socket, map_id, center, [])

  @doc "Socket fast-path form of `fly_to/3`."
  @spec fly_to(Socket.t(), map_id(), %{lng: number(), lat: number()}, keyword()) :: Socket.t()
  def fly_to(%Socket{} = socket, map_id, center, opts),
    do: push_command(socket, map_id, :fly_to, fly_to_params(center, opts))

  ## fit_bounds

  @doc """
  Fits the map view to bounds.

  Takes explicit bounds (`%{west: _, south: _, east: _, north: _}`) or any
  GeoJSON value, which `PhxMaplibre.Geo.bounds/1` reduces to a bounding box —
  returning `{:error, :no_coordinates}` if the GeoJSON holds none.

  Options: `:padding` in px (default 40), `:max_zoom` (default 15).
  """
  @spec fit_bounds(map_id(), Geo.bounds() | geojson()) :: :ok | {:error, term()}
  def fit_bounds(map_id, bounds_or_geojson) when is_binary(map_id),
    do: fit_bounds(map_id, bounds_or_geojson, [])

  @doc """
  Broadcast form of `fit_bounds/2`.

  Alongside `:padding` and `:max_zoom`, `opts` accepts `:pubsub` and
  `:topic_prefix`; each falls back to application configuration.
  """
  @spec fit_bounds(map_id(), Geo.bounds() | geojson(), keyword()) :: :ok | {:error, term()}
  def fit_bounds(map_id, bounds_or_geojson, opts) when is_binary(map_id) and is_list(opts) do
    with {:ok, bounds} <- resolve_bounds(bounds_or_geojson) do
      broadcast_command(map_id, :fit_bounds, fit_bounds_params(bounds, opts), opts)
    end
  end

  @spec fit_bounds(Socket.t(), map_id(), Geo.bounds() | geojson()) :: Socket.t()
  def fit_bounds(%Socket{} = socket, map_id, bounds_or_geojson),
    do: fit_bounds(socket, map_id, bounds_or_geojson, [])

  @doc "Socket fast-path form of `fit_bounds/3`. Raises on GeoJSON without coordinates."
  @spec fit_bounds(Socket.t(), map_id(), Geo.bounds() | geojson(), keyword()) :: Socket.t()
  def fit_bounds(%Socket{} = socket, map_id, bounds_or_geojson, opts) do
    case resolve_bounds(bounds_or_geojson) do
      {:ok, bounds} ->
        push_command(socket, map_id, :fit_bounds, fit_bounds_params(bounds, opts))

      {:error, :no_coordinates} ->
        raise ArgumentError, "fit_bounds/4 got GeoJSON with no coordinates"
    end
  end

  ## set_style

  @doc """
  Switches the map's base style to the given style URL.

  Swapping the style discards everything the library added to it, so the hook
  re-adds its sources and layers, re-sets the current point and area data, and
  restores hover/selection state once the new style has loaded.
  """
  @spec set_style(map_id(), String.t()) :: :ok | {:error, term()}
  def set_style(map_id, style) when is_binary(map_id), do: set_style(map_id, style, [])

  @doc """
  Broadcast form of `set_style/2`.

  `opts` accepts `:pubsub` and `:topic_prefix`; each falls back to the
  application configuration described in `PhxMaplibre.Config`.
  """
  @spec set_style(map_id(), String.t(), keyword()) :: :ok | {:error, term()}
  def set_style(map_id, style, opts) when is_binary(map_id) and is_list(opts),
    do: broadcast_command(map_id, :set_style, %{style: style}, opts)

  @spec set_style(Socket.t(), map_id(), String.t()) :: Socket.t()
  def set_style(%Socket{} = socket, map_id, style),
    do: push_command(socket, map_id, :set_style, %{style: style})

  ## request_geolocation

  @doc """
  Asks the map to trigger the browser geolocation flow.

  The outcome comes back as a `:geolocation_success` or `:geolocation_error`
  event. This drives the geolocate control, so it only does something on a map
  rendered with `geolocation={true}`; on any other map it is a no-op.
  """
  @spec request_geolocation(map_id()) :: :ok | {:error, term()}
  def request_geolocation(map_id) when is_binary(map_id), do: request_geolocation(map_id, [])

  @doc """
  Broadcast form of `request_geolocation/1`.

  `opts` accepts `:pubsub` and `:topic_prefix`; each falls back to the
  application configuration described in `PhxMaplibre.Config`.
  """
  @spec request_geolocation(map_id(), keyword()) :: :ok | {:error, term()}
  def request_geolocation(map_id, opts) when is_binary(map_id) and is_list(opts),
    do: broadcast_command(map_id, :request_geolocation, %{}, opts)

  @spec request_geolocation(Socket.t(), map_id()) :: Socket.t()
  def request_geolocation(%Socket{} = socket, map_id),
    do: push_command(socket, map_id, :request_geolocation, %{})

  ## Subscriptions

  @doc """
  Subscribes the calling process to a map's events topic.

  From then on it receives `%PhxMaplibre.Event{}` messages. A LiveView that
  calls `PhxMaplibre.LiveView.attach_map/3` is subscribed already unless it
  passed `subscribe: false`; this is for every other process.
  """
  @spec subscribe(map_id(), keyword()) :: :ok | {:error, term()}
  def subscribe(map_id, opts \\ []) when is_binary(map_id) do
    Phoenix.PubSub.subscribe(
      Config.pubsub!(opts),
      Topics.events_topic(map_id, Config.topic_prefix(opts))
    )
  end

  @doc """
  Unsubscribes the calling process from a map's events topic.
  """
  @spec unsubscribe(map_id(), keyword()) :: :ok
  def unsubscribe(map_id, opts \\ []) when is_binary(map_id) do
    Phoenix.PubSub.unsubscribe(
      Config.pubsub!(opts),
      Topics.events_topic(map_id, Config.topic_prefix(opts))
    )
  end

  @doc """
  The events topic name for a map, with the configured prefix applied. See
  `PhxMaplibre.Topics`.
  """
  @spec events_topic(map_id(), keyword()) :: String.t()
  def events_topic(map_id, opts \\ []) when is_binary(map_id),
    do: Topics.events_topic(map_id, Config.topic_prefix(opts))

  @doc """
  The commands topic name for a map, with the configured prefix applied. See
  `PhxMaplibre.Topics`.
  """
  @spec commands_topic(map_id(), keyword()) :: String.t()
  def commands_topic(map_id, opts \\ []) when is_binary(map_id),
    do: Topics.commands_topic(map_id, Config.topic_prefix(opts))

  ## Internals

  defp broadcast_command(map_id, command, params, opts) do
    with {:ok, cmd} <- Command.new(map_id, command, params) do
      pubsub = Config.pubsub!(opts)
      prefix = Config.topic_prefix(opts)
      execute_telemetry(map_id, command)
      Phoenix.PubSub.broadcast(pubsub, Topics.commands_topic(map_id, prefix), cmd)
    end
  end

  defp push_command(socket, map_id, command, params) do
    cmd = Command.new!(map_id, command, params)
    execute_telemetry(map_id, command)
    Phoenix.LiveView.push_event(socket, "maplibre:#{map_id}:#{cmd.command}", cmd.params)
  end

  defp execute_telemetry(map_id, command) do
    :telemetry.execute(
      [:phx_maplibre, :command],
      %{system_time: System.system_time()},
      %{map_id: map_id, command: command}
    )
  end

  defp normalize_geojson(features) when is_list(features), do: Geo.feature_collection(features)
  # Anything else goes through untouched, for `PhxMaplibre.Command` to reject.
  defp normalize_geojson(geojson), do: geojson

  defp fly_to_params(center, opts) do
    %{
      center: center,
      zoom: Keyword.get(opts, :zoom, 14),
      duration: Keyword.get(opts, :duration, 1500)
    }
  end

  defp fit_bounds_params(bounds, opts) do
    %{
      bounds: bounds,
      padding: Keyword.get(opts, :padding, 40),
      max_zoom: Keyword.get(opts, :max_zoom, 15)
    }
  end

  defp resolve_bounds(%{west: _, south: _, east: _, north: _} = bounds), do: {:ok, bounds}
  defp resolve_bounds(geojson), do: Geo.bounds(geojson)
end
