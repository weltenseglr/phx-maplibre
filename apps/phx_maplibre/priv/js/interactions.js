import {pushMapEvent, viewportPayload} from "./events.js"
import {clearPopupTracking, showPopup} from "./popup.js"

/**
 * GeoJSON is the exchange format: the payload carries the feature exactly as
 * the map knows it (geometry and properties untouched), with id, kind, and a
 * representative coordinate alongside for cheap pattern matching.
 */
function featurePayload(feature, kind) {
  const props = feature.properties || {}

  return {
    id: feature.id ?? props.id,
    kind,
    lng: feature.geometry?.coordinates?.[0],
    lat: feature.geometry?.coordinates?.[1],
    feature: {
      type: "Feature",
      id: feature.id ?? props.id,
      geometry: feature.geometry ?? null,
      properties: props,
    },
  }
}

const POINT_SOURCES = ["points", "animated"]

function hoverPayload(feature, kind) {
  return {id: feature.id ?? feature.properties?.id, kind, title: feature.properties?.title ?? null}
}

// `source` may be one id or a list: point features live on both the snapshot
// ("points") and animated sources, and their hover/selection state must stay
// in lockstep so the zoom-gate flip never drops styling (promoteId "id" makes
// the same feature id valid on both).
function setState(hook, source, id, value) {
  if (id === null || id === undefined) return
  for (const src of Array.isArray(source) ? source : [source]) {
    hook.map.setFeatureState({source: src, id}, value)
  }
}

// A feature may opt into a secondary selection highlight by naming another
// feature id in its `linked-id` property. The relationship is deliberately
// data-driven: consumers can use it for partners, related assets, or any
// other paired map feature without adding a new event contract.
function linkedId(feature) {
  return feature.properties?.["linked-id"] ?? null
}

/**
 * Turn a layer's raw mousemove stream into one event per hover transition.
 * Entering a feature emits a single `feature_hovered`; going straight from
 * feature A onto feature B emits `feature_unhovered` for A before
 * `feature_hovered` for B; further mousemove ticks inside the same feature emit
 * nothing. Pass `emit: false` to keep the feature-state bookkeeping and skip
 * the events, as the cluster layer does.
 */
function bindHoverTransitions(hook, layer, source, kind, key, emit = true) {
  hook.map.on("mousemove", layer, (event) => {
    if (hook.styleReloading) return
    hook.map.getCanvas().style.cursor = "pointer"

    const feature = event.features?.[0]
    if (!feature || hook[key] === feature.id) return

    if (hook[key] !== null) {
      setState(hook, source, hook[key], {hover: false})
      const previous = hook[`${key}Feature`]
      if (emit && previous) pushMapEvent(hook, "feature_unhovered", hoverPayload(previous, kind))
    }

    hook[key] = feature.id
    hook[`${key}Feature`] = feature
    setState(hook, source, feature.id, {hover: true})
    if (emit) pushMapEvent(hook, "feature_hovered", hoverPayload(feature, kind))
  })

  hook.map.on("mouseleave", layer, () => {
    if (hook.styleReloading) return
    hook.map.getCanvas().style.cursor = ""

    if (hook[key] !== null) {
      setState(hook, source, hook[key], {hover: false})
      const feature = hook[`${key}Feature`]
      if (emit && feature) pushMapEvent(hook, "feature_unhovered", hoverPayload(feature, kind))
      hook[key] = null
      hook[`${key}Feature`] = null
    }
  })
}

function select(hook, source, kind, key, feature) {
  if (hook[key] !== null && hook[key] !== feature.id) {
    setState(hook, source, hook[key], {selected: false})
    setState(hook, source, hook[`${key}LinkedId`], {linked: false})
    pushMapEvent(hook, "feature_deselected", {id: hook[key], kind})
  }
  hook[key] = feature.id
  hook[`${key}LinkedId`] = linkedId(feature)
  setState(hook, source, feature.id, {selected: true})
  setState(hook, source, hook[`${key}LinkedId`], {linked: true})
}

