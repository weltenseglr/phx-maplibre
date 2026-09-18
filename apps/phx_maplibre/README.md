# PhxMaplibre

PubSub-first [MapLibre GL JS](https://maplibre.org/) integration for Phoenix
LiveView. You render a map with a stateless function component. Whitelisted
map interactions come back as `%PhxMaplibre.Event{}` structs on that map's own
PubSub topic, and any BEAM process can drive the map by broadcasting a
`%PhxMaplibre.Command{}` on its commands topic. The process that renders a map
and the process that feeds it need not be the same one, or know about each
other at all.

## How it works

```
 browser (MapLibre GL) ──"maplibre:event"──▶ attach_hook(:handle_event) ──▶ PubSub events topic ──▶ any subscriber
 browser (MapLibre GL) ◀──push_event──────── attach_hook(:handle_info)  ◀── PubSub commands topic ◀── any process
```

* `PhxMaplibre.Components.map/1` is a plain function component, not a
  `Phoenix.LiveComponent`. It renders one `div` with `phx-update="ignore"` and
  a `phx-hook`. The map itself lives in the browser and the component never
  re-renders it.
* `use PhxMaplibre.LiveView` in the parent LiveView adds an `on_mount`
  callback that attaches two `Phoenix.LiveView.attach_hook/4` hooks, one on
  `:handle_event` and one on `:handle_info`. They relay map traffic in both
  directions and leave your own `handle_event`/`handle_info` clauses alone.
* `PhxMaplibre.LiveView.attach_map/3`, called in `mount/3`, registers a map id
  and subscribes the LiveView to that map's events and commands topics.
* A client interaction reaches the browser hook and is pushed to the server as
  a single multiplexed `"maplibre:event"` LiveView event carrying the map id,
  event name, and payload. The `:handle_event` hook turns it into a
  `%PhxMaplibre.Event{}` and broadcasts it on `phx_maplibre:{map_id}:events`,
  where every subscriber, the owning LiveView included, picks it up in an
  ordinary `handle_info/2` clause. **No `handle_event/3` clause is ever needed
  for map interactions.**
* A call to `PhxMaplibre.fly_to/3` (or `set_features/3`, `fit_bounds/3`, …)
  validates the params, wraps them in a `%PhxMaplibre.Command{}`, and
  broadcasts on `phx_maplibre:{map_id}:commands`. The `:handle_info` hook on
  the owning LiveView turns that back into a `push_event/3` to the browser
  hook, which applies it to the MapLibre instance.

Both directions are ordinary PubSub topics, so the sender and the map's
LiveView never have to be related. A supervised simulation can drive a map it
never rendered, and a test, a second LiveView, or a `LiveDashboard` page can
watch a map's interactions by calling `PhxMaplibre.subscribe/2`.

## Installation

Inside this umbrella, or any umbrella that vendors the library as a sibling
app, depend on it with `in_umbrella`:

```elixir
{:phx_maplibre, in_umbrella: true}
```

Once it is published, the Hex form will be:

```elixir
def deps do
  [
    {:phx_maplibre, "~> 0.2"}
  ]
end
```

### JavaScript

`maplibre-gl` is a peer dependency. Your app installs it and passes the module
into the hook factory, so the library never pins a MapLibre GL version.

| MapLibre GL JS | Coverage | Drawing stack |
| --- | --- | --- |
| 5.x | CI compatibility lane | WaterGIS 1.16.0, Terra Draw 1.33.0, adapter 1.4.1 |
| 6.x | Demo and pre-commit lane | WaterGIS 1.16.0, Terra Draw 1.33.0, adapter 1.4.1 |

The library supports both majors through its peer range. The demos pin the
current 6.x line; CI rebuilds the Berlin editor with 5.x before running its
browser suite.

MapLibre 6 ships a separate module worker. With esbuild, serve
`dist/maplibre-gl-worker.mjs` and `dist/maplibre-gl-shared.mjs` together from
your static assets, then call
`maplibregl.setWorkerUrl("/assets/js/maplibre-gl-worker.mjs")` before mounting
any maps. Both demos copy these files during `mix assets.setup`,
`mix assets.build`, and `mix assets.deploy`. MapLibre 5 embeds its worker and
does not need this step.

```json
// assets/package.json
{
  "dependencies": {
    "maplibre-gl": "6.10.0"
  }
}
```

```js
// assets/js/app.js
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import * as maplibregl from "maplibre-gl"
import {createMapHook} from "phx_maplibre"

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PhxMaplibreHook: createMapHook(maplibregl)}
})
```

`createMapHook(maplibregl)` returns the hook implementation. Register it under
exactly the name `PhxMaplibreHook`; that is what
`PhxMaplibre.Components.map/1` puts in `phx-hook`.

### Browser readiness and Playwright

Readiness has several independent meanings. Use the narrowest signal needed:

| State | Signal | Meaning |
| --- | --- | --- |
| LiveView connected | Application connection indicator or hook `mounted` / `reconnected` / `disconnected` callbacks | The channel is live; this does not imply style or data readiness. |
| Hook mounted | `data-map-hook-ready="true"` | Map instance and command handlers exist. |
| Style initialized | `data-map-style-ready="true"` | Custom sources, layers, and interactions exist. Resets during theme or `set_style` replacement. |
| Initial map load | `data-map-loaded="true"` | Initial MapLibre `load` event occurred; this milestone remains true across style replacements. |
| Points present | `data-map-points-present="true"` | Latest `set_features` collection is nonempty; becomes false for an empty collection. |
| Actionable pin | `queryRenderedFeatures` on the intended pin layers | A pin is currently rendered in the viewport. |

The four map attributes start as `"false"` and reset on hook destruction.
Style readiness alone does not guarantee that asynchronous source processing
has rendered a feature. Area-only maps need their own data condition:
`data-map-points-present` describes points only. The server `:ready` event still
fires at initial map load and is a useful cue for the first data push.

Import `getMapHandle` from `phx_maplibre` and pass the container element. It
returns `null` before successful mount and after destruction, or a frozen
handle with `map` (the MapLibre instance) and a `pointsData` getter reflecting the latest
collection. Treat the collection as read-only. Reacquire the handle after
navigation or remount. A previously saved handle still refers to the old,
removed map; it must not be reused. There is no need to inspect
private `window.liveSocket` objects.

Initialization diagnostics are separate from readiness. `data-map-lifecycle`
is `mounting`, `mounted`, `style-loading`, `error`, or `destroyed`.
`data-map-mount-count` increments on each mount of the same element.
`data-map-error` holds the latest setup or MapLibre resource error message and
resets on remount. Setup exceptions leave the relevant readiness flags false,
record `error`, clean up a failed mount, and log the original message to the
console without interrupting other LiveView hooks. Resource errors can be
recoverable, so they record a message without automatically marking a mounted
map unusable. Connectivity remains independent of map setup success.

For browser tests, explicitly expose the exported accessor in the app bundle:

```js
import {getMapHandle} from "phx_maplibre";
window.phxMaplibre = Object.freeze({getMapHandle});
```

In a failing test, include `mapLifecycle`, `mapMountCount`, and `mapError` from
the container's `dataset` in the readiness assertion. An `error` lifecycle
should fail immediately with the original error; a mounting or style-loading
state can be polled with a bounded timeout. The GSD suite demonstrates this in
its `waitForMapState` helper.

For a canvas visibility test, checking the canvas is sufficient:

```js
await page.goto("/");
await expect(page.locator("#tracker-map canvas")).toBeVisible();
```

For pin selection, wait for style and point data, choose a real coordinate,
then poll for an actual rendered pin. This example uses the default point
layers and zooms past clustering; adjust the zoom for your configuration:

```js
const selector = "#tracker-map";
const container = page.locator(selector);
await expect(container).toHaveAttribute("data-map-hook-ready", "true");
await expect(container).toHaveAttribute("data-map-style-ready", "true");
await expect(container).toHaveAttribute("data-map-points-present", "true");

await page.evaluate((selector) => {
  const {map, pointsData} = window.phxMaplibre.getMapHandle(document.querySelector(selector));
  map.jumpTo({center: pointsData.features[0].geometry.coordinates, zoom: 15});
}, selector);

const layers = ["unclustered-points", "animated-points"];
await expect.poll(() => page.evaluate(({selector, layers}) => {
  const {map} = window.phxMaplibre.getMapHandle(document.querySelector(selector));
  const existing = layers.filter(id => map.getLayer(id));
  return existing.length ? map.queryRenderedFeatures({layers: existing}).length : 0;
}, {selector, layers})).toBeGreaterThan(0);

const pixel = await page.evaluate(({selector, layers}) => {
  const {map} = window.phxMaplibre.getMapHandle(document.querySelector(selector));
  const feature = map.queryRenderedFeatures({
    layers: layers.filter(id => map.getLayer(id)),
  })[0];
  const projected = map.project(feature.geometry.coordinates);
  const rect = map.getContainer().getBoundingClientRect();
  return {x: rect.left + projected.x, y: rect.top + projected.y};
}, {selector, layers});
await page.mouse.click(pixel.x, pixel.y);
await expect(page.locator("#detail-panel")).toBeVisible();
```

Live updates can move pins between querying and clicking. Keep this interval
short and assert the resulting selection. Do not use `map.loaded()` as a
universal readiness gate: continuously updated sources can keep it false.

For a simulation survival test, expose a server update revision on an
application element, increment it when a broadcast is handled, and wait for
it to change. In the GSD demo, connectivity is exposed as
`#gsd-connection-status[data-connection="live"]` and updates as
`#gsd-tracker[data-simulation-revision]`:

```js
await expect(page.locator("#gsd-connection-status"))
  .toHaveAttribute("data-connection", "live");
await expect(page.locator('[id^="map-tracker-"] canvas')).toBeVisible();
const tracker = page.locator("#gsd-tracker");
const revision = await tracker.getAttribute("data-simulation-revision");
await expect(tracker).not.toHaveAttribute("data-simulation-revision", revision);
```

This observes a received update rather than assuming a tick occurred after a
fixed sleep. Map mounting, connectivity, and update receipt stay separate.

For your own connection indicator, register an application hook and keep its
state across server patches:

```js
const ConnectionStatus = {
  mounted() { this.setConnection(true); },
  reconnected() { this.setConnection(true); },
  disconnected() { this.setConnection(false); },
  updated() { this.setConnection(this.connectionLive); },
  setConnection(live) {
    this.connectionLive = live;
    this.el.dataset.connection = live ? "live" : "offline";
  },
};
// Include ConnectionStatus in the LiveSocket's hooks option.
```

```heex
<span id="connection-status" phx-hook="ConnectionStatus"
      data-connection="offline" role="status">Connection</span>
```

A mounted map can remain visible while disconnected, so use the connection
indicator when a test needs server interaction.


esbuild resolves `import "phx_maplibre"` Node-style, walking `NODE_PATH`.
Where to point it depends on how you consume the library:

* **Hex dependency.** The package is fetched into the app's `deps` directory,
  so `NODE_PATH` needs `deps` (the `package.json` `main` field points at
  `priv/js/phx_maplibre.js`, resolved relative to that real path):

  ```elixir
  # config/config.exs (config/ and deps/ are both direct children of the app root)
  config :esbuild,
    my_app: [
      args: ~w(js/app.js --bundle --outdir=../priv/static/assets/js),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__)]}
    ]
  ```

* **Umbrella sibling**, as in this repo, where `demo_gsd_tracker` consumes
  `phx_maplibre` with `in_umbrella: true`. Here `phx_maplibre` is not in
  `deps` at all but a sibling directory under `apps/`, so `NODE_PATH` needs
  the `apps` directory itself:

  ```elixir
  # apps/demo_gsd_tracker/config/config.exs
  config :esbuild,
    version: "0.25.4",
    demo_gsd_tracker: [
      args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
      cd: Path.expand("../assets", __DIR__),
      env: %{
        "NODE_PATH" => [
          Path.expand("../assets", __DIR__),
          Path.expand("../assets/node_modules", __DIR__), # drawing peers installed by the app
          Path.expand("../../../deps", __DIR__),  # shared umbrella deps
          Path.expand("../..", __DIR__),          # apps/ — resolves `phx_maplibre` directly
          Mix.Project.build_path()
        ]
      }
    ]
  ```

### CSS

Import the MapLibre GL stylesheet first, then this library's (popup and
control theming), alongside your own CSS. Paths below are relative to
`assets/css/app.css`.

