const {test, expect} = require("@playwright/test")
const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4001"
test.describe.configure({mode: "serial"})
test.setTimeout(60_000)
async function open(page) {
  // Keep collaboration tests independent of external basemap availability.
  await page.route('https://basemaps.cartocdn.com/gl/**/style.json', route => route.fulfill({json:{version:8,glyphs:'https://fonts.openmaptiles.org/{fontstack}/{range}.pbf',sources:{},layers:[{id:'background',type:'background',paint:{'background-color':route.request().url().includes('dark')?'#111111':'#ffffff'}}]}}))

  await page.addInitScript(() => document.addEventListener("phx-maplibre:editor-ready", e => { window.editor = e.detail }))
  await page.goto(`${baseURL}/editor`)
  await expect(page.locator("#shared-editor")).toHaveAttribute("data-editor-ready", "true")
  await expect.poll(() => page.evaluate(() => Boolean(window.editor?.online)), {timeout:30000}).toBe(true)
}
const state = page => page.evaluate(() => window.editor.state)
const mutate = (page, payload) => page.evaluate(payload => window.editor.mutate(payload), payload)
async function polygon(page) {
  await page.evaluate(() => window.editor.setMode("polygon"))
  const r = await page.locator(".maplibregl-canvas").boundingBox()
  for (const [x,y] of [[200,180],[400,180],[400,360],[200,360],[200,180]]) await page.mouse.click(r.x+x,r.y+y)
  await expect.poll(async () => (await state(page)).features.length).toBe(1)
  return (await state(page)).features[0]
}
test.beforeEach(async ({page}) => {
  await open(page)
  for (const f of (await state(page)).features) await mutate(page,{action:"delete",id:f.id})
})
test("upstream toolbar creates shared polygon, application fields and deletion", async ({page, context}) => {
  const errors=[]; page.on("pageerror",e=>errors.push(e.message))
  const peer=await context.newPage(); await open(peer)
  const f=await polygon(page)
  await expect.poll(async()=> (await state(peer)).features.map(f=>f.id)).toContain(f.id)
  await page.evaluate(id=>window.editor.select(id),f.id)
  await page.locator('[data-role="selected-name"]').fill("Shared garden")
  await page.locator('[data-role="apply-properties"]').click()
  await expect.poll(async()=> (await state(peer)).features[0].properties.name).toBe("Shared garden")
  await mutate(peer,{action:"delete",id:f.id})
  await expect.poll(async()=> (await state(page)).features.length).toBe(0)
  expect(errors).toEqual([]); await peer.close()
})
test("unfinished drafts remain outside remote Terra state and cancellation removes preview", async ({page, context}) => {
  const peer=await context.newPage(); await open(peer)
  await page.evaluate(()=>window.editor.setMode("polygon"))
  const r=await page.locator(".maplibregl-canvas").boundingBox()
  await page.mouse.click(r.x+220,r.y+180); await page.mouse.move(r.x+340,r.y+250)
  await expect.poll(()=>peer.evaluate(async()=> (await window.editor.map.getSource("phx-editor-shared-editor-drafts")?.getData())?.features?.length || 0)).toBeGreaterThan(0)
  expect(await peer.evaluate(()=>window.editor.draw.getSnapshot().filter(f=>!f.properties.selectionPoint&&!f.properties.midPoint).length)).toBe(0)
  await page.keyboard.press("Escape")
  await expect.poll(()=>peer.evaluate(async()=> (await window.editor.map.getSource("phx-editor-shared-editor-drafts")?.getData())?.features?.length || 0)).toBe(0)
  await peer.close()
})
test("shared settings, reconnect and theme changes preserve authoritative features", async ({page, context}) => {
  const f=await polygon(page); const peer=await context.newPage(); await open(peer)
  await page.locator('[data-role="interval"]').evaluate(el=>{el.value="25";el.dispatchEvent(new Event("change",{bubbles:true}))})
  await expect.poll(async()=> (await state(peer)).settings.update_interval_ms).toBe(25)
  await page.evaluate(()=>window.liveSocket.disconnect())
  await expect.poll(()=>page.evaluate(()=>window.editor.online)).toBe(false)
  await page.evaluate(()=>window.liveSocket.connect())
  await expect.poll(()=>page.evaluate(()=>window.editor.online)).toBe(true)
  await expect.poll(async()=> (await state(page)).features.map(f=>f.id)).toContain(f.id)
  await page.evaluate(()=>document.documentElement.setAttribute("data-theme","dark"))
  await expect.poll(()=>page.evaluate(()=>window.editor.draw.getSnapshot().some(f=>f.id===window.editor.state.features[0].id))).toBe(true)
  await peer.close()
})