function deselect(hook, source, kind, key) {
  if (hook[key] === null) return
  setState(hook, source, hook[key], {selected: false})
  setState(hook, source, hook[`${key}LinkedId`], {linked: false})
  pushMapEvent(hook, "feature_deselected", {id: hook[key], kind})
  hook[key] = null
  hook[`${key}LinkedId`] = null
}

function removePopup(hook) {
  if (hook.popup) {
    hook.popup.remove()
    hook.popup = null
    clearPopupTracking(hook)
  }
}

function bindClusterInteractions(hook) {
  const {map} = hook

  map.on("click", "clusters", async (event) => {
    if (hook.styleReloading) return
    const feature = event.features?.[0]
    if (!feature) return

    const id = feature.properties.cluster_id
    try {
      const zoom = await map.getSource("points").getClusterExpansionZoom(id)
      map.easeTo({center: feature.geometry.coordinates, zoom})
      pushMapEvent(hook, "cluster_selected", {
        cluster_id: id,
        point_count: feature.properties.point_count,
        center: {lng: feature.geometry.coordinates[0], lat: feature.geometry.coordinates[1]},
      })
    } catch (_) {
      // the cluster may have dissolved between click and expansion query
    }
  })

  bindHoverTransitions(hook, "clusters", "points", "cluster", "hoveredClusterId", false)
}

/**
 * Wire up clicks, hovers, viewport moves, and click-on-empty-map deselection.
 * Call once, after the initial style has loaded and the layers exist.
 */
export function bindInteractions(hook) {
  const {map} = hook

  if (hook.config.cluster && map.getLayer("clusters")) bindClusterInteractions(hook)

  map.on("click", "unclustered-points", (event) => {
    if (hook.styleReloading) return
    const feature = event.features?.[0]
    if (!feature) return

    showPopup(hook, event.lngLat, feature, "point")
    select(hook, POINT_SOURCES, "point", "selectedPointId", feature)
    pushMapEvent(hook, "feature_selected", featurePayload(feature, "point"))
  })
  bindHoverTransitions(hook, "unclustered-points", POINT_SOURCES, "point", "hoveredPointId")

  // Animated points behave exactly like unclustered points: same kind, same
  // payload contract, same shared hover/selection state; the geometry is the
  // position at click time. Only one of the two layers is visible at a time.
  map.on("click", "animated-points", (event) => {
    if (hook.styleReloading) return
    const feature = event.features?.[0]
    if (!feature) return

    showPopup(hook, event.lngLat, feature, "point")
    select(hook, POINT_SOURCES, "point", "selectedPointId", feature)
    pushMapEvent(hook, "feature_selected", featurePayload(feature, "point"))
  })
  bindHoverTransitions(hook, "animated-points", POINT_SOURCES, "point", "hoveredPointId")

  map.on("click", "area-fill", (event) => {
    if (hook.styleReloading) return
    const feature = event.features?.[0]
    if (!feature) return

    // A second click on the selected area toggles it off.
    if (hook.selectedAreaId === feature.id) {
      deselect(hook, "areas", "area", "selectedAreaId")
      removePopup(hook)
      return
    }

    showPopup(hook, event.lngLat, feature, "area")
    select(hook, "areas", "area", "selectedAreaId", feature)
    pushMapEvent(hook, "feature_selected", {
      ...featurePayload(feature, "area"),
      lng: event.lngLat.lng,
      lat: event.lngLat.lat,
    })
  })
  bindHoverTransitions(hook, "area-fill", "areas", "area", "hoveredAreaId")

  map.on("moveend", () => {
    const now = Date.now()
    if (now - hook.lastMoveEnd < hook.config.moveEndThrottleMs) return
    hook.lastMoveEnd = now
    pushMapEvent(hook, "move_end", viewportPayload(map))
  })

  map.on("click", (event) => {
    const interactive = map.queryRenderedFeatures(event.point, {
      layers: ["unclustered-points", "area-fill", "clusters", "animated-points"].filter((id) =>
        map.getLayer(id),
      ),
    })
    if (hook.styleReloading || interactive.length) return

    deselect(hook, POINT_SOURCES, "point", "selectedPointId")
    deselect(hook, "areas", "area", "selectedAreaId")
    removePopup(hook)
  })
}
