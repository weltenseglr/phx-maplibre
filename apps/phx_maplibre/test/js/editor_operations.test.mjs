import {test} from 'node:test'
import assert from 'node:assert/strict'
import {coordinateState, geometryOperations, editingFeature, acceptSnapshot, projectFeature, isHelperFeature} from '../../priv/js/editor/operations.mjs'
const feature = {type:'Feature',id:'f',properties:{name:'test'},geometry:{type:'LineString',coordinates:[[0,0],[1,1]]}}
const metadata = {mode:'linestring',vertex_ids:['a','b'],nodes:{a:{id:'a',after:null,coordinate:[0,0],seed:true},b:{id:'b',after:'a',coordinate:[1,1],seed:true}}}
test('properties and replacement projection are independent of translation branch', () => {
  assert.equal(projectFeature(feature,metadata,[{type:'properties',properties:{name:'new'}}]).feature.properties.name,'new')
  assert.deepEqual(projectFeature(feature,metadata,[{type:'replace_geometry',geometry:{type:'Point',coordinates:[2,2]}}]).feature.geometry,{type:'Point',coordinates:[2,2]})
  assert.deepEqual(projectFeature(feature,metadata,[{type:'translate',delta:[1,2]}]).feature.geometry.coordinates,[[1,2],[2,3]])
})
test('optimistic insertions use sorted stable IDs and tombstone anchors', () => {
  const ops = [{type:'remove',vertex_id:'a'},{type:'insert',vertex_id:'z',after_id:'a',coordinate:[3,3]},{type:'insert',vertex_id:'c',after_id:'a',coordinate:[2,2]}]
  assert.deepEqual(projectFeature(feature,metadata,ops).metadata.vertex_ids,['c','z','b'])
})
test('line beginning insertion has a null anchor and retains existing IDs', () => {
  const next = {...feature,geometry:{type:'LineString',coordinates:[[-1,-1],[0,0],[1,1]]}}
  const result = geometryOperations(coordinateState(feature,metadata),next,metadata,()=> 'new')
  assert.deepEqual(result.state.ids,['new','a','b'])
  assert.equal(result.operations[0].after_id,null)
})
test('coordinate moves merge by stable IDs and whole translations use deltas', () => {
  const state = coordinateState(feature,metadata)
  assert.deepEqual(geometryOperations(state,{...feature,geometry:{type:'LineString',coordinates:[[0,0],[1,2]]}},metadata).operations,[{type:'move',vertex_id:'b',coordinate:[1,2]}])
  assert.deepEqual(geometryOperations(state,{...feature,geometry:{type:'LineString',coordinates:[[1,2],[2,3]]}},metadata).operations,[{type:'translate',delta:[1,2]}])
})
test('generation reset replaces state but revision gaps require synchronization', () => {
  const current = {generation:'old',revision:10}
  assert.equal(acceptSnapshot(current,{generation:'new',revision:0}),'replace')
  assert.equal(acceptSnapshot(current,{generation:'old',revision:12}),'sync')
  assert.equal(acceptSnapshot(current,{generation:'old',revision:12},true),'replace')
  assert.equal(acceptSnapshot(current,{generation:'old',revision:9}),'ignore')
})
test('editing restores mode metadata and rounds coordinates without changing application data', () => {
  const original = {...feature,geometry:{type:'Point',coordinates:[1.12345678912,2]}}
  const editable = editingFeature(original,{mode:'marker',properties:{marker:true}})
  assert.equal(editable.properties.mode,'marker'); assert.equal(editable.properties.marker,true)
  assert.equal(editable.geometry.coordinates[0],1.123456789)
  assert.equal(original.geometry.coordinates[0],1.12345678912)
})
test('Terra helper features must remain owned by its active gesture', () => {
  for (const key of ['midPoint','selectionPoint','closingPoint','snappingPoint','coordinatePoint']) assert.equal(isHelperFeature({...feature,properties:{[key]:true}}),true)
  assert.equal(isHelperFeature(feature),false)
})

// One wire fixture drives both client projection and the authoritative reducer.
const wireFixtures = JSON.parse(await (await import('node:fs/promises')).readFile(new URL('../editor/protocol.json', import.meta.url), 'utf8'))
for (const fixture of wireFixtures) test(`shared protocol: ${fixture.name}`, () => {
  const geometry = fixture.geometry
  const coordinates = geometry.type === 'Polygon' ? geometry.coordinates[0].slice(0,-1) : geometry.coordinates
  const nodes = Object.fromEntries(fixture.vertex_ids.map((id,index) => [id,{id,after:fixture.vertex_ids[index-1] || null,coordinate:coordinates[index],seed:true,deleted:false,version:0}]))
  const projected = projectFeature({type:'Feature',id:'f',geometry,properties:{}},{mode:fixture.mode,nodes,vertex_ids:fixture.vertex_ids},fixture.operations)
  assert.deepEqual(projected.metadata.vertex_ids,fixture.expected_vertex_ids)
  assert.deepEqual(projected.feature.geometry.coordinates,fixture.expected_coordinates)
})
test('existing feature updates exclude Terra reserved properties while preserving text and application values', async () => {
  const {mutableProperties}=await import('../../priv/js/editor/operations.mjs')
  assert.deepEqual(mutableProperties({mode:'text',currentlyDrawing:false,selected:true,marker:true,coordinatePointIds:['a'],selectionPointFeatureId:'f',text:'Label',name:'Shared',color:'#112233',radiusKilometers:2}),{text:'Label',name:'Shared',color:'#112233',radiusKilometers:2})
})
test('early polygon previews render as points and lines, then become polygons',async()=>{
  const {previewFeature}=await import('../../priv/js/editor/operations.mjs')
  const polygon=ring=>({...feature,geometry:{type:'Polygon',coordinates:[ring]}})
  assert.deepEqual(previewFeature(polygon([[1,2],[1,2],[1,2],[1,2]])).geometry,{type:'Point',coordinates:[1,2]})
  assert.deepEqual(previewFeature(polygon([[1,2],[3,4],[3,4],[1,2]])).geometry,{type:'LineString',coordinates:[[1,2],[3,4]]})
  assert.equal(previewFeature(polygon([[1,2],[3,4],[3,2],[1,2]])).geometry.type,'Polygon')
})
test('bounded preview sampling preserves line ends and polygon closure without mutating completion geometry',async()=>{
  const {boundedPreview}=await import('../../priv/js/editor/operations.mjs')
  const coordinates=Array.from({length:5000},(_,i)=>[i/100,Math.sin(i/100)])
  const line={...feature,geometry:{type:'LineString',coordinates}}
  const sampled=boundedPreview(line)
  assert.equal(sampled.geometry.coordinates.length,1000)
  assert.deepEqual(sampled.geometry.coordinates[0],coordinates[0]);assert.deepEqual(sampled.geometry.coordinates.at(-1),coordinates.at(-1))
  const polygon={...feature,geometry:{type:'Polygon',coordinates:[[...coordinates,coordinates[0]]]}}
  const ring=boundedPreview(polygon).geometry.coordinates[0]
  assert.equal(ring.length,1000);assert.deepEqual(ring[0],ring.at(-1))
  assert.equal(line.geometry.coordinates.length,5000);assert.equal(polygon.geometry.coordinates[0].length,5001)
})
