const {test, expect} = require('@playwright/test')
const baseURL = process.env.PLAYWRIGHT_BASE_URL || 'http://127.0.0.1:4001'
test.describe.configure({mode:'serial'})
test.setTimeout(90_000)
async function open(page) {
  // Keep collaboration tests independent of external basemap availability.
  await page.route('https://basemaps.cartocdn.com/gl/**/style.json', route => route.fulfill({json:{version:8,glyphs:'https://fonts.openmaptiles.org/{fontstack}/{range}.pbf',sources:{},layers:[{id:'background',type:'background',paint:{'background-color':route.request().url().includes('dark')?'#111111':'#ffffff'}}]}}))

  await page.addInitScript(() => document.addEventListener('phx-maplibre:editor-ready',event => { window.editor = event.detail }))
  await page.goto(`${baseURL}/editor`)
  await expect.poll(() => page.evaluate(() => Boolean(window.editor?.online)), {timeout:30000}).toBe(true)
}
const state = page => page.evaluate(() => window.editor.state)
const mutate = (page,payload) => page.evaluate(payload => window.editor.mutate(payload),payload)
const pointModes = ['point','marker','text']
const lineModes = ['linestring','polyline','freehand-linestring']
const modes = [...pointModes,...lineModes,'polygon','rectangle','circle','freehand','angled-rectangle','sensor','sector']
function specimen(mode,id) {
  const geometry = pointModes.includes(mode) ? {type:'Point',coordinates:[13.38,52.51]} : lineModes.includes(mode) ? {type:'LineString',coordinates:[[13.38,52.51],[13.39,52.52],[13.4,52.51]]} : {type:'Polygon',coordinates:[[[13.38,52.51],[13.39,52.51],[13.39,52.52],[13.38,52.52],[13.38,52.51]]]}
  const count = geometry.type === 'Point' ? 1 : geometry.type === 'LineString' ? 3 : 4
  return {action:'create',mode,feature:{type:'Feature',id,geometry,properties:{name:`Shared ${mode}`,color:'#3b82f6'}},vertex_ids:Array.from({length:count},(_,index)=>`${id}-v${index}`),mode_properties:mode==='text'?{text:'Shared label'}:mode==='circle'?{radiusKilometers:1}:{}}
}
test.beforeEach(async ({page}) => { await open(page); for (const feature of (await state(page)).features) await mutate(page,{action:'delete',id:feature.id}) })
test('all standard modes reconstruct remotely, retain metadata, edit and delete',async ({page,context}) => {
  const peer = await context.newPage(); await open(peer)
  const errors=[]; peer.on('pageerror',error=>errors.push(error.message))
  for (const mode of modes) {
    const id=require("node:crypto").randomUUID(), payload=specimen(mode,id)
    expect((await mutate(page,payload)).error,mode).toBeFalsy()
    await expect.poll(()=>peer.evaluate(id=>window.editor.draw.getSnapshot().find(feature=>feature.id===id)?.properties.mode,id),{message:`restore ${mode}`}).toBe(mode)
    if (mode==='text') expect(await peer.evaluate(id=>window.editor.draw.getSnapshot().find(feature=>feature.id===id).properties.text,id)).toBe('Shared label')
    expect((await state(peer)).features.find(feature=>feature.id===id).properties.mode).toBeUndefined()
    expect((await mutate(peer,{action:'edit',id,sequence:1,gesture_id:`${id}-move`,operations:[{type:'translate',delta:[.001,0]}],finish:true})).error,mode).toBeFalsy()
    await expect.poll(async()=> (await state(page)).metadata[id].acknowledgements).not.toEqual({})
    expect((await mutate(page,{action:'delete',id})).error).toBeFalsy()
    await expect.poll(()=>peer.evaluate(id=>window.editor.draw.getSnapshot().some(feature=>feature.id===id),id)).toBe(false)
  }
  expect(errors).toEqual([]); await peer.close()
})
test('simultaneous gesture batches merge distinct vertices and committed toolbar undo preserves remote edit',async ({page,context}) => {
  const peer=await context.newPage(); await open(peer)
  const id=require("node:crypto").randomUUID(), payload=specimen('polygon',id)
  expect((await mutate(page,payload)).error).toBeFalsy()
  await expect.poll(async()=> (await state(peer)).features.some(feature=>feature.id===id)).toBe(true)
  const results=await Promise.all([
    mutate(page,{action:'edit',id,sequence:1,gesture_id:'gesture-left',operations:[{type:'move',vertex_id:`${id}-v0`,coordinate:[13.379,52.51]}],finish:true}),
    mutate(peer,{action:'edit',id,sequence:1,gesture_id:'gesture-right',operations:[{type:'move',vertex_id:`${id}-v2`,coordinate:[13.391,52.52]}],finish:true}),
  ])
  for (const result of results) expect(result.error).toBeFalsy()
  await expect.poll(async()=> (await state(page)).features.find(feature=>feature.id===id).geometry.coordinates[0][2]).toEqual([13.391,52.52])
  const undo=page.locator('button[class*="undo-button"]')
  await expect(undo).toBeEnabled(); await undo.click()
  await expect.poll(async()=> (await state(peer)).features.find(feature=>feature.id===id).geometry.coordinates[0][0]).toEqual([13.38,52.51])
  expect((await state(peer)).features.find(feature=>feature.id===id).geometry.coordinates[0][2]).toEqual([13.391,52.52])
  const redo=page.locator('button[class*="redo-button"]')
  await expect(redo).toBeEnabled(); await redo.click()
  await expect.poll(async()=> (await state(peer)).features.find(feature=>feature.id===id).geometry.coordinates[0][0]).toEqual([13.379,52.51])
  await peer.close()
})
test('editing an existing text label synchronizes mode metadata',async ({page,context}) => {
  const peer=await context.newPage(); await open(peer)
  const id=require("node:crypto").randomUUID(); expect((await mutate(page,specimen('text',id))).error).toBeFalsy()
  await expect.poll(()=>peer.evaluate(id=>window.editor.draw.getSnapshot().find(f=>f.id===id)?.properties.text,id)).toBe('Shared label')
  await page.evaluate(()=>{window.textEvents=[];window.editor.draw.on('finish',(id,context)=>window.textEvents.push({id,context,features:window.editor.draw.getSnapshot()}));window.editor.setMode('text')})
  const point=await page.evaluate(()=>{const p=window.editor.map.project([13.38,52.51]);const r=window.editor.map.getCanvas().getBoundingClientRect();return {x:r.x+p.x,y:r.y+p.y}})
  await page.mouse.click(point.x,point.y)
  await expect(page.locator('textarea')).toHaveValue('Shared label')
  await page.locator('textarea').fill('Updated label')
  await page.locator('.maplibregl-terradraw-text-mode-submit-button').click()
  await expect.poll(()=>page.evaluate(()=>window.textEvents.length)).toBeGreaterThan(0)
  await expect.poll(()=>peer.evaluate(id=>window.editor.draw.getSnapshot().find(f=>f.id===id)?.properties.text,id)).toBe('Updated label')
  expect((await state(peer)).features.find(f=>f.id===id).properties.text).toBeUndefined()
  await peer.close()
})
test('an unfinished drawing continues after style replacement and editor destruction removes controls',async ({page,context}) => {
  const peer=await context.newPage(); await open(peer)
  await page.evaluate(()=>window.editor.setMode('polygon'))
  const canvas=page.locator('.maplibregl-canvas'), bounds=await canvas.boundingBox()
  await page.mouse.click(bounds.x+240,bounds.y+180)
  await page.mouse.click(bounds.x+420,bounds.y+180)
  await page.mouse.move(bounds.x+420,bounds.y+320)
  await expect.poll(()=>peer.evaluate(async()=> (await window.editor.map.getSource('phx-editor-shared-editor-drafts')?.getData())?.features?.length || 0)).toBeGreaterThan(0)
  // A remote preview must return after a style swap without another pointer
  // update from its owner; style restoration itself recreates our overlays.
  await peer.evaluate(()=>{window.styleResumes=0;document.addEventListener('phx-maplibre:editor-ready',()=>window.styleResumes++);document.documentElement.setAttribute('data-theme','dark')})
  await expect.poll(()=>peer.evaluate(()=>window.styleResumes)).toBeGreaterThan(0)
  await expect.poll(()=>peer.evaluate(async()=> (await window.editor.map.getSource('phx-editor-shared-editor-drafts')?.getData())?.features?.length || 0)).toBeGreaterThan(0)
  await page.evaluate(()=>{window.styleResumes=0;document.addEventListener('phx-maplibre:editor-ready',()=>window.styleResumes++);document.documentElement.setAttribute('data-theme','dark')})
  await expect.poll(()=>page.evaluate(()=>window.styleResumes)).toBeGreaterThan(0)
  await expect(page.locator('#shared-editor')).toHaveAttribute('data-editor-ready','true')
  await page.mouse.click(bounds.x+420,bounds.y+320)
  await page.mouse.click(bounds.x+240,bounds.y+320)
  await page.mouse.click(bounds.x+240,bounds.y+180)
  await expect.poll(async()=> (await state(peer)).features.length).toBe(1)
  expect((await state(peer)).features[0].geometry.coordinates[0].length).toBeGreaterThanOrEqual(5)
  await page.evaluate(()=>{window.oldMap=window.editor.map;window.oldEditor=window.editor})
  await page.goto(baseURL)
  await expect(page.locator('#shared-editor')).toHaveCount(0)
  await expect(page.locator('button[class*="undo-button"]')).toHaveCount(0)
  await peer.close()
})
