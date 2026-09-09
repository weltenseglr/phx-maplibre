defmodule PhxMaplibre.Event do
  @moduledoc """
  A map interaction, as broadcast on the map's events topic.

  Subscribers — the owning LiveView among them — receive these structs in
  `handle_info/2` and sort them out by pattern matching:

      def handle_info(%PhxMaplibre.Event{event: :move_end, payload: %{bounds: bounds}}, socket) do
        ...
      end

  ## Events

  | event | payload |
  |---|---|
  | `:ready` | `%{bounds: bounds, center: center, zoom: zoom}` |
  | `:feature_selected` | `%{id: id, kind: "point" \\| "area", lng: lng, lat: lat, feature: geojson_feature}` |
  | `:feature_deselected` | `%{id: id, kind: kind}` |
  | `:feature_hovered` | `%{id: id, kind: kind, title: title}` |
  | `:feature_unhovered` | `%{id: id, kind: kind, title: title}` |
  | `:cluster_selected` | `%{cluster_id: id, point_count: n, center: %{lng: lng, lat: lat}}` |
  | `:move_end` | `%{bounds: %{west: w, south: s, east: e, north: n}, center: center, zoom: zoom}` |
  | `:geolocation_success` | `%{lng: lng, lat: lat, accuracy: accuracy}` |
  | `:geolocation_error` | `%{code: code, message: message}` |

  Hover events fire exactly once per transition. Dragging the pointer from
  feature A straight onto feature B emits `:feature_unhovered` for A strictly
  before `:feature_hovered` for B, and moving around inside one feature emits
  nothing at all.

  GeoJSON is the exchange format for feature data: `:feature_selected` hands
  you the clicked feature as a GeoJSON Feature under `:feature` — geometry and
  properties exactly as the map data provided them, string keys and all. For
  point clicks `lng`/`lat` are the feature's coordinates; for area clicks they
  are where the pointer hit. Hover events stay lightweight (`id`/`kind`/`title`)
  because they can fire often.

  Payload keys the library knows about are converted to atoms. Anything else
  keeps its string key, including everything under `:feature` — that map is
  the caller's own GeoJSON and is passed through as it came in. Key conversion
  stops eight levels down; deeper subtrees are passed through untouched, which
  is what they were headed for anyway.

  The required fields shown in the table are structurally validated before an
  event is broadcast. Extra payload keys remain available to consumers, but a
  malformed known event is rejected as `{:error, :invalid_payload}`.

  `meta` carries `%{pid: pid, at: DateTime.t()}`: which LiveView process
  relayed the event, and when.
  """

  @enforce_keys [:map_id, :event, :payload]
  defstruct [:map_id, :event, :payload, :meta]

  @typedoc "An interaction emitted by the browser hook."
  @type event_name ::
          :ready
          | :feature_selected
          | :feature_deselected
          | :feature_hovered
          | :feature_unhovered
          | :cluster_selected
          | :move_end
          | :geolocation_success
          | :geolocation_error

  @typedoc "A validated interaction broadcast from a single map's events topic."
  @type t :: %__MODULE__{
          map_id: String.t(),
          event: event_name(),
          payload: map(),
          meta: %{pid: pid(), at: DateTime.t()} | nil
        }

  @max_depth 8

  @client_events %{
    "ready" => :ready,
    "feature_selected" => :feature_selected,
    "feature_deselected" => :feature_deselected,
    "feature_hovered" => :feature_hovered,
    "feature_unhovered" => :feature_unhovered,
    "cluster_selected" => :cluster_selected,
    "move_end" => :move_end,
    "geolocation_success" => :geolocation_success,
    "geolocation_error" => :geolocation_error
  }

  @default_event_names [
    :ready,
    :feature_selected,
    :feature_deselected,
    :cluster_selected,
    :move_end,
    :geolocation_success,
    :geolocation_error
  ]

  @payload_keys %{
    "bounds" => :bounds,
    "center" => :center,
    "zoom" => :zoom,
    "west" => :west,
    "south" => :south,
    "east" => :east,
    "north" => :north,
    "lng" => :lng,
    "lat" => :lat,
    "id" => :id,
    "kind" => :kind,
    "title" => :title,
    "properties" => :properties,
    "feature" => :feature,
    "cluster_id" => :cluster_id,
    "point_count" => :point_count,
    "accuracy" => :accuracy,
    "code" => :code,
    "message" => :message
  }

  @doc """
  Every event name the library accepts from the client, as atoms.
  """
  @spec event_names() :: [event_name()]
  def event_names, do: Map.values(@client_events)

  @doc """
  The conservative default event allowlist used by both the component and
  `PhxMaplibre.LiveView.attach_map/3`.

  Hover events are intentionally opt-in because they can be frequent.
  """
  @spec default_event_names() :: [event_name()]
  def default_event_names, do: @default_event_names

  @doc """
  Builds an event from the raw client wire format.

  `event_name` is checked against the compile-time allowlist and known payload
  keys are turned into atoms. Anything outside the allowlist comes back as
  `{:error, :unknown_event}`; no atom is ever created from client input.
  """
  @spec from_client(String.t(), String.t(), map()) ::
          {:ok, t()} | {:error, :unknown_event | :invalid_payload}
  def from_client(map_id, event_name, payload)
      when is_binary(map_id) and is_binary(event_name) and is_map(payload) do
    case Map.fetch(@client_events, event_name) do
      {:ok, event} ->
        payload = normalize_payload(payload, 1)

        if valid_payload?(event, payload) do
          {:ok,
           %__MODULE__{
             map_id: map_id,
             event: event,
             payload: payload,
             meta: %{pid: self(), at: DateTime.utc_now()}
           }}
        else
          {:error, :invalid_payload}
        end

      :error ->
        {:error, :unknown_event}
    end
  end

  def from_client(_map_id, _event_name, _payload), do: {:error, :unknown_event}

  defp valid_payload?(:ready, %{bounds: bounds, center: center, zoom: zoom}),
    do: bounds?(bounds) and center?(center) and is_number(zoom)

  defp valid_payload?(:feature_selected, %{id: id, kind: kind, lng: lng, lat: lat, feature: feature}),
    do: feature_id?(id) and kind?(kind) and is_number(lng) and is_number(lat) and is_map(feature)

  defp valid_payload?(:feature_deselected, %{id: id, kind: kind}),
    do: feature_id?(id) and kind?(kind)

  defp valid_payload?(event, %{id: id, kind: kind, title: title})
       when event in [:feature_hovered, :feature_unhovered],
       do: feature_id?(id) and kind?(kind) and (is_binary(title) or is_nil(title))

  defp valid_payload?(:cluster_selected, %{cluster_id: id, point_count: count, center: center}),
    do: feature_id?(id) and is_number(count) and center?(center)

  defp valid_payload?(:move_end, %{bounds: bounds, center: center, zoom: zoom}),
    do: bounds?(bounds) and center?(center) and is_number(zoom)

  defp valid_payload?(:geolocation_success, %{lng: lng, lat: lat, accuracy: accuracy}),
    do: is_number(lng) and is_number(lat) and is_number(accuracy)

  defp valid_payload?(:geolocation_error, %{code: code, message: message}),
    do: is_integer(code) and is_binary(message)

  defp valid_payload?(_event, _payload), do: false

  defp bounds?(%{west: west, south: south, east: east, north: north}),
    do: Enum.all?([west, south, east, north], &is_number/1)

  defp bounds?(_bounds), do: false
  defp center?(%{lng: lng, lat: lat}), do: is_number(lng) and is_number(lat)
  defp center?(_center), do: false
  defp feature_id?(id), do: is_binary(id) or is_number(id)
  defp kind?(kind), do: kind in ["point", "area"]

  defp normalize_payload(payload, depth) when is_map(payload) do
    Map.new(payload, fn
      {key, value} when is_binary(key) ->
        case Map.fetch(@payload_keys, key) do
          # :feature and :properties hold user GeoJSON — keep their keys untouched
          {:ok, :feature} -> {:feature, value}
          {:ok, :properties} -> {:properties, value}
          {:ok, atom} -> {atom, normalize_value(value, depth)}
          :error -> {key, value}
        end

      {key, value} ->
        {key, value}
    end)
  end

  # Client input, so the walk is bounded: past @max_depth the subtree is data
  # either way and goes through as it came in.
  defp normalize_value(value, depth) when is_map(value) and depth < @max_depth,
    do: normalize_payload(value, depth + 1)

  defp normalize_value(value, _depth), do: value
end
