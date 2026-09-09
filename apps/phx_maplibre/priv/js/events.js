/** Push a map event to the owning LiveView, unless the config's whitelist leaves it out. */
export function pushMapEvent(hook, name, payload) {
  if (hook.config.events.includes(name)) {
    hook.pushEvent("maplibre:event", {id: hook.mapId, event: name, payload})
  }
}

/** Current bounds, center and zoom — the payload shared by `ready` and `move_end`. */
export function viewportPayload(map) {
  const bounds = map.getBounds()
  const center = map.getCenter()
  return {
    bounds: {west: bounds.getWest(), south: bounds.getSouth(), east: bounds.getEast(), north: bounds.getNorth()},
    center: {lng: center.lng, lat: center.lat}, zoom: map.getZoom(),
  }
}
