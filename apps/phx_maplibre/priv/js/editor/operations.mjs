const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b)
export const clone = value => JSON.parse(JSON.stringify(value))
export const isHelperFeature = feature => ["midPoint", "selectionPoint", "closingPoint", "snappingPoint", "coordinatePoint"].some(key => feature.properties?.[key])
// Terra Draw 1.33 reserves these keys for its own modes. They may be supplied
// when restoring a feature, but never passed to updateFeatureProperties.
const reservedProperties = new Set(["mode", "currentlyDrawing", "edited", "closingPoint", "snappingPoint", "coordinatePoint", "coordinatePointFeatureId", "coordinatePointIds", "provisionalCoordinateCount", "committedCoordinateCount", "marker", "selected", "midPoint", "selectionPointFeatureId", "selectionPoint"])
export const mutableProperties = properties => Object.fromEntries(Object.entries(properties).filter(([key]) => !reservedProperties.has(key)))
export function takeGestureBatch(operations) {
  const gesture_id = operations[0]?.__gesture_id
  const boundary = operations.findIndex(operation => operation.__gesture_id !== gesture_id)
  const size = boundary < 0 ? operations.length : boundary
  return {gesture_id, operations: operations.slice(0, size).map(({__gesture_id, ...operation}) => operation), remaining: operations.slice(size)}
}

// Early polygon drafts are degenerate rings. Render their actual dimensionality
// so collaborators can see the very first interaction.
export function previewFeature(feature) {
  const result = clone(feature)
  if (result.geometry.type !== "Polygon") return result
  const ring = result.geometry.coordinates[0] || []
  const seen = new Set()
  const unique = ring.filter(coordinate => { const key = JSON.stringify(coordinate); if (seen.has(key)) return false; seen.add(key); return true })
  if (unique.length === 1) result.geometry = {type: "Point", coordinates: unique[0]}
  else if (unique.length === 2) result.geometry = {type: "LineString", coordinates: unique}
  return result
}
export function boundedPreview(feature, maxCoordinates = 1000) {
  const result = clone(feature), geometry = result.geometry
  const sample = (coordinates, limit) => coordinates.length <= limit ? coordinates : Array.from({length: limit}, (_, index) => coordinates[Math.round(index * (coordinates.length - 1) / (limit - 1))])
  if (geometry.type === "LineString") geometry.coordinates = sample(geometry.coordinates, maxCoordinates)
  else if (geometry.type === "Polygon") {
    const budget = Math.max(4, Math.floor(maxCoordinates / geometry.coordinates.length))
    geometry.coordinates = geometry.coordinates.map(ring => {
      const closed = ring.length > 1 && equal(ring[0], ring.at(-1))
      const sampled = sample(closed ? ring.slice(0, -1) : ring, closed ? budget - 1 : budget)
      return closed ? [...sampled, sampled[0]] : sampled
    })
  }
  return result
}
export function coordinateState(feature, metadata = {}, newId = () => crypto.randomUUID()) {
  const geometry = feature.geometry
  const coordinates = geometry.type === "Point" ? [geometry.coordinates] : geometry.type === "LineString" ? geometry.coordinates :
    geometry.type === "Polygon" && geometry.coordinates.length === 1 ? geometry.coordinates[0].slice(0, -1) : null
  if (!coordinates) return null
  return {ids: coordinates.map((_, i) => metadata.vertex_ids?.[i] || newId()), coordinates: clone(coordinates), type: geometry.type}
}
export function geometryOperations(previous, feature, metadata = {}, newId = () => crypto.randomUUID()) {
  const next = coordinateState(feature, {}, newId)
  if (!previous || !next || previous.type !== next.type) return {state: next, operations: [{type: "replace_geometry", geometry: clone(feature.geometry), expected_version: metadata.version}]}
  const old = previous.coordinates, coordinates = next.coordinates, ids = [...previous.ids]
  let operations
  if (old.length === coordinates.length) {
    const delta = coordinates[0].map((n, i) => n - old[0][i])
    const translates = coordinates.every((p, i) => p.every((n, j) => Math.abs(n - old[i][j] - delta[j]) < 1e-9))
    operations = translates && delta.some(n => Math.abs(n) > 1e-10) ? [{type: "translate", delta}] : coordinates.flatMap((p, i) => equal(p, old[i]) ? [] : [{type: "move", vertex_id: ids[i], coordinate: p}])
  } else if (coordinates.length === old.length + 1) {
    const index = coordinates.findIndex((_, i) => equal(coordinates.filter((_, j) => i !== j), old))
    if (index < 0) return {state: next, operations: [{type: "replace_geometry", geometry: clone(feature.geometry), expected_version: metadata.version}]}
    const id = newId(), after = index === 0 && previous.type === "LineString" ? null : ids[(index - 1 + ids.length) % ids.length]
    operations = [{type: "insert", vertex_id: id, after_id: after, coordinate: coordinates[index]}]
    ids.splice(index, 0, id)
  } else if (coordinates.length === old.length - 1) {
    const index = old.findIndex((_, i) => equal(old.filter((_, j) => i !== j), coordinates))
    if (index < 0) return {state: next, operations: [{type: "replace_geometry", geometry: clone(feature.geometry), expected_version: metadata.version}]}
    operations = [{type: "remove", vertex_id: ids[index]}]; ids.splice(index, 1)
  } else return {state: next, operations: [{type: "replace_geometry", geometry: clone(feature.geometry), expected_version: metadata.version}]}
  return {state: {...next, ids}, operations}
}
export function editingFeature(feature, metadata = {}) {
  const round = value => Array.isArray(value) ? value.map(round) : Number(value.toFixed(9))
  return {...clone(feature), geometry: {...feature.geometry, coordinates: round(feature.geometry.coordinates)}, properties: {...feature.properties, ...(metadata.properties || {}), mode: metadata.mode || feature.properties?.mode || "polygon"}}
}
export function acceptSnapshot(current, incoming, syncing = false) {
  if (!incoming || !Number.isInteger(incoming.revision)) return "ignore"
  if (!current || current.generation !== incoming.generation) return "replace"
  if (incoming.revision < current.revision) return "ignore"
  if (!syncing && incoming.revision > current.revision + 1) return "sync"
  return "replace"
}

