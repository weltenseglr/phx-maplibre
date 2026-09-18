import {test} from "node:test"
import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"

const packageRoot = new URL("../../", import.meta.url)
const manifest = JSON.parse(await readFile(new URL("package.json", packageRoot), "utf8"))
const editorPeers = ["@watergis/maplibre-gl-terradraw", "terra-draw", "terra-draw-maplibre-gl-adapter"]

// Follow the actual static module graph: importing the map entry must never
// resolve optional drawing packages, even when consumers install those peers.
test("map entry keeps the optional editor out of its module graph", async () => {
  const visited = new Set()
  async function visit(url) {
    if (visited.has(url.href)) return
    visited.add(url.href)
    assert.ok(!/\/(?:editor(?:\.js|\/)|update_gate\.js)/.test(url.pathname), `Map entry includes editor support ${url.pathname}`)
    const source = await readFile(url, "utf8")
    const imports = source.matchAll(/(?:import|export)\s+(?:[^"']*?\s+from\s*)?["']([^"']+)["']/g)
    for (const [, specifier] of imports) {
      assert.ok(!editorPeers.some(peer => specifier === peer || specifier.startsWith(`${peer}/`)), `Map entry imports ${specifier}`)
      if (specifier.startsWith(".")) await visit(new URL(specifier, url))
    }
  }
  await visit(new URL(manifest.exports["."], packageRoot))
  assert.ok(!visited.has(new URL(manifest.exports["./editor"], packageRoot).href), "Map entry includes the editor")
  const entry = await import(new URL(manifest.exports["."], packageRoot))
  assert.equal(typeof entry.createMapHook, "function")
})

test("drawing peers are optional for map-only installations", () => {
  for (const peer of editorPeers) assert.equal(manifest.peerDependenciesMeta[peer]?.optional, true)
})

test("MapLibre peer range admits the tested 5.x and 6.x compatibility lanes", () => {
  // Check the actual whole range, including the absence of extra restrictions.
  assert.match(manifest.peerDependencies["maplibre-gl"], /^>=\s*5\.0\.0\s+<\s*7\.0\.0$/)
})
