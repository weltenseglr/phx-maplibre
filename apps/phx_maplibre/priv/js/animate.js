import {refreshPopup} from "./popup.js"

// Animated position transitions between `set_features` updates.
//
// The browser holds NO simulation logic: the server streams plain
// (viewport-filtered) GeoJSON exactly as always. At zooms at or above
// `animate_min_zoom` (on by default; `false` opts out) the hook renders point
// features on a second, unclustered source whose positions tween linearly
// from where a feature was displayed to where the latest update says it is.
// Constant velocity matches how moving things actually travel between
// updates; the tween duration is the measured interval between updates, so
// motion stays continuous whatever the server's cadence.

// Hostile or runaway GeoJSON must not drive unbounded per-frame work: above
// this many features an update is NOT animated at all (the snapshot path
// renders it instead, exactly as below the zoom gate), and only ids that are
// strings of at most 128 chars or finite numbers participate in tweening.
const MAX_ANIMATED_FEATURES = 10_000
const MAX_ID_LENGTH = 128

const MIN_TWEEN_MS = 250
const MAX_TWEEN_MS = 15_000
const DEFAULT_TWEEN_MS = 5_000
// Frame-interval ladder by animated-feature count (inclusive upper bounds):
// every setData serializes the whole FeatureCollection to MapLibre's worker,
// so the budget is features x frames, not frames alone.
const FRAME_LADDER = [
  [1000, 33], // <= 1000 features -> ~30 fps
  [3000, 67], // <= 3000 features -> ~15 fps
]
const FRAME_MS_FLOOR = 200 // above the ladder -> 5 fps
const ZOOM_HYSTERESIS = 0.5

const featureId = (feature) => feature.id ?? feature.properties?.id

const animatableId = (id) =>
  (typeof id === "string" && id.length <= MAX_ID_LENGTH) ||
  (typeof id === "number" && Number.isFinite(id))

/** Fresh per-mount animation state. */
export function initAnimateState(hook) {
  hook.animEntries = new Map()
  hook.animFc = {type: "FeatureCollection", features: []}
  hook.animRaf = null
  hook.animLastFrame = -Infinity
  hook.animActive = false
  hook.animLastUpdateAt = null
  hook.pointsDirty = false
  hook.animOverCap = false
}

const animationConfigured = (hook) =>
  typeof hook.config.animateMinZoom === "number" && hook.config.clusterSpiderfyZoom === null

/**
 * Fold a `set_features` payload into the tween table. Existing features tween
 * from their currently displayed position to the new one; first-seen ids
 * appear in place; vanished ids drop. Properties always apply immediately.
 * With `tween: false` (initial load, style replay) everything snaps to its
 * target — there is nothing meaningful to animate from.
 */
export function updateAnimatedFeatures(hook, {tween = true} = {}) {
  if (!animationConfigured(hook)) return

  const features = hook.pointsData?.features || []

  // Over the cap: skip tweening entirely for this update and fall back to the
  // snapshot presentation until an update under the cap arrives.
  if (features.length > MAX_ANIMATED_FEATURES) {
    if (!hook.animOverCap) {
      console.warn(
        `[phx_maplibre] ${features.length} features exceed MAX_ANIMATED_FEATURES ` +
          `(${MAX_ANIMATED_FEATURES}); rendering as a snapshot without animation`,
      )
    }
    hook.animOverCap = true
    hook.animEntries = new Map()
    hook.animFc.features = []
    updateAnimateMode(hook)
    renderAnimateFrame(hook)
    return
  }
  hook.animOverCap = false

  const now = hook.now()
  const duration = tween ? measureDuration(hook, now) : 0

  const next = new Map()

  for (const feature of features) {
    const id = featureId(feature)
    const coords = feature.geometry?.coordinates
    if (!animatableId(id) || !Array.isArray(coords)) continue

    const previous = hook.animEntries.get(id)
    const displayed = previous ? previous.feature.geometry.coordinates : coords

    const entry = previous ?? {
      feature: {
        type: "Feature",
        id,
        geometry: {type: "Point", coordinates: [coords[0], coords[1]]},
        properties: {},
      },
    }

    entry.from = [displayed[0], displayed[1]]
    entry.to = [coords[0], coords[1]]
    entry.start = now
    entry.duration = previous && tween ? duration : 0
    entry.feature.properties = {...feature.properties, id}
    next.set(id, entry)
  }

  hook.animEntries = next
  hook.animFc.features = [...next.values()].map((entry) => entry.feature)

  // Mode first: the popup must only ride the tween while the animated layer
  // is the one actually displayed.
  updateAnimateMode(hook)
  renderAnimateFrame(hook)
}

