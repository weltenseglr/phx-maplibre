import {area} from "@turf/area"
import {length} from "@turf/length"
import {polygonToLine} from "@turf/polygon-to-line"

export function polygonMetrics(feature) {
  const vertices = feature.geometry.coordinates[0].slice(0, -1)
  return {vertices, edges: vertices.length, perimeter: length(polygonToLine(feature), {units: "meters"}), area: area(feature)}
}

export function infoCard(feature) {
  const metrics = polygonMetrics(feature)
  const card = document.createElement("div")
  card.className = "polygon-info"
  const title = document.createElement("h3")
  title.textContent = feature.properties.name || "New polygon"
  title.className = "font-semibold"
  card.append(title)
  const dl = document.createElement("dl")
  const distance = metrics.perimeter >= 1000 ? `${(metrics.perimeter / 1000).toFixed(2)} km` : `${metrics.perimeter.toFixed(1)} m`
  const surface = metrics.area >= 1e6 ? `${(metrics.area / 1e6).toFixed(2)} km²` : `${metrics.area.toFixed(1)} m²`
  for (const [label, value] of [["Edges", metrics.edges], ["Vertices", metrics.vertices.length], ["Circumference", distance], ["Area", surface]]) {
    const dt = document.createElement("dt")
    dt.textContent = label
    const dd = document.createElement("dd")
    dd.textContent = String(value)
    dl.append(dt, dd)
  }
  card.append(dl)
  const label = document.createElement("p")
  label.textContent = "Points (latitude, longitude)"
  card.append(label)
  const list = document.createElement("ol")
  list.className = "polygon-coordinates"
  metrics.vertices.forEach(([lng, lat], index) => {
    const li = document.createElement("li")
    li.textContent = `${index + 1}. ${lat.toFixed(6)}, ${lng.toFixed(6)}`
    list.append(li)
  })
  card.append(list)
  return card
}
