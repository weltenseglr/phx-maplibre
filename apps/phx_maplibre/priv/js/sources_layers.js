export const STYLE_PROPS = new Set([
  "fill-color", "fill-opacity", "fill-outline-color", "fill-pattern", "circle-color", "circle-radius", "circle-opacity", "circle-stroke-color", "circle-stroke-width", "line-color", "line-width", "line-opacity", "line-dasharray", "text-color", "text-size", "text-opacity", "text-halo-color", "text-halo-width", "icon-image", "icon-size", "icon-opacity", "background-color", "background-opacity", "raster-opacity", "hillshade-illumination-direction", "hillshade-exaggeration",
])

export const emptyFeatureCollection = () => ({type: "FeatureCollection", features: []})
export const CLUSTER_MAX_ZOOM = 14
export const PERSISTENT_CLUSTER_MAX_ZOOM = 23
const GEOJSON_MAX_ZOOM = 24

export const clusterMaxZoom = (clusterSpiderfyZoom = null) =>
  typeof clusterSpiderfyZoom === "number" ? PERSISTENT_CLUSTER_MAX_ZOOM : CLUSTER_MAX_ZOOM

/** Add the GeoJSON sources used by the map, unless the style already has them. */
export function addSources(map, cluster, clusterSpiderfyZoom = null) {
  if (!map.getSource("points")) {
    const points = {type: "geojson", data: emptyFeatureCollection(), cluster, clusterMaxZoom: clusterMaxZoom(clusterSpiderfyZoom), clusterRadius: 50, promoteId: "id"}
    if (typeof clusterSpiderfyZoom === "number") points.maxzoom = GEOJSON_MAX_ZOOM
    map.addSource("points", points)
  }
  if (!map.getSource("areas")) map.addSource("areas", {type: "geojson", data: emptyFeatureCollection(), promoteId: "id"})
  // The animated source is never clustered — it is fed per frame while tweening.
  if (!map.getSource("animated")) map.addSource("animated", {type: "geojson", data: emptyFeatureCollection(), promoteId: "id"})
  if (typeof clusterSpiderfyZoom === "number") {
    if (!map.getSource("spider")) map.addSource("spider", {type: "geojson", data: emptyFeatureCollection(), promoteId: "id"})
  }
}

/**
 * Add the presentation layers on top of those sources: area fill, outline and
 * highlight, the two cluster layers when clustering is on, and the point
 * circles. Paint expressions prefer a feature's own value for the property
 * over the library default, and fold hover and selection in as feature-state
 * cases.
 */