// Tween duration = measured interval between consecutive updates, clamped.
function measureDuration(hook, now) {
  const previous = hook.animLastUpdateAt
  hook.animLastUpdateAt = now
  if (previous === null) return DEFAULT_TWEEN_MS
  return Math.min(Math.max(now - previous, MIN_TWEEN_MS), MAX_TWEEN_MS)
}

/** Lerp every feature toward its target; returns true while tweens run. */
export function renderAnimateFrame(hook) {
  if (!animationConfigured(hook)) return false

  const now = hook.now()
  let pending = false

  for (const entry of hook.animEntries.values()) {
    const progress = entry.duration > 0 ? Math.min((now - entry.start) / entry.duration, 1) : 1
    if (progress < 1) pending = true

    const coords = entry.feature.geometry.coordinates
    coords[0] = entry.from[0] + progress * (entry.to[0] - entry.from[0])
    coords[1] = entry.from[1] + progress * (entry.to[1] - entry.from[1])

    if (
      hook.animActive &&
      hook.popup &&
      hook.popupKind === "point" &&
      hook.popupFeatureId === entry.feature.id
    ) {
      hook.popup.setLngLat([coords[0], coords[1]])
    }
  }

  hook.map.getSource("animated")?.setData(hook.animFc)
  return pending
}

function setVisibility(map, layerId, visible) {
  if (map.getLayer(layerId)) {
    map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none")
  }
}

/**
 * Zoom-gated hybrid: at/above `animate_min_zoom` the animated source shows and
 * the snapshot point layers hide; half a zoom level below they flip back.
 * Inside the hysteresis band the current mode sticks. Unconfigured maps
 * (`animate_min_zoom` nil) never enter this mode at all.
 */
export function updateAnimateMode(hook) {
  if (!hook.map || !animationConfigured(hook)) return

  const hasFeatures = hook.animEntries.size > 0 && !hook.animOverCap
  const zoom = hook.map.getZoom()
  const minZoom = hook.config.animateMinZoom

  const wasActive = hook.animActive === true
  let active = wasActive
  if (!hook.ready || !hasFeatures) active = false
  else if (zoom >= minZoom) active = true
  else if (zoom < minZoom - ZOOM_HYSTERESIS) active = false

  hook.animActive = active

  // While animation was active, set_features skipped the hidden clustered
  // source (rebuilding/reclustering up to the whole viewport for nothing).
  // Flush the stash once, before the snapshot layers become visible again.
  if (wasActive && !active && hook.pointsDirty) {
    hook.map.getSource("points")?.setData(hook.pointsData)
    refreshPopup(hook, "point", hook.pointsData)
    hook.pointsDirty = false
  }
  setVisibility(hook.map, "animated-points", active)
  for (const id of ["clusters", "cluster-count", "unclustered-points"]) {
    setVisibility(hook.map, id, !active)
  }

  if (active) startAnimateLoop(hook)
  else stopAnimateLoop(hook)
}

/**
 * The frame loop. Idles (stops itself) once every tween has completed — the
 * next `set_features` restarts it — so a quiet map costs nothing.
 */
export function startAnimateLoop(hook) {
  if (hook.animRaf != null) return

  const step = () => {
    hook.animRaf = hook.raf(step)
    const nowPerf = hook.now()
    if (nowPerf - hook.animLastFrame < frameInterval(hook.animEntries.size)) return
    hook.animLastFrame = nowPerf

    const pending = renderAnimateFrame(hook)
    if (!pending) stopAnimateLoop(hook)
  }

  hook.animLastFrame = -Infinity
  hook.animRaf = hook.raf(step)
}

/** Frame interval for a given animated-feature count, per the ladder. */
export function frameInterval(count) {
  for (const [maxCount, ms] of FRAME_LADDER) {
    if (count <= maxCount) return ms
  }
  return FRAME_MS_FLOOR
}

export function stopAnimateLoop(hook) {
  if (hook.animRaf == null) return
  hook.caf(hook.animRaf)
  hook.animRaf = null
}