For a Hex dependency:

```css
@import "../node_modules/maplibre-gl/dist/maplibre-gl.css";
@import "../../deps/phx_maplibre/priv/css/phx_maplibre.css";
```

For an umbrella sibling (as `demo_gsd_tracker` does):

```css
@import "../node_modules/maplibre-gl/dist/maplibre-gl.css";
@import "../../../phx_maplibre/priv/css/phx_maplibre.css";
```

## Quick start

```elixir
defmodule MyAppWeb.TrackerLive do
  use MyAppWeb, :live_view
  use PhxMaplibre.LiveView

  @map_id "tracker-map"

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:map_id, @map_id)
      |> PhxMaplibre.LiveView.attach_map(@map_id, pubsub: MyApp.PubSub)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <PhxMaplibre.Components.map
      id={@map_id}
      center={%{lng: 13.405, lat: 52.52}}
      zoom={11}
      class="h-full w-full"
    />
    """
  end

  # No handle_event/3 clause needed — the hook installed by
  # `use PhxMaplibre.LiveView` relays client events to PubSub for you.

  def handle_info(%PhxMaplibre.Event{event: :ready, payload: %{bounds: _bounds}}, socket) do
    features = %{
      type: "FeatureCollection",
      features: [
        %{
          type: "Feature",
          id: "1",
          geometry: %{type: "Point", coordinates: [13.405, 52.52]},
          properties: %{id: "1", title: "Berlin"}
        }
      ]
    }

    {:noreply, PhxMaplibre.set_features(socket, @map_id, features)}
  end

  def handle_info(%PhxMaplibre.Event{event: :feature_selected, payload: payload}, socket) do
    IO.inspect(payload, label: "selected")
    {:noreply, socket}
  end

  def handle_info(%PhxMaplibre.Event{}, socket), do: {:noreply, socket}
end
```

