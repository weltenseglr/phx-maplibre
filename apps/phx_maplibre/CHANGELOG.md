# Changelog

## 0.2.0 (2026-09-16)

Cluster spiderfying.

- Added the optional `cluster_spiderfy_zoom` component attribute. Below the
  configured zoom, a cluster click zooms no farther than the threshold; at or
  above it, the cluster expands into individually selectable points with
  leader lines.
- Clustering remains active throughout MapLibre's normal map zoom range when
  cluster spiderfying is configured. Animated point presentation is disabled
  in this mode so one source owns the visible point state.
- Spiderfied selections preserve the original GeoJSON feature, including its
  stable id, coordinates, and properties.
- Expansion now hides only the selected native cluster and restores it on
  zoom, source updates, style changes, or a background click. Stale
  `getClusterLeaves` responses are ignored after the interaction is canceled.
- Fixed cluster clicks jumping directly to maximum zoom when their calculated
  expansion zoom exceeded the spiderfy threshold.

## 0.1.0 (2026-09-10)

Animated position transitions.

- Hardened the browser event boundary: known event payloads are structurally
  validated before delivery, malformed messages are dropped with
  `[:phx_maplibre, :event_dropped]` telemetry, and the server's default event
  allowlist now matches the component's default configuration.
- Declared the shipped JavaScript as native ESM, narrowed the MapLibre peer
  range to the supported v5 major, and declared Phoenix as a direct compile
  dependency. CI now smoke-tests the built Hex tarball as an external
  dependency and verifies that a release tag matches the package version.

- Point features now move smoothly by default: at zooms at or above the new
  `animate_min_zoom` component attribute (default `12`; `false` disables),
  each `set_features` update renders on an unclustered animated source that
  tweens every feature — matched by `id` — linearly from its displayed
  position to its new one over the measured interval between updates
  (clamped 250 ms – 15 s). Below the threshold the clustered snapshot
  renders as before, with half a zoom level of hysteresis between modes.
  The browser holds no simulation logic; the server keeps streaming plain,
  viewport-filtered GeoJSON.
- First-seen features appear in place, vanished ids drop immediately, and
  properties always apply immediately — only positions tween. Interaction
  parity is complete on the animated source: feature-state hover/select,
  popups riding their moving feature, `:feature_selected` with the position
  at click time, and style-swap survival.
- The animation loop idles once every feature reaches its target and wakes
  on the next update; above ~1,500 animated features it degrades from 30 to
  10 frames per second.
- `createMapHook` gained `now`/`raf`/`caf` timing seams (test injection;
  production defaults unchanged).

A PubSub-first MapLibre GL JS integration for Phoenix LiveView:

- `PhxMaplibre.Components.map/1` renders a map as a stateless function
  component configured through a single JSON `data-config` attribute.
- `use PhxMaplibre.LiveView` + `attach_map/3` wire the owning LiveView up via
  `attach_hook/4`. Consumers write no `handle_event/3` clauses: whitelisted map
  interactions are relayed to a per-map PubSub events topic and arrive as
  `%PhxMaplibre.Event{}` in `handle_info/2`.
- Any process can drive any map by broadcasting a `%PhxMaplibre.Command{}` to
  the map's commands topic — `PhxMaplibre.set_features/3`, `fly_to/3`,
  `fit_bounds/3`, `set_style/3`, and friends. Each command also has a
  socket-first fast path that skips PubSub for hot paths.
- GeoJSON is the exchange format in both directions: features go in as GeoJSON
  FeatureCollections, and `:feature_selected` hands the clicked feature back
  as a GeoJSON Feature, geometry and properties untouched.
- The JS side ships as ES modules with a `createMapHook(maplibregl)` factory;
  `maplibre-gl` stays a peer dependency of the consuming app. Clustering,
  feature-state hover/select, exact-once hover transition events, an escaped
  default popup (rich popups via an explicit `popupContent` DOM-node renderer
  on `createMapHook` — feature data can never inject markup), and
  light/dark style switching (with source, layer, and
  feature-state restoration) are built in.
- Telemetry: `[:phx_maplibre, :event]` and `[:phx_maplibre, :command]`.
