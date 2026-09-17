import {test} from "node:test"
import assert from "node:assert/strict"
import {polygonMetrics} from "./polygon_metrics.mjs"

test("counts distinct vertices and computes geodesic square measurements", () => {
  const square = {type: "Feature", properties: {}, geometry: {type: "Polygon", coordinates: [[[0,0],[1,0],[1,1],[0,1],[0,0]]]}}
  const result = polygonMetrics(square)
  assert.equal(result.edges, 4)
  assert.equal(result.vertices.length, 4)
  assert.ok(Math.abs(result.perimeter - 444763) < 10)
  assert.ok(Math.abs(result.area - 12363718145) < 100)
})