export function addLayers(map, cluster, clusterColor = null, clusterSpiderfy = false) {
  const add = (layer) => { if (!map.getLayer(layer.id)) map.addLayer(layer) }
  add({id: "area-fill", type: "fill", source: "areas", paint: {"fill-color": ["coalesce", ["get", "fill-color"], "#6366f1"], "fill-opacity": ["case", ["boolean", ["feature-state", "selected"], false], .55, ["boolean", ["feature-state", "hover"], false], .4, ["coalesce", ["get", "fill-opacity"], .2]]}})
  add({id: "area-outline", type: "line", source: "areas", paint: {"line-color": ["coalesce", ["get", "line-color"], "#6366f1"], "line-width": ["coalesce", ["get", "line-width"], 2], "line-opacity": ["coalesce", ["get", "line-opacity"], .5]}})
  add({id: "area-highlight", type: "line", source: "areas", paint: {"line-color": ["case", ["boolean", ["feature-state", "selected"], false], "#111827", "#374151"], "line-width": ["case", ["boolean", ["feature-state", "selected"], false], 3, 2], "line-opacity": ["case", ["boolean", ["feature-state", "hover"], false], .9, ["boolean", ["feature-state", "selected"], false], .9, 0]}, layout: {"line-join": "round", "line-cap": "round"}})
  if (cluster) {
    // A configured clusterColor replaces the size-stepped palette with one
    // brand color (hover keeps its own tint); count text goes dark to match.
    const clusterFill = clusterColor
      ? ["case", ["boolean", ["feature-state", "hover"], false], clusterColor, clusterColor]
      : ["case", ["boolean", ["feature-state", "hover"], false], "#f97316", ["step", ["get", "point_count"], "#51bbd6", 100, "#f1f075", 750, "#f28cb1"]]
    const strokeColor = clusterColor ? "#0a0b0d" : "#ffffff"
    const countColor = clusterColor ? "#0a0b0d" : "#1f2937"

    add({id: "clusters", type: "circle", source: "points", filter: ["has", "point_count"], paint: {"circle-color": clusterFill, "circle-radius": ["case", ["boolean", ["feature-state", "hover"], false], ["step", ["get", "point_count"], 24, 100, 35, 750, 48], ["step", ["get", "point_count"], 18, 100, 28, 750, 40]], "circle-stroke-width": 2, "circle-stroke-color": strokeColor, "circle-opacity": clusterColor ? ["case", ["boolean", ["feature-state", "hover"], false], 1, 0.85] : 1}})
    add({id: "cluster-count", type: "symbol", source: "points", filter: ["has", "point_count"], layout: {"text-field": "{point_count_abbreviated}", "text-size": 12, "text-allow-overlap": true}, paint: {"text-color": countColor}})
  }
  add({id: "unclustered-points", type: "circle", source: "points", filter: ["!", ["has", "point_count"]], paint: {"circle-color": ["case", ["boolean", ["feature-state", "selected"], false], "#ef4444", ["boolean", ["feature-state", "linked"], false], "#f97316", ["boolean", ["feature-state", "hover"], false], "#22c55e", ["coalesce", ["get", "circle-color"], "#6366f1"]], "circle-radius": ["case", ["boolean", ["feature-state", "selected"], false], 10, ["boolean", ["feature-state", "linked"], false], 9, ["boolean", ["feature-state", "hover"], false], 9, ["coalesce", ["get", "circle-radius"], 7]], "circle-stroke-width": ["coalesce", ["get", "circle-stroke-width"], 2], "circle-stroke-color": ["coalesce", ["get", "circle-stroke-color"], "#ffffff"], "circle-opacity": ["coalesce", ["get", "circle-opacity"], .9]}})
  // Same paint as unclustered-points so the zoom-gated mode flip is invisible;
  // hidden until the animation mode activates it.
  add({id: "animated-points", type: "circle", source: "animated", layout: {visibility: "none"}, paint: {"circle-color": ["case", ["boolean", ["feature-state", "selected"], false], "#ef4444", ["boolean", ["feature-state", "linked"], false], "#f97316", ["boolean", ["feature-state", "hover"], false], "#22c55e", ["coalesce", ["get", "circle-color"], "#6366f1"]], "circle-radius": ["case", ["boolean", ["feature-state", "selected"], false], 10, ["boolean", ["feature-state", "linked"], false], 9, ["boolean", ["feature-state", "hover"], false], 9, ["coalesce", ["get", "circle-radius"], 7]], "circle-stroke-width": ["coalesce", ["get", "circle-stroke-width"], 2], "circle-stroke-color": ["coalesce", ["get", "circle-stroke-color"], "#ffffff"], "circle-opacity": ["coalesce", ["get", "circle-opacity"], .9]}})
  if (clusterSpiderfy) {
    add({id: "spider-lines", type: "line", source: "spider", filter: ["==", ["geometry-type"], "LineString"], paint: {"line-color": "#94a3b8", "line-width": 2, "line-opacity": .9}})
    add({id: "spider-points", type: "circle", source: "spider", filter: ["==", ["geometry-type"], "Point"], paint: {"circle-color": ["case", ["boolean", ["feature-state", "selected"], false], "#ef4444", ["boolean", ["feature-state", "hover"], false], "#22c55e", ["coalesce", ["get", "circle-color"], "#6366f1"]], "circle-radius": ["case", ["boolean", ["feature-state", "selected"], false], 10, ["boolean", ["feature-state", "hover"], false], 9, ["coalesce", ["get", "circle-radius"], 7]], "circle-stroke-width": ["coalesce", ["get", "circle-stroke-width"], 2], "circle-stroke-color": ["coalesce", ["get", "circle-stroke-color"], "#ffffff"], "circle-opacity": .95}})
  }
}