`:ready` is the obvious cue for the first push, but not a hard requirement.
`set_features` and `set_area_features` that arrive before the initial style
has loaded are held by the hook and applied as soon as the sources exist. The
camera commands (`fly_to`, `fit_bounds`) have no such buffer.

### `attach_map/3` options

* `:pubsub` — the PubSub server. Falls back to
  `config :phx_maplibre, pubsub: MyApp.PubSub`. One of the two is required, or
  the call raises `ArgumentError`.
* `:topic_prefix` — overrides the `"phx_maplibre"` topic prefix.
  `config :phx_maplibre, topic_prefix: "..."` sets it globally.
* `:subscribe` — subscribe this LiveView to the map's events topic. Default
  `true`. Set `false` when another process handles the events.
* `:commands` — subscribe to the commands topic and relay commands to the
  browser. Default `true`.
* `:events` — the events this map may relay, as atoms. Default: all of them
  (`PhxMaplibre.Event.event_names/0`). Pass the same list you gave the
  component — see below for why the component's list is not enough.
* `:max_event_payload_bytes` — drop client event payloads above this size
  (default `524_288`, i.e. 512 KB; positive integer or `:infinity`). The cap
  guards against fabricated payloads from hostile clients, not your own data —
  if your features carry large properties (a base64-encoded image, say) that
  round-trip through `:feature_selected`, raise it or pass `:infinity`. On a
  single node the broadcast shares large binaries rather than copying them
  per subscriber, so a higher limit costs less than it sounds.

Subscribing needs a connected socket, so a dead mount only records the
registration. Call `attach_map/3` unconditionally in `mount/3`; the connected
mount does the subscribing. Calling it again for an id that is already
registered replaces the registration rather than stacking a second set of
subscriptions. `PhxMaplibre.LiveView.detach_map/2` unsubscribes and forgets an
id, which you need when a `live_patch` swaps the map out but the process
survives.

## Component attributes

`PhxMaplibre.Components.map/1`:

