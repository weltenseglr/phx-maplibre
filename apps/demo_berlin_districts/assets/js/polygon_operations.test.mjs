import {test} from "node:test"
import assert from "node:assert/strict"
import {vertexState, geometryOperations, optimisticFeature, editingFeature} from "./polygon_operations.mjs"
const feature = {type:"Feature", id:"p", properties:{vertex_ids:["a","b","c","d"]}, geometry:{type:"Polygon", coordinates:[[[0,0],[2,0],[2,2],[0,2],[0,0]]]}}
const geometry = points => ({type:"Polygon",coordinates:[[...points,points[0]]]})
test("moves use stable IDs and insertion/deletion preserve identity", () => {
  const base = vertexState(feature)
  const moved = geometryOperations(base,geometry([[-1,0],[2,0],[2,2],[0,2]]))
  assert.deepEqual(moved.operations,[{type:"move",vertex_id:"a",coordinate:[-1,0]}])
  const inserted = geometryOperations(base,geometry([[0,0],[1,0],[2,0],[2,2],[0,2]]),()=>"new")
  assert.deepEqual(inserted.operations,[{type:"insert",vertex_id:"new",after_id:"a",coordinate:[1,0]}])
  assert.deepEqual(inserted.state.ids,["a","new","b","c","d"])
  const removed = geometryOperations(inserted.state,feature.geometry)
  assert.deepEqual(removed.operations,[{type:"remove",vertex_id:"new"}])
  const firstRemoved = geometryOperations(base,geometry([[2,0],[2,2],[0,2]]))
  assert.deepEqual(firstRemoved.operations,[{type:"remove",vertex_id:"a"}])
})
test("whole polygon movement is a delta",()=>{
  const result=geometryOperations(vertexState(feature),geometry([[1,1],[3,1],[3,3],[1,3]]))
  assert.deepEqual(result.operations,[{type:"translate",delta:[1,1]}])
})
test("optimistic movement preserves remote inserted vertices",()=>{
  const inserted=optimisticFeature(feature,[{type:"insert",vertex_id:"new",after_id:"c",coordinate:[1,2]}])
  const merged=optimisticFeature(inserted,[{type:"move",vertex_id:"a",coordinate:[-1,0]}])
  assert.deepEqual(merged.properties.vertex_ids,["a","b","c","new","d"])
  assert.deepEqual(merged.geometry.coordinates[0],[[-1,0],[2,0],[2,2],[1,2],[0,2],[-1,0]])
})

test("editor precision does not change authoritative coordinates or generate unrelated moves",()=>{
  const original=structuredClone(feature)
  original.geometry.coordinates[0][1][0]=2.123456789012345
  const editable=editingFeature(original)
  assert.equal(editable.geometry.coordinates[0][1][0],2.123456789)
  assert.equal(original.geometry.coordinates[0][1][0],2.123456789012345)
  const next=structuredClone(editable.geometry)
  next.coordinates[0][0]=[-1,0];next.coordinates[0][4]=[-1,0]
  assert.deepEqual(geometryOperations(vertexState(editable),next).operations,[{type:"move",vertex_id:"a",coordinate:[-1,0]}])
})
