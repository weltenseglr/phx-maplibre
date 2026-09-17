defmodule PhxMaplibre.Components do
  @moduledoc """
  Function components for rendering MapLibre maps.

  The map lives in the browser behind `phx-update="ignore"`, so the component
  renders once: a container div and the JSON configuration the hook reads at
  mount. Nothing after that arrives by re-rendering — see
  `PhxMaplibre.LiveView` for wiring up the parent LiveView and `PhxMaplibre`
  for driving the map afterwards.
  """

  use Phoenix.Component

  @default_events PhxMaplibre.Event.default_event_names()

  @doc """
  Renders the explicitly enabled shared editor's companion panel.

  Import `phx_maplibre/editor`, register `PhxMaplibreEditorHook`, and call
  `PhxMaplibre.LiveView.attach_editor/3` separately. The ordinary map component
  does not include or initialize editor code.
  """
  attr :id, :string, required: true
  attr :map_id, :string, required: true
  attr :config, :map, default: %{}
  attr :class, :any, default: nil
  slot :inner_block

  def editor(assigns), do: PhxMaplibre.Editor.Components.editor(assigns)

  @doc """
  Renders a MapLibre map container.

  Two things have to be in place for it to come alive: the `PhxMaplibreHook`
  JS hook registered on the LiveSocket (`createMapHook` in the `phx_maplibre`
  npm package), and a parent LiveView that does `use PhxMaplibre.LiveView` and
  calls `PhxMaplibre.LiveView.attach_map/3` with this same `id`.

  ## Browser readiness

  The hook initializes these DOM attributes to `"false"`:

    * `data-map-hook-ready` becomes `"true"` after the map and command handlers exist.
    * `data-map-style-ready` becomes `"true"` after custom sources, layers and
      interactions exist. It resets during command/theme style replacement.
    * `data-map-loaded` records the initial MapLibre `load` event. It is a
      milestone, not the continuously changing `map.loaded()` predicate.
    * `data-map-points-present` reflects whether the latest point collection is
      nonempty; it does not imply that a feature has rendered.

  `data-map-lifecycle` distinguishes `mounting`, `mounted`, `style-loading`,
  `error`, and `destroyed`; `data-map-mount-count` counts mounts of this element,
  and `data-map-error` records the latest setup/resource error (reset on remount).
  Setup exceptions record diagnostics and are logged without breaking LiveView.

  All flags reset on destruction. On a mounted container,
  the exported `getMapHandle(element)` returns a frozen handle exposing the
  MapLibre `map` and a read-only `pointsData` getter. It returns `null` before
  successful mounting and after destruction. Reacquire after remount. Treat the
  returned feature collection as read-only. Wait for style readiness before querying layers, then poll `queryRenderedFeatures`
  for the specific actionable layer needed by the test. LiveView connectivity
  and application update receipt are separate application states.

  Browser extensions can listen for the bubbling DOM event
  `phx-maplibre:style-changing` on the container. It fires synchronously before
  a command or theme change replaces the style, while existing layers still
  exist. Detach extension layers then, and reattach when `data-map-style-ready`
  becomes `"true"` again.

  ## Example

      <PhxMaplibre.Components.map
        id="berlin-map"
        center={%{lng: 13.405, lat: 52.52}}
        zoom={11}
        events={[:ready, :move_end, :feature_selected, :feature_deselected]}
        class="h-full w-full rounded-lg"
      />

  `events` is an opt-in whitelist: an event the list omits never leaves the
  browser. `:feature_hovered` and `:feature_unhovered` are missing from the
  default list — add them when you want hover events. It gates the browser
  only, so pass the same list to `PhxMaplibre.LiveView.attach_map/3` to gate
  the server side too.

  `center`, `zoom`, `events`, and `move_end_throttle_ms` are checked before
  they are serialized; a wrong value raises `ArgumentError` naming the
  attribute rather than failing later inside the JSON encoder.
  """
  attr :id, :string, required: true, doc: "DOM id; also the map id used in topics and events"

  attr :center, :map,
    default: %{lng: 13.405, lat: 52.52},
    doc: "initial center, %{lng: _, lat: _}"

  attr :zoom, :any, default: 11, doc: "initial zoom level"

  attr :light_style, :string,
    default: "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json",
    doc: "style URL used whenever the dark style does not apply"

  attr :dark_style, :string,
    default: "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json",
    doc:
      ~s(style URL used when the document root has data-theme="dark", or has no data-theme and the OS prefers dark)

  attr :cluster, :boolean, default: true, doc: "cluster point features"

  attr :cluster_spiderfy_zoom, :any,
    default: nil,
    doc: "zoom at/above which cluster clicks spiderfy instead of zooming; nil disables"

  attr :cluster_color, :string,
    default: nil,
    doc:
      "single color for cluster bubbles (count text goes dark); when unset " <>
        "the built-in size-stepped palette is used"

  attr :animate_min_zoom, :any,
    default: 12,
    doc:
      "zoom at/above which point features render with animated position " <>
        "transitions between `set_features` updates (below it the clustered " <>
        "snapshot renders); `false` (or `nil`) disables animation"

  attr :navigation, :boolean, default: true, doc: "show the navigation control"
  attr :geolocation, :boolean, default: false, doc: "show the geolocate control"

  attr :fly_on_geolocate, :boolean,
    default: true,
    doc: "fly to the user's position on geolocation success"

  attr :events, :list,
    default: @default_events,
    doc: "opt-in whitelist of events the map publishes; see `PhxMaplibre.Event`"

  attr :move_end_throttle_ms, :integer,
    default: 1000,
    doc: "shortest gap, in ms, between two `move_end` events"

  attr :class, :any, default: nil, doc: "extra classes for the container"
  attr :rest, :global

  def map(assigns) do
    validate!(assigns)

    ~H"""
    <div
      id={@id}
      phx-hook="PhxMaplibreHook"
      phx-update="ignore"
      class={["phx-maplibre", @class]}
      data-config={config_json(assigns)}
      {@rest}
    >
    </div>
    """
  end

  # Everything here ends up in a JSON attribute the hook reads, so a bad value
  # would surface as a Jason.EncodeError or an Enum crash from inside a
  # template. Say which attribute is wrong instead.
  defp validate!(assigns) do
    case assigns.events do
      events when is_list(events) ->
        if not Enum.all?(events, &is_atom/1), do: bad!(:events, assigns.events, "a list of atoms")

      other ->
        bad!(:events, other, "a list of atoms")
    end

    case assigns.center do
      %{lng: lng, lat: lat} when is_number(lng) and is_number(lat) ->
        :ok

      other ->
        bad!(:center, other, "%{lng: number, lat: number}")
    end

    if not is_number(assigns.zoom), do: bad!(:zoom, assigns.zoom, "a number")

    if not is_number(assigns.move_end_throttle_ms),
      do: bad!(:move_end_throttle_ms, assigns.move_end_throttle_ms, "a number")

    case assigns.animate_min_zoom do
      value when is_number(value) -> :ok
      disabled when disabled in [false, nil] -> :ok
      other -> bad!(:animate_min_zoom, other, "a number, or false to disable")
    end

    case assigns.cluster_spiderfy_zoom do
      value when is_number(value) -> :ok
      disabled when disabled in [false, nil] -> :ok
      other -> bad!(:cluster_spiderfy_zoom, other, "a number, or nil to disable")
    end

    :ok
  end

  defp bad!(attr, value, expected) do
    raise ArgumentError,
          "PhxMaplibre.Components.map/1: #{attr} must be #{expected}, got: #{inspect(value)}"
  end

  defp config_json(assigns) do
    Jason.encode!(%{
      center: assigns.center,
      zoom: assigns.zoom,
      lightStyle: assigns.light_style,
      darkStyle: assigns.dark_style,
      cluster: assigns.cluster,
      clusterSpiderfyZoom: assigns.cluster_spiderfy_zoom || false,
      clusterColor: assigns.cluster_color,
      # nil and false both mean "disabled"; false is the canonical wire value.
      animateMinZoom: assigns.animate_min_zoom || false,
      navigation: assigns.navigation,
      geolocation: assigns.geolocation,
      flyOnGeolocate: assigns.fly_on_geolocate,
      events: Enum.map(assigns.events, &to_string/1),
      moveEndThrottleMs: assigns.move_end_throttle_ms
    })
  end
end
