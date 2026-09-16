import {emptyFeatureCollection} from "./sources_layers.js"

const featureId = (feature) => feature.id ?? feature.properties?.id
const collection = (features) => ({type: "FeatureCollection", features})

function setClusterFilter(hook, hiddenClusterId = null) {
  const filter = hiddenClusterId === null
    ? ["has", "point_count"]
    : ["all", ["has", "point_count"], ["!=", ["get", "cluster_id"], hiddenClusterId]]

  for (const layer of ["clusters", "cluster-count"]) {
    if (hook.map.getLayer(layer)) hook.map.setFilter(layer, filter)
  }
}

export function collapseSpider(hook) {
  hook.spiderRequestId = (hook.spiderRequestId || 0) + 1
  hook.spiderExpanded = false
  hook.spiderFeatures = new Map()
  hook.map.getSource("spider")?.setData(emptyFeatureCollection())
  setClusterFilter(hook)
}

export function expandClusterSpider(hook, cluster, leaves) {
  if (!leaves.length) return

  const center = hook.map.project(cluster.geometry.coordinates)
  const radius = Math.max(36, Math.min(80, leaves.length * 4))
  const features = []
  hook.spiderFeatures = new Map()

  leaves.forEach((original, index) => {
    const angle = -Math.PI / 2 + (index * Math.PI * 2) / leaves.length
    const pixel = {x: center.x + Math.cos(angle) * radius, y: center.y + Math.sin(angle) * radius}
    const lngLat = hook.map.unproject([pixel.x, pixel.y])
    const id = featureId(original)
    hook.spiderFeatures.set(id, original)
    features.push({
      type: "Feature",
      id: `line-${id}`,
      geometry: {type: "LineString", coordinates: [[lngLat.lng, lngLat.lat], original.geometry.coordinates]},
      properties: {},
    })
    features.push({
      type: "Feature",
      id,
      geometry: {type: "Point", coordinates: [lngLat.lng, lngLat.lat]},
      properties: {...(original.properties || {}), id},
    })
  })

  hook.spiderExpanded = true
  setClusterFilter(hook, cluster.properties.cluster_id)
  hook.map.getSource("spider")?.setData(collection(features))
}

export function originalSpiderFeature(hook, feature) {
  return hook.spiderFeatures.get(featureId(feature)) || feature
}