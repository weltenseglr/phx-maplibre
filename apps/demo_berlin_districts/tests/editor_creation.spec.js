const {test,expect}=require('@playwright/test')
const baseURL=process.env.PLAYWRIGHT_BASE_URL||'http://127.0.0.1:4001'
test.describe.configure({mode:'serial'})
test.setTimeout(60_000)
const modes=['point','marker','linestring','polyline','polygon','rectangle','circle','freehand','freehand-linestring','angled-rectangle','sensor','sector','text']
async function open(page){
  // Keep collaboration tests independent of external basemap availability.
  await page.route('https://basemaps.cartocdn.com/gl/**/style.json', route => route.fulfill({json:{version:8,glyphs:'https://fonts.openmaptiles.org/{fontstack}/{range}.pbf',sources:{},layers:[{id:'background',type:'background',paint:{'background-color':route.request().url().includes('dark')?'#111111':'#ffffff'}}]}}))

  await page.addInitScript(()=>document.addEventListener('phx-maplibre:editor-ready',event=>{window.editor=event.detail}))
  await page.goto(`${baseURL}/polygons`)
  await expect.poll(()=>page.evaluate(()=>Boolean(window.editor?.online)), {timeout:30000}).toBe(true)
}
const state=page=>page.evaluate(()=>window.editor.state)
const mutate=(page,payload)=>page.evaluate(payload=>window.editor.mutate(payload),payload)
const preview=peer=>expect.poll(()=>peer.evaluate(async()=> (await window.editor.map.getSource('phx-editor-shared-editor-drafts')?.getData())?.features?.length || 0)).toBeGreaterThan(0)
for(const mode of modes)test(`upstream ${mode} pointer gestures create a shared feature`,async({page,context})=>{
  await open(page)
  for(const feature of(await state(page)).features)await mutate(page,{action:'delete',id:feature.id})
  const peer=await context.newPage();await open(peer)
  const errors=[];page.on('pageerror',error=>errors.push(error.message));peer.on('pageerror',error=>errors.push(error.message))
  await page.evaluate(mode=>window.editor.setMode(mode),mode)
  const box=await page.locator('.maplibregl-canvas').boundingBox()
  const click=(x,y)=>page.mouse.click(box.x+x,box.y+y)
  const move=(x,y,steps=8)=>page.mouse.move(box.x+x,box.y+y,{steps})
  if(['point','marker'].includes(mode))await click(300,240)
  else if(mode==='text'){
    await click(300,240)
    await page.locator('textarea').fill('A shared label')
    await preview(peer)
    await page.locator('.maplibregl-terradraw-text-mode-submit-button').click()
  }else if(['circle','rectangle'].includes(mode)){
    await click(260,200);await move(420,340);await preview(peer);await click(420,340)
  }else if(['angled-rectangle','sector'].includes(mode)){
    await click(260,260);await move(420,240);await click(420,240);await move(380,360)
    await preview(peer);await click(380,360)
  }else if(mode==='sensor'){
    await click(300,260);await move(410,230);await click(410,230)
    await move(410,330);await click(410,330);await move(470,350)
    await preview(peer);await click(470,350)
  }else if(mode==='polygon'){
    await click(240,200);await move(420,200);await click(420,200);await move(420,360)
    await preview(peer)
    await expect.poll(()=>peer.evaluate(()=>window.editor.map.queryRenderedFeatures({layers:['phx-editor-shared-editor-drafts-line']}).length)).toBeGreaterThan(0)
    await click(420,360);await click(240,360);await click(240,200)
  }else if(['linestring','polyline'].includes(mode)){
    await click(240,200);await move(360,260);await click(360,260);await move(440,340)
    await preview(peer);await click(440,340);await page.keyboard.press('Enter')
  }else{
    // Upstream freehand modes sample the moving pointer between two clicks.
    await click(240,200);await move(420,200,20);await move(420,340,20)
    if(mode==='freehand'){await move(240,340,20);await move(240,220,20)}
    await preview(peer);await click(mode==='freehand'?240:440,mode==='freehand'?220:360)
  }
  await expect.poll(async()=>(await state(peer)).features.length,{message:`${mode} completion reaches peer`}).toBe(1)
  const shared=(await state(peer)).features[0]
  expect((await state(peer)).metadata[shared.id].mode).toBe(mode)
  await expect.poll(()=>peer.evaluate(id=>window.editor.draw.getSnapshot().find(feature=>feature.id===id)?.properties.mode,shared.id)).toBe(mode)
  if(mode==='text')expect(await peer.evaluate(id=>window.editor.draw.getSnapshot().find(feature=>feature.id===id).properties.text,shared.id)).toBe('A shared label')
  await expect.poll(()=>peer.evaluate(async()=> (await window.editor.map.getSource('phx-editor-shared-editor-drafts')?.getData())?.features?.length || 0)).toBe(0)
  expect(errors).toEqual([])
  await peer.close()
})
