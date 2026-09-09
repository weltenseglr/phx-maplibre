import {STYLE_PROPS} from "./sources_layers.js"

export function escapeHTML(value) {
  const el = document.createElement("div")
  el.textContent = value
  return el.innerHTML
}

/**
 * Render the default popup for a feature: title, description, then one row per
 * remaining property, with paint properties and keys starting with `_` skipped.
 * Every value is HTML-escaped. There is deliberately no way for feature data
 * to inject markup here — rich popups go through the `popupContent` renderer
 * passed to `createMapHook`, which is application code, not data.
 */
export function buildPopupHTML(properties = {}) {
  const row = ([key, value]) =>
    `<div class="phx-maplibre-popup-row"><span class="phx-maplibre-popup-label">${escapeHTML(key)}</span><span class="phx-maplibre-popup-value">${escapeHTML(String(value))}</span></div>`

  const rows = Object.entries(properties)
    .filter(([key]) => !key.startsWith("_") && !["title", "description", "popupHTML"].includes(key) && !STYLE_PROPS.has(key))
    .map(row)
    .join("")

  return `<div class="phx-maplibre-popup">${properties.title ? `<h3 class="phx-maplibre-popup-title">${escapeHTML(properties.title)}</h3>` : ""}${properties.description ? `<p class="phx-maplibre-popup-desc">${escapeHTML(properties.description)}</p>` : ""}${rows ? `<div class="phx-maplibre-popup-details">${rows}</div>` : ""}</div>`
}

const isDOMNode = (value) =>
  value !== null && typeof value === "object" && typeof value.nodeType === "number"

function applyContent(hook, popup, feature) {
  const content = hook.popupContent ? hook.popupContent(feature) : undefined

  if (isDOMNode(content)) {
    popup.setDOMContent(content)
  } else {
    if (content !== undefined && content !== null) {
      console.warn("[phx_maplibre] popupContent must return a DOM Node (or null for the default popup); got", typeof content)
    }
    popup.setHTML(buildPopupHTML(feature.properties || {}))
  }
}

/**
 * Open the popup for a clicked feature. When the app supplied a
 * `popupContent` renderer, its returned DOM Node goes in via
 * `Popup#setDOMContent`; a nullish return falls back to the escaped default,
 * and any other return is ignored with a console warning. Without a renderer
 * the escaped default builder is used.
 *
 * The popup remembers which feature it belongs to (see `refreshPopup`), so
 * data updates re-anchor and re-render it instead of leaving it stale.
 */
export function showPopup(hook, lngLat, feature, kind = "point") {
  if (hook.popup) hook.popup.remove()

  const popup = new hook.maplibregl.Popup({closeButton: true, closeOnClick: false, maxWidth: "280px"})
    .setLngLat(lngLat)

  applyContent(hook, popup, feature)

  hook.popupFeatureId = feature.id ?? feature.properties?.id ?? null
  hook.popupKind = kind
  hook.popup = popup.addTo(hook.map)
}

/** Forget which feature the open popup belongs to (call wherever it closes). */
export function clearPopupTracking(hook) {
  hook.popupFeatureId = null
  hook.popupKind = null
}

/**
 * Re-sync the open popup after `set_features` / `set_area_features` replaced
 * a source's data: re-render its content from the feature's fresh properties
 * and, for point features, move the popup to the feature's new position. A
 * popup whose feature vanished from the data is closed.
 */
export function refreshPopup(hook, kind, geojson) {
  if (!hook.popup || hook.popupFeatureId == null || hook.popupKind !== kind) return

  const features = geojson?.features || []
  const feature = features.find((f) => (f.id ?? f.properties?.id) === hook.popupFeatureId)

  if (!feature) {
    hook.popup.remove()
    hook.popup = null
    clearPopupTracking(hook)
    return
  }

  if (kind === "point" && Array.isArray(feature.geometry?.coordinates)) {
    hook.popup.setLngLat(feature.geometry.coordinates)
  }

  applyContent(hook, hook.popup, feature)
}