// Match authoritative ordering, including invisible tombstone insertion anchors.
export function projectFeature(feature, metadata, operations = []) {
  const result = clone(feature), meta = clone(metadata)
  const nodes = meta.nodes || {}
  for (const op of operations) {
    const node = nodes[op.vertex_id]
    if (op.type === "move" && node && !node.deleted) node.coordinate = clone(op.coordinate)
    else if (op.type === "remove" && node) node.deleted = true
    else if (op.type === "insert" && !node && (op.after_id == null || nodes[op.after_id])) nodes[op.vertex_id] = {id:op.vertex_id, after:op.after_id, coordinate:clone(op.coordinate), seed:false, deleted:false}
    else if (op.type === "translate") {
      for (const node of Object.values(nodes)) if (!node.deleted) node.coordinate = node.coordinate.map((n,i) => n + op.delta[i])
    }
    else if (op.type === "properties") Object.assign(result.properties, op.properties)
    else if (op.type === "mode_properties") meta.properties = {...meta.properties, ...op.properties}
    else if (op.type === "replace_geometry") return {feature:{...result,geometry:clone(op.geometry)},metadata:meta}
  }
  const children = new Map()
  for (const node of Object.values(nodes)) { const list = children.get(node.after) || []; list.push(node); children.set(node.after,list) }
  const walk = anchor => (children.get(anchor) || []).sort((a,b) => Number(a.seed)-Number(b.seed) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)).flatMap(node => [node,...walk(node.id)])
  const visible = walk(null).filter(node => !node.deleted), coordinates = visible.map(node => node.coordinate)
  meta.nodes = nodes; meta.vertex_ids = visible.map(node => node.id)
  result.geometry = {type:feature.geometry.type, coordinates:feature.geometry.type === "Point" ? coordinates[0] : feature.geometry.type === "LineString" ? coordinates : [[...coordinates,coordinates[0]]]}
  return {feature:result,metadata:meta}
}