| attribute | type | default | notes |
|---|---|---|---|
| `id` | `:string` | required | DOM id; also the map id used for topics and events — must match `attach_map/3`'s id |
| `center` | `:map` | `%{lng: 13.405, lat: 52.52}` | initial center |
| `zoom` | `:any` | `11` | initial zoom level |
| `light_style` | `:string` | Carto Positron style URL | style used when the document has no dark theme |
| `dark_style` | `:string` | Carto Dark Matter style URL | style used when `<html data-theme="dark">`, or when there is no `data-theme` and the OS prefers dark |
| `cluster` | `:boolean` | `true` | cluster point features (MapLibre GL clustering on the `points` source) |
| `cluster_color` | `:string` | `nil` | single color for cluster bubbles, with dark count text; unset keeps the built-in size-stepped palette |
| `cluster_spiderfy_zoom` | `:any` | `nil` | keep clusters through the map's zoom range; below this zoom cluster clicks zoom no farther than the threshold, while clicks at/above it spiderfy that cluster's leaves; this mode supersedes animated point presentation |
| `animate_min_zoom` | `:any` | `12` | zoom at/above which point features render with animated position transitions between `set_features` updates (see [Animated updates](#animated-updates)); `false` (or `nil`) disables animation |
| `navigation` | `:boolean` | `true` | show the `NavigationControl` (zoom/rotate) |
| `geolocation` | `:boolean` | `false` | show the `GeolocateControl` |
| `fly_on_geolocate` | `:boolean` | `true` | fly the map to the user's position on geolocation success |
| `events` | `:list` | `[:ready, :feature_selected, :feature_deselected, :cluster_selected, :move_end, :geolocation_success, :geolocation_error]` | opt-in whitelist — only listed event names ever leave the browser |
| `move_end_throttle_ms` | `:integer` | `1000` | minimum interval between `:move_end` events |
| `class` | `:any` | `nil` | extra classes merged onto the `phx-maplibre` container class |
| `rest` | `:global` | — | passed through to the container `div` |

Spiderfying changes presentation only. Expanded points remain linked to their
original GeoJSON features, so selection events carry the original coordinates
and properties. Zooming or clicking empty map space restores the cluster.

```heex
<PhxMaplibre.Components.map
  id="venues-map"
  cluster={true}
  cluster_spiderfy_zoom={15}
/>
```

The threshold is also the upper bound for normal cluster-click zooming. If
MapLibre calculates an expansion zoom of `18`, clicking at zoom `14` stops at
`15`; the next click spiderfies the cluster without moving the camera. While
expanded, only that cluster is hidden. Other clusters remain interactive.

The whitelist is enforced client-side: `pushMapEvent` in `priv/js/events.js`
checks membership before calling `pushEvent`, so an event you leave out never
reaches the server. `:feature_hovered` and `:feature_unhovered` are absent
from the default list on purpose, since hover fires on every pointer
transition. Opt in explicitly when you want it:

```heex
events={[:ready, :move_end, :feature_selected, :feature_deselected, :feature_hovered, :feature_unhovered]}
```

Client-side is the operative word: the list keeps your own map from being
chatty, but a connected client can push any event name it likes over the
channel. Give the same list to `attach_map/3`'s `:events` option to gate the
server side, where it is enforced before anything is relayed to PubSub:

```elixir
@events [:ready, :move_end, :feature_selected, :feature_deselected]

PhxMaplibre.LiveView.attach_map(socket, "tracker-map", pubsub: MyApp.PubSub, events: @events)
```

Payloads over 512 KB are dropped with a warning, whatever the event.

## Events reference

Every event is a `%PhxMaplibre.Event{map_id: map_id, event: event_name,
payload: payload, meta: %{pid: pid, at: datetime}}`. `meta` records which
LiveView process relayed the event and when. Payload keys the library knows
about become atoms; unrecognized keys and everything inside `:properties`
(your own feature data) keep their string keys.

| event | fires when | payload |
|---|---|---|
| `:ready` | the map's initial style has finished loading and its sources/layers exist | `%{bounds: bounds, center: %{lng:, lat:}, zoom: zoom}` |
| `:feature_selected` | a point or area feature is clicked | `%{id: id, kind: "point" \| "area", lng: lng, lat: lat, feature: geojson_feature}` (for areas, `lng`/`lat` are the click position, not a centroid) |
| `:feature_deselected` | a selected feature is replaced by a new selection *of the same kind*, an already-selected area is clicked again (toggle off), or a click lands on empty map space (fires once per kind — point and/or area — that was selected) | `%{id: id, kind: "point" \| "area"}` |
| `:feature_hovered` | the pointer enters a point or area feature — opt-in, not in the default `events` list | `%{id: id, kind: "point" \| "area", title: title \| nil}` |
| `:feature_unhovered` | the pointer leaves a feature, or moves directly onto another feature (fires for the old feature before `:feature_hovered` fires for the new one) — opt-in | `%{id: id, kind: "point" \| "area", title: title \| nil}` |
| `:cluster_selected` | a cluster circle is clicked (only when `cluster={true}`); below `cluster_spiderfy_zoom` the map eases no farther than that threshold, and at/above it the cluster spiderfies without moving the camera | `%{cluster_id: id, point_count: n, center: %{lng:, lat:}}` |
| `:move_end` | the map stops moving (pan/zoom/fly), throttled to at most one per `move_end_throttle_ms` | `%{bounds: %{west:, south:, east:, north:}, center: %{lng:, lat:}, zoom: zoom}` |
| `:geolocation_success` | the browser's `GeolocateControl` resolves a position | `%{lng: lng, lat: lat, accuracy: accuracy}` |
| `:geolocation_error` | the browser denies or fails geolocation | `%{code: code, message: message}` |

Hover is exact-once per transition. Moving around inside one feature emits
nothing further, and going from feature A straight onto feature B emits
`:feature_unhovered` for A strictly before `:feature_hovered` for B. Cluster
circles highlight on hover but emit no event; only point and area features do.

GeoJSON is the exchange format in both directions. Features go to the map as
GeoJSON through `set_features`/`set_area_features`, and `:feature_selected`
hands the clicked feature back under `:feature` as a GeoJSON Feature —
geometry and properties exactly as your data provided them (string-keyed,
paint overrides included). Read application data from
`payload.feature["properties"]`.

## Commands reference

Every command has two forms:

* **`command(map_id, ..., opts)`** validates the params, broadcasts a
  `%PhxMaplibre.Command{}` over PubSub, and returns `:ok | {:error, reason}`.
  Callable from any process. Needs `:pubsub` in `opts` or
  `config :phx_maplibre, pubsub: MyApp.PubSub`.
* **`command(socket, map_id, ..., opts)`** validates the params and calls
  `Phoenix.LiveView.push_event/3` on the socket, skipping PubSub. Only the
  LiveView that owns the map can use it. It saves a PubSub round trip, which
  is worth having for big or frequent payloads such as `set_features/3` with
  thousands of features on a timer.

| PubSub form | socket fast-path form | params | notes |
|---|---|---|---|
| `set_features(map_id, geojson, opts \\ [])` | `set_features(socket, map_id, geojson)` | `geojson`: a FeatureCollection map or a list of Feature maps | replaces all point features; points should carry an `id` property (used for hover/select `setFeatureState`) |
| `set_area_features(map_id, geojson, opts \\ [])` | `set_area_features(socket, map_id, geojson)` | same shape as `set_features` | replaces all area (polygon) features |
| `fly_to(map_id, center, opts \\ [])` | `fly_to(socket, map_id, center, opts \\ [])` | `center`: `%{lng:, lat:}`; `opts`: `:zoom` (default `14`), `:duration` ms (default `1500`) | animated flight to a point |
| `fit_bounds(map_id, bounds_or_geojson, opts \\ [])` | `fit_bounds(socket, map_id, bounds_or_geojson, opts \\ [])` | explicit `%{west:, south:, east:, north:}`, or any GeoJSON whose bbox is computed via `PhxMaplibre.Geo.bounds/1`; `opts`: `:padding` px (default `40`), `:max_zoom` (default `15`) | the PubSub form returns `{:error, :no_coordinates}` for GeoJSON with no coordinates; the socket form **raises** `ArgumentError` in that case |
| `set_style(map_id, style, opts \\ [])` | `set_style(socket, map_id, style)` | `style`: a MapLibre style URL | swaps the base style; library sources/layers/data/feature-state are re-added automatically after the style loads |
| `request_geolocation(map_id, opts \\ [])` | `request_geolocation(socket, map_id)` | — | triggers the browser's geolocate control; result arrives as `:geolocation_success`/`:geolocation_error`. No-op on a map rendered without `geolocation={true}`, which has no control to trigger |

A bare list of Feature maps is wrapped into a FeatureCollection for you by
`PhxMaplibre.Geo.feature_collection/1`.

`PhxMaplibre.Command.new/3` validates params before anything is broadcast, so
a malformed call fails at the call site with
`{:error, {:invalid_params, command}}` instead of quietly doing nothing in the
browser. The socket fast path goes through the same constructor and raises
`ArgumentError`.

`set_features`/`set_area_features` are checked the same way: the `geojson` has
to be a FeatureCollection map (`type` of `"FeatureCollection"`, string or atom
key, and a list under `features`) whose entries are Feature maps, or a bare
list of Feature maps. Anything else — `%{}` most notably, which would fail
silently inside `setData` — is `{:error, :invalid_geojson}`, or an
`ArgumentError` from the socket form. The check is structural; geometries are
yours.

### Cookbook: drive a map from anywhere

Any process that knows the map id and the PubSub server can move the map, not
only the LiveView that renders it. From `iex`:

```elixir
iex> PhxMaplibre.fly_to("tracker-map", %{lng: 13.405, lat: 52.52}, zoom: 13, pubsub: MyApp.PubSub)
:ok
```

Or from a supervised process, say a ticker that recenters the map on the
busiest cluster every half minute:

```elixir
defmodule MyApp.MapDirector do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :timer.send_interval(30_000, :recenter)
    {:ok, %{map_id: Keyword.fetch!(opts, :map_id), pubsub: Keyword.fetch!(opts, :pubsub)}}
  end

  @impl true
  def handle_info(:recenter, state) do
    center = MyApp.Tracking.busiest_area_center()
    PhxMaplibre.fly_to(state.map_id, center, zoom: 13, pubsub: state.pubsub)
    {:noreply, state}
  end
end
```

`MyApp.MapDirector` never renders the map and knows nothing about the LiveView
that does beyond the map id. The command reaches the browser through the
`phx_maplibre:tracker-map:commands` topic.

## Animated updates

Point features move smoothly. Each `set_features` update is rendered twice:
the clustered snapshot source updates instantly (that is what you see at low
zoom), and — at zooms at or above `animate_min_zoom` (default `12`, half a
zoom level of hysteresis) — an unclustered animated source shows the same
features tweening linearly from where they were displayed to their new
positions. The tween duration is the measured interval between updates, so a
server streaming viewport-filtered GeoJSON every few seconds produces
continuous, constant-velocity motion with zero extra wire traffic and zero
simulation logic in the browser.

The mechanics, so behavior is predictable:

* Features are matched by `id` across updates. A first-seen id appears in
  place (no fly-in); an id missing from an update disappears immediately.
* Properties (status, paint overrides, …) always apply immediately — only
  the position tweens.
* The measured interval is clamped to 250 ms – 15 s (first update: 5 s), so
  a burst or a stall cannot produce absurd motion.
* Interaction parity is complete: hover/select feature-state, popups (which
  ride their moving feature), and `:feature_selected` with the position at
  click time all work identically on the animated source.
* The animation loop idles whenever every feature has reached its target and
  wakes on the next update; above ~1,500 animated features it drops from 30
  to 10 frames per second — keep pushing viewport-filtered subsets rather
  than the world.
* Two safety bounds: an update with more than 10,000 features renders as a
  plain snapshot (no animation, one console warning) until a smaller update
  arrives, and only features whose `id` is a string of at most 128
  characters or a finite number participate in tweening — everything else
  still renders via the snapshot path.
* Pass `animate_min_zoom={false}` (or `nil`) on the component to disable the
  animated path entirely and render every update as an instant snapshot.

## Subscribing from other processes

Any process can watch a map's interactions without being its LiveView:

```elixir
PhxMaplibre.subscribe("tracker-map", pubsub: MyApp.PubSub)

receive do
  %PhxMaplibre.Event{event: :feature_selected, payload: payload} ->
    IO.inspect(payload)
end
```

In a GenServer, another LiveView, or a test, match on `%PhxMaplibre.Event{}`
in `handle_info/2` the way the owning LiveView does. `PhxMaplibre.unsubscribe/2`
stops it. If you would rather subscribe through `Phoenix.PubSub` yourself,
`PhxMaplibre.events_topic/2` and `PhxMaplibre.commands_topic/2` give you the
raw topic names.

## Security model: authorize at attach time

A browser client cannot subscribe to anything. `Phoenix.PubSub.subscribe/2`
is a BEAM-process primitive; the only process acting for a client is its own
LiveView, and that LiveView subscribes to exactly the topics your server code
passed to `attach_map/3` in `mount/3`. No wire message triggers a
subscription. The relay hook forwards `"maplibre:event"` only for map ids in
that LiveView's own registry — an unregistered id is logged and dropped — and
event names are matched against a compile-time allowlist, so a client cannot
mint atoms or smuggle topic strings through a payload.

The consequence: **the map id is a capability, and `attach_map/3` is where
authorization happens.** The one way a hostile client reaches someone else's
map is a server that attaches an id the client chose:

```elixir
# Vulnerable: the map id becomes an unauthenticated capability. An attacker
# who knows (or guesses) another user's id now receives that map's commands
# and can forge events into its topic.
def mount(%{"map_id" => id}, _session, socket) do
  {:ok, PhxMaplibre.LiveView.attach_map(socket, id, pubsub: MyApp.PubSub)}
end
```

Rules that keep the model sound:

* **The server chooses map ids.** For per-user maps, generate one per
  session — `"tracker-" <> Base.encode16(:crypto.strong_rand_bytes(16))` —
  as the demo apps do. It is unguessable and only ever rendered into that
  user's DOM.
* **Gate shared maps with your normal LiveView auth.** A deliberately shared
  id (`"fleet-overview"`) is fine when the attach is conditional:
  `live_session` + `on_mount` assigns the current user, and you call
  `attach_map/3` only after `can_view_map?(user, map_id)` passes. Not
  attaching *is* the denial.
* **Namespace structural ids by tenant** (`"org:#{org.id}:fleet"`) and verify
  membership in `mount/3`; backend broadcasters derive topics the same way,
  so no client-nameable id crosses a tenant boundary.
* **Sign ids that round-trip through the client** (deep links, params) with
  `Phoenix.Token`, and verify before attaching.

One honest boundary: PubSub itself has no ACLs. Any *server-side* process may
subscribe to any topic — that is trusted code by definition, and no library
changes it. What this library guarantees is that the untrusted side of the
wire never gets a subscription, never gets a relay for an unattached id, and
never gets an event past the server-side `:events` allowlist and
`:max_event_payload_bytes` cap.

## Styling

### Feature paint overrides

A feature's `properties` can carry flat MapLibre paint properties, which
override the layer default for that one feature through a `coalesce`
expression (`["coalesce", ["get", "circle-color"], "#6366f1"]`). The
recognized set is `STYLE_PROPS` in `priv/js/sources_layers.js`:

```
fill-color, fill-opacity, fill-outline-color, fill-pattern,
circle-color, circle-radius, circle-opacity, circle-stroke-color, circle-stroke-width,
line-color, line-width, line-opacity, line-dasharray,
text-color, text-size, text-opacity, text-halo-color, text-halo-width,
icon-image, icon-size, icon-opacity,
background-color, background-opacity,
raster-opacity, hillshade-illumination-direction, hillshade-exaggeration
```

Only ten of those keys actually reach a layer today: `fill-color` and
`fill-opacity` on the area fill, `line-color`/`line-width`/`line-opacity` on
the area outline, and `circle-color`/`circle-radius`/`circle-opacity`/
`circle-stroke-color`/`circle-stroke-width` on unclustered points. The popup
filter recognizes the whole set, but the rest has no layer to apply to.
Selection and hover states win over these overrides: a selected point is
always red, a hovered point always green. `priv/js/sources_layers.js` has the
exact expressions.

A feature can set `properties["linked-id"]` to another feature id. Selecting
it then marks the linked feature with the secondary orange selection state.
This is generic data-driven behavior: use it for paired assets, related
records, or any other relationship without adding a new event contract.

The default popup renderer skips these keys so they don't show up as
application data. Event payloads do not filter them: `:feature_selected`
carries the GeoJSON Feature exactly as your data provided it, paint overrides
included.

### Popup HTML

Clicking a point or area feature opens a MapLibre popup, built by default from
the feature's `properties` (`buildPopupHTML` in `priv/js/popup.js`):

* `properties.title` → `<h3 class="phx-maplibre-popup-title">`
* `properties.description` → `<p class="phx-maplibre-popup-desc">`
* every other property (excluding `title`, `description`, keys starting with
  `_`, and the `STYLE_PROPS` above) → a `.phx-maplibre-popup-row` with a
  `.phx-maplibre-popup-label` / `.phx-maplibre-popup-value` pair, in property
  order

All values are HTML-escaped, and feature data can never inject markup — there
is deliberately no property that reaches the popup unescaped. Rich popups are
code, not data: pass a `popupContent` renderer to `createMapHook` and return a
DOM Node, which goes in via MapLibre's `Popup#setDOMContent`:

```js
const hook = createMapHook(maplibregl, {
  popupContent(feature) {
    const el = document.createElement("div")
    el.className = "phx-maplibre-popup"
    el.textContent = feature.properties.title ?? "Unnamed"
    return el // built with createElement/textContent — XSS-safe by construction
  },
})
```

Return `null` (or nothing) to fall back to the default popup for that
feature. If you assemble HTML strings inside the renderer via `innerHTML`,
sanitizing them is on you — but that choice then lives visibly in your code,
where a review can find it, not in whatever GeoJSON happens to flow in.

CSS classes to target for custom styling: `.phx-maplibre` (the container),
`.phx-maplibre-popup`, `.phx-maplibre-popup-title`, `.phx-maplibre-popup-desc`,
`.phx-maplibre-popup-details`, `.phx-maplibre-popup-row`,
`.phx-maplibre-popup-label`, `.phx-maplibre-popup-value`, and
`.phx-maplibre-popup-type` (styled but not emitted by the default renderer —
it's there for custom `popupContent` nodes). `priv/css/phx_maplibre.css` ships
light-mode styles for those plus MapLibre's own `.maplibregl-popup-content`
and `.maplibregl-popup-close-button`, and dark variants scoped under
`[data-theme="dark"]` — including `.maplibregl-popup-tip` and
`.maplibregl-ctrl-group`, which are only restyled in dark mode.

### Theme switching

`light_style` and `dark_style` are two independent MapLibre style URLs. The
hook watches `<html data-theme="...">` with a `MutationObserver`, debounced
300ms, and swaps styles when the resolved theme changes:

* `data-theme="dark"` → `dark_style`
* `data-theme="light"` → `light_style`
* no `data-theme` attribute → the `prefers-color-scheme: dark` media query decides

MapLibre discards everything the library added when the style changes, so once
the new style has loaded the hook re-adds its sources and layers, pushes the
current feature data back in, and restores hover and selection state. That
happens on every theme flip and after an explicit `set_style/3`,
with nothing required from the LiveView. Writing `data-theme` is your app's
job; PhxMaplibre only reacts to it.

By default `light_style` and `dark_style` point at CARTO's public style CDN,
which is fine for demos but worth reconsidering before production: the
browser fetches that style JSON directly at runtime, so your map's appearance
now depends on a third party's availability and on trusting the content they
serve. Production consumers should self-host the style JSON (and its tile
sources) or at least pin and review the specific style version they point to,
rather than trusting a mutable public URL indefinitely.

## Optional shared feature editor

Feature editing is an explicit opt-in. Ordinary maps use only the existing
map component and `createMapHook`; they do not import Terra Draw or WaterGIS,
start editor processes, or require drawing packages.

```js
// Map-only application: no editor dependencies required.
import * as maplibregl from "maplibre-gl";
import {createMapHook} from "phx_maplibre";
const hooks = {PhxMaplibreHook: createMapHook(maplibregl)};
```

An editing application installs the optional drawing peers:

```sh
npm install @watergis/maplibre-gl-terradraw@1.16.0 terra-draw@1.33.0 terra-draw-maplibre-gl-adapter@1.4.1
```

When using Phoenix's esbuild wrapper, include your application's
`assets/node_modules` explicitly in `NODE_PATH`, alongside the directory that
contains `phx_maplibre` (`deps` for Hex, or `apps` for an umbrella sibling).
Drawing peers are imported from the library's real path, so searching only the
app's JavaScript source directory is insufficient.

Register the separate editor hook and WaterGIS control styles alongside the
ordinary map hook:

```js
import * as maplibregl from "maplibre-gl";
import {createMapHook} from "phx_maplibre";
import {createEditorHook, getEditorHandle} from "phx_maplibre/editor";
import "@watergis/maplibre-gl-terradraw/dist/maplibre-gl-terradraw.css";
import "phx_maplibre/editor.css";

const hooks = {
  PhxMaplibreHook: createMapHook(maplibregl),
  PhxMaplibreEditorHook: createEditorHook(maplibregl),
};
// Pass hooks to your LiveSocket. Reacquire the editor handle after remount.
```

If esbuild bundles the CSS imports above, include its emitted CSS file in your
page. Phoenix applications that build their main stylesheet with Tailwind can
instead place these imports in `assets/css/app.css` and omit the JavaScript
CSS imports:

```css
@import "../node_modules/@watergis/maplibre-gl-terradraw/dist/maplibre-gl-terradraw.css";
/* Hex dependency, relative to assets/css/app.css: */
@import "../../deps/phx_maplibre/priv/css/editor.css";
/* Umbrella sibling: use ../../../phx_maplibre/priv/css/editor.css instead. */
```

The relative WaterGIS path avoids a Tailwind resolver issue with that package's
CSS export conditions. Keep these styles explicit so map-only pages need no
editor stylesheet.

Start an editor runtime explicitly in your application's supervision tree.
The default storage is ephemeral; stopping the runtime discards its documents.
Document processes are started lazily when an editor attaches.

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  {PhxMaplibre.Editor.Runtime, name: MyApp.EditorRuntime, pubsub: MyApp.PubSub}
]
```

Attach both the map and editor in your LiveView. Editor IDs identify browser
instances; document IDs identify shared feature sets. Two editors using the
same document ID share a document, while different document IDs remain isolated.

```elixir
use PhxMaplibre.LiveView

# In mount/3, after assigning the current user:
socket =
  socket
  |> PhxMaplibre.LiveView.attach_map("features-map", pubsub: MyApp.PubSub)
  |> PhxMaplibre.LiveView.attach_editor("features-editor",
    runtime: MyApp.EditorRuntime,
    document_id: "shared-polygons",
    modes: ["polygon", "select"],
    user: %{id: "user-42", name: "Visitor", color: "#f97316"}
  )
```

```heex
<PhxMaplibre.Components.map id="features-map" cluster={false} />
<PhxMaplibre.Components.editor
  id="features-editor"
  map_id="features-map"
  config={%{}}
/>
```

Use the same configuration in `attach_editor` and the editor component. Build
one configuration map and pass `Map.to_list(config)` to `attach_editor/3` to
avoid the two declarations drifting.
`modes` selects enabled WaterGIS modes, `control` selects `"draw"` or `"measure"`,
`control_options` passes control options (default `%{"open" => true}`), and
`fields` selects the built-in `"name"` and `"color"` property inputs. Other
application properties can be changed through the editor handle. Available
drawing modes are `point`, `marker`, `linestring`, `polyline`, `polygon`,
`rectangle`, `circle`, `freehand`, `freehand-linestring`, `angled-rectangle`,
`sensor`, `sector`, and `text`; control modes are `render`, `select`,
`delete-selection`, `delete`, `undo`, `redo`, and `download`. Omit `modes` to
use the library's complete supported list. The shared
update interval initially defaults to 500 ms and can be changed through the
editor; all editors in that document use the authoritative value.

The library owns drawing, shared operations, optimistic reconciliation,
acknowledgements, reconnect, preview and cursor rendering, and style lifecycle.
Application UI can use `getEditorHandle(element)` rather than implementing its
own gesture engine or synchronization protocol. Feature properties remain
application data; editor coordinate IDs, modes, history, and acknowledgements
are separate metadata. Epoch and revision identify document state, so a reset
can replace a client's previous document.

### Browser commands and readiness

`getEditorHandle(element)` returns `null` before mounting and after destruction.
The frozen handle exposes `map`, `draw`, a copied `state`, `online`, `select(id)`,
`setMode(mode)`, `mutate(payload)`, `undo()`, and `redo()`. Custom UI should use
these commands to preserve the library's collaboration protocol.

The editor dispatches the bubbling `phx-maplibre:editor-ready` event after the
map style and drawing control are ready. It can fire again following style
restoration; remove listeners when your application UI is destroyed.

```js
const element = document.getElementById("features-editor");
element.addEventListener("phx-maplibre:editor-ready", () => {
  const editor = getEditorHandle(element);
  // Network readiness is independent of map readiness.
  if (editor?.online) editor.setMode("polygon");
});
```

### Persistence and ownership

Storage and document ownership are independent, optional application adapters:

```elixir
{PhxMaplibre.Editor.Runtime,
 name: MyApp.EditorRuntime,
 pubsub: MyApp.PubSub,
 storage: {MyApp.EditorStorage, repo: MyApp.Repo},
 owner: {MyApp.EditorOwner, registry: MyApp.DocumentRegistry}}
```

`PhxMaplibre.Editor.Storage.load(document_id, opts)` returns `{:ok, state}`,
`{:ok, nil}` for an absent document, or `{:error, reason}`.
`commit(document_id, expected_version, next_state, opts)` returns `:ok` or
`{:error, reason}`. Commit must compare the expected `{generation, revision}` and
persist the entire opaque document state atomically. Saving GeoJSON alone loses
stable coordinate IDs, insertion anchors, tombstones, and acknowledgements.
A failed commit must leave both persisted geometry and collaboration state
unchanged; success must precede a shared broadcast.

`PhxMaplibre.Editor.Owner.resolve(document_id, opts)` returns `{:ok, pid}` for
the single authoritative document process or `{:error, reason}`. Without an
owner adapter, the explicitly started runtime owns its local documents. Shared
PubSub and shared storage alone do not elect an owner across nodes: applications
using several runtimes must route each document to one owner.

See [the Ash/PostGIS persistence example](examples/ash_postgis_editor.md) for
an application adapter that keeps queryable geometry and editor state in one
transaction. Ash and PostGIS are not dependencies of phx-maplibre.

## Telemetry

Both events carry `%{system_time: System.system_time()}` as measurements.

* `[:phx_maplibre, :event]` fires when a client interaction is relayed to
  PubSub. Metadata: `%{map_id: map_id, event: event_name}`.
* `[:phx_maplibre, :command]` fires when a command is sent, from both the
  PubSub form and the socket fast path. Metadata:
  `%{map_id: map_id, command: command_name}`.
* `[:phx_maplibre, :event_dropped]` fires when untrusted client input is
  rejected before relay. Metadata: `%{map_id: map_id | nil, reason: reason}`;
  `reason` is `:malformed`, `:unattached`, `:unknown_event`,
  `:invalid_payload`, `:disallowed_event`, or `:oversized`.

## Demo apps

`apps/demo_gsd_tracker` (sibling umbrella app, port 4002, live at
[gsd-tracker.weltenseglr.de](https://gsd-tracker.weltenseglr.de)) is the
fuller example. A supervised OTP simulation flies GSDs ("surveillance
pigeons") around Berlin — `config :demo_gsd_tracker, :gsd_count` sets the
fleet size, 24,000 in the deployed demo — and pushes position updates with
`PhxMaplibre.set_features/3`, reading viewport bounds back out of `:move_end`
events to cull the feature set to what's on screen. Start at
`apps/demo_gsd_tracker/lib/gsd_tracker_web/live/map_live.ex`, with
`assets/js/app.js` and `assets/css/app.css` for the asset wiring.

`apps/demo_berlin_districts` (port 4001, live at
[phx-maplibre.demo.weltenseglr.de](https://phx-maplibre.demo.weltenseglr.de))
is smaller: three maps on one page, covering clustering, area hover,
geolocation, and theme switching.

### Browser extensions and style changes

A map container dispatches the bubbling DOM event
`phx-maplibre:style-changing` synchronously before `set_style` commands or
theme changes replace its style. Extensions using `getMapHandle(container)`
can listen to this event to detach their own sources, layers, and controls
while the previous style still exists. Observe `data-map-style-ready` becoming
`"true"` to attach them again after the library restores its own layers.
Remove extension listeners when their LiveView hook is destroyed.

### Browser update gate

`createUpdateGate` is an optional, transport-independent browser send gate.
It calls `send(reason)` immediately on the first movement sample or an explicit
interaction, sooner on smoothed acceleration/direction changes, and every
500 ms when updates are pending. Movement-triggered early sends have a 35 ms
minimum interval; explicit interactions bypass it. No timer runs when idle.
Samples are CSS-pixel `[x, y]` positions, so behavior is independent of map zoom.

```js
import {createUpdateGate} from "phx_maplibre/editor";

const gate = createUpdateGate({send: () => flushQueuedUpdates()});
// After storing the latest cursor position:
canvas.addEventListener("pointermove", event => gate.sample([event.clientX, event.clientY]));
// After storing a click, release, insertion, or removal:
gate.request({immediate: true});
// For queued geometry changes without a new pointer sample:
gate.request();
```

The caller retains its payloads and operation queues; the gate never drops or
coalesces operations and does not implement transport backpressure. Keep one
request in flight if ordering requires it, and remember when a gated send is
waiting for that request. A reply alone should not trigger an ungated send.
`flush()` sends pending work immediately, `reset()` cancels pending scheduling
and movement history (e.g. on disconnect), and `destroy()` permanently stops
the gate. `setHeartbeatMs(ms)` changes the heartbeat at runtime and reschedules
pending work without clearing it. Acceleration approvals remain eligible for
earlier sends; the effective movement minimum is clamped to the heartbeat
when it is shorter than `minIntervalMs`. Remove your DOM listeners when
navigating away.

Options default to `heartbeatMs: 500`, `minIntervalMs: 35`,
`accelerationThreshold: 0.004` px/ms², `speedChangeThreshold: 0.12` px/ms,
`minDistance: 2` pixels, and `smoothingMs: 40`. Early movement sends require all
three thresholds. Timing functions `now`, `setTimeout`, and `clearTimeout`
can be injected for deterministic tests. This utility does not change the
map hook's existing event behavior unless an application explicitly uses it.

## License

EUPL-1.2, with an explicit clarification that commercial use — internal
business use, powering commercial SaaS, and paid services or support — is
permitted and encouraged. See
[LICENSE](https://github.com/weltenseglr/phx-maplibre/blob/main/apps/phx_maplibre/LICENSE).

Editor feature IDs use Terra Draw’s UUID4 strategy. Preserve those UUIDs in storage; application IDs can be stored in feature properties. Server-generated IDs also use UUID4.

Runtime limits apply to every document it owns: `max_features` (default 1,000),
`max_vertices` (default and maximum 1,000 live coordinates per feature), and
`max_payload_bytes` (default 262,144). The LiveView integration also accepts
`max_event_payload_bytes` (default 524,288). Draft checkpoints are sampled to
1,000 coordinates; history retains 100 gestures per actor. Completed geometry
is validated in full, so exceeding its coordinate limit rejects the commit.

Completed freehand polygons are first sampled to at most 1,000 vertices and
deduplicated in the browser. Valid rings keep their shape; invalid sampled
rings use their convex boundary when that produces a valid polygon. The
server still validates the submitted geometry and applies any lower runtime
limit.

```elixir
{PhxMaplibre.Editor.Runtime,
 name: MyApp.EditorRuntime, pubsub: MyApp.PubSub,
 max_features: 250, max_vertices: 500, max_payload_bytes: 131_072}
```
