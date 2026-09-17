const equal = (a, b) => a.length === b.length && a.every((n, i) => Math.abs(n - b[i]) < 1e-10)
const sameRing = (a, b) => a.length === b.length && a.every((p, i) => equal(p, b[i]))
export const vertexState = feature => ({ids: [...feature.properties.vertex_ids], coordinates: feature.geometry.coordinates[0].slice(0, -1).map(p => [...p])})

// The MapLibre adapter requires at most nine decimals. Keep the authoritative
// geometry intact, and compare gestures against the exact geometry Terra owns.
export function editingFeature(feature) {
  return {...feature, geometry: {...feature.geometry, coordinates: feature.geometry.coordinates.map(ring => ring.map(p => p.map(n => Number(n.toFixed(9)))))}}
}

// Terra Draw owns gesture indices. Translate those indices to permanent IDs
// against the last local gesture geometry, never against a newer remote ring.
export function geometryOperations(previous, geometry, newId = () => crypto.randomUUID()) {
  const coordinates = geometry.coordinates[0].slice(0, -1).map(p => [...p])
  const old = previous.coordinates
  let ids = [...previous.ids], operations = []
  if (coordinates.length === old.length) {
    const delta = coordinates[0].map((n, i) => n - old[0][i])
    if (coordinates.every((p, i) => equal(p.map((n, j) => n - old[i][j]), delta))) {
      if (!equal(delta, [0, 0])) operations = [{type: "translate", delta}]
    } else {
      operations = coordinates.flatMap((p, i) => equal(p, old[i]) ? [] : [{type: "move", vertex_id: ids[i], coordinate: p}])
    }
  } else if (coordinates.length === old.length + 1) {
    const index = coordinates.findIndex((_, i) => sameRing(coordinates.filter((_, j) => i !== j), old))
    if (index < 0) throw new Error("Could not identify the inserted vertex.")
    const id = newId(), after = ids[(index - 1 + ids.length) % ids.length]
    operations = [{type: "insert", vertex_id: id, after_id: after, coordinate: coordinates[index]}]
    ids.splice(index, 0, id)
  } else if (coordinates.length === old.length - 1) {
    const index = old.findIndex((_, i) => sameRing(old.filter((_, j) => i !== j), coordinates))
    if (index < 0) throw new Error("Could not identify the removed vertex.")
    operations = [{type: "remove", vertex_id: ids[index]}]
    ids.splice(index, 1)
  } else {
    throw new Error("Unsupported polygon gesture. Select the polygon again to refresh its vertices.")
  }
  return {state: {ids, coordinates}, operations}
}

export function optimisticFeature(feature, operations) {
  const state = vertexState(feature)
  for (const operation of operations) {
    const index = state.ids.indexOf(operation.vertex_id)
    if (operation.type === "move" && index >= 0) state.coordinates[index] = operation.coordinate
    else if (operation.type === "remove" && index >= 0) { state.ids.splice(index, 1); state.coordinates.splice(index, 1) }
    else if (operation.type === "insert" && index < 0) {
      const anchor = state.ids.indexOf(operation.after_id)
      if (anchor >= 0) { state.ids.splice(anchor + 1, 0, operation.vertex_id); state.coordinates.splice(anchor + 1, 0, operation.coordinate) }
    } else if (operation.type === "translate") state.coordinates = state.coordinates.map(p => p.map((n, i) => n + operation.delta[i]))
  }
  return {...feature, properties: {...feature.properties, vertex_ids: state.ids}, geometry: {type: "Polygon", coordinates: [[...state.coordinates, ...state.coordinates.slice(0, 1)]]}}
}
