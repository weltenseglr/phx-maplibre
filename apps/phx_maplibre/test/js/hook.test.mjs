import {describe, it, beforeEach, afterEach} from "node:test"
import assert from "node:assert/strict"

import {parseConfig} from "../../priv/js/hook.js"
import {pushMapEvent} from "../../priv/js/events.js"
import {buildPopupHTML} from "../../priv/js/popup.js"
import {emptyFeatureCollection} from "../../priv/js/sources_layers.js"
import {createMapHook, getMapHandle} from "../../priv/js/phx_maplibre.js"
import {installGlobals, uninstallGlobals, createFakeMaplibre, createCtx, mountHook, mountAndLoad} from "./helpers.mjs"

const point = (id, lng, lat, properties = {}) => ({
  type: "Feature",
  id,
  geometry: {type: "Point", coordinates: [lng, lat]},
  properties,
})

const featureCollection = (...features) => ({type: "FeatureCollection", features})

// ---------------------------------------------------------------------------
// 1. parseConfig
// ---------------------------------------------------------------------------

describe("parseConfig", () => {
  it("honors camelCase keys from data-config", () => {
    const el = {
      dataset: {
        config: JSON.stringify({
          lightStyle: "https://example.com/light.json",
          flyOnGeolocate: false,
          moveEndThrottleMs: 250,
          clusterColor: "#a3e635",
        }),
      },
    }

    const config = parseConfig(el)

    assert.strictEqual(config.lightStyle, "https://example.com/light.json")
    assert.strictEqual(config.flyOnGeolocate, false)
    assert.strictEqual(config.moveEndThrottleMs, 250)
    assert.strictEqual(config.clusterColor, "#a3e635")
  })

  it("defaults clusterColor to null so the step palette applies", () => {
    const config = parseConfig({dataset: {config: "{}"}})
    assert.strictEqual(config.clusterColor, null)
  })

  it("accepts a cluster spiderfy zoom while leaving it disabled by default", () => {
    assert.strictEqual(parseConfig({dataset: {config: "{}"}}).clusterSpiderfyZoom, null)
    assert.strictEqual(
      parseConfig({dataset: {config: JSON.stringify({clusterSpiderfyZoom: 15})}}).clusterSpiderfyZoom,
      15,
    )
  })

  it("falls back to defaults on malformed JSON", () => {
    const el = {dataset: {config: "{not valid json"}}

    const config = parseConfig(el)

    assert.strictEqual(config.zoom, 11)
    assert.strictEqual(config.cluster, true)
    assert.strictEqual(config.navigation, true)
    assert.strictEqual(config.geolocation, false)
    assert.strictEqual(config.flyOnGeolocate, true)
    assert.strictEqual(config.moveEndThrottleMs, 1000)
    assert.strictEqual(config.lightStyle, "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json")
    assert.strictEqual(config.darkStyle, "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json")
    assert.deepStrictEqual(config.events, [])
    assert.deepStrictEqual(config.center, {lng: 13.405, lat: 52.52})
  })

  it("falls back to defaults when data-config is missing entirely", () => {
    const config = parseConfig({dataset: {}})
    assert.strictEqual(config.zoom, 11)
    assert.strictEqual(config.moveEndThrottleMs, 1000)
  })

  it("filters the events whitelist down to strings", () => {
    const el = {dataset: {config: JSON.stringify({events: ["ready", 42, null, {}, "move_end", true]})}}

    const config = parseConfig(el)

    assert.deepStrictEqual(config.events, ["ready", "move_end"])
  })

  it("ignores a non-array events value", () => {
    const el = {dataset: {config: JSON.stringify({events: "ready"})}}
    assert.deepStrictEqual(parseConfig(el).events, [])
  })

  it("clamps a negative moveEndThrottleMs to zero", () => {
    const el = {dataset: {config: JSON.stringify({moveEndThrottleMs: -500})}}
    assert.strictEqual(parseConfig(el).moveEndThrottleMs, 0)
  })
})

// ---------------------------------------------------------------------------
// 6. pushMapEvent whitelist + multiplexed shape (standalone, no globals needed)
// ---------------------------------------------------------------------------

describe("pushMapEvent", () => {
  it("only pushes events included in config.events, multiplexed as maplibre:event", () => {
    const pushed = []
    const hook = {
      mapId: "map-1",
      config: {events: ["ready", "feature_selected"]},
      pushEvent(name, payload) {
        pushed.push({name, payload})
      },
    }

    pushMapEvent(hook, "ready", {zoom: 10})
    pushMapEvent(hook, "move_end", {zoom: 11}) // not whitelisted
    pushMapEvent(hook, "feature_selected", {id: 1})

    assert.strictEqual(pushed.length, 2)
    assert.deepStrictEqual(pushed[0], {
      name: "maplibre:event",
      payload: {id: "map-1", event: "ready", payload: {zoom: 10}},
    })
    assert.deepStrictEqual(pushed[1], {
      name: "maplibre:event",
      payload: {id: "map-1", event: "feature_selected", payload: {id: 1}},
    })
  })

  it("pushes nothing when the events whitelist is empty", () => {
    const pushed = []
    const hook = {mapId: "map-1", config: {events: []}, pushEvent: (n, p) => pushed.push({n, p})}
    pushMapEvent(hook, "ready", {})
    assert.strictEqual(pushed.length, 0)
  })
})

// ---------------------------------------------------------------------------
// Hook integration tests (need document/window/MutationObserver fakes)
// ---------------------------------------------------------------------------

describe("hook integration", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  it("buffers a set_features command dispatched before load and applies it once load fires", () => {
    const {ctx} = mountHook({id: "map-1", config: {events: ["ready"]}})
    const geojson = featureCollection(point(1, 13.4, 52.5))

    // Dispatch the command before the map's `load` event has fired at all —
    // this is the regression scenario for the initial-load buffering fix.
    ctx.command("set_features", {geojson})

    assert.strictEqual(ctx.map.getSource("points"), undefined, "source doesn't exist before load")
    assert.deepStrictEqual(ctx.pointsData, geojson, "the hook buffers the data on itself")

    ctx.map._fire("load")

    assert.deepStrictEqual(
      ctx.map.getSource("points").getData(),
      geojson,
      "the buffered data was applied once the source existed"
    )

    // Bonus: confirm the multiplexed ready event went out once whitelisted.
    const readyEvent = ctx.pushedEvents.find((e) => e.payload?.event === "ready")
    assert.ok(readyEvent, "ready event was pushed")
    assert.strictEqual(readyEvent.name, "maplibre:event")
    assert.strictEqual(readyEvent.payload.id, "map-1")
  })

  it("replaces points data after load, and falls back to an empty FeatureCollection", () => {
    const {ctx} = mountAndLoad()
    const geojson = featureCollection(point(1, 1, 1), point(2, 2, 2))

    ctx.command("set_features", {geojson})
    assert.deepStrictEqual(ctx.map.getSource("points").getData(), geojson)

    ctx.command("set_features", {}) // missing geojson
    assert.deepStrictEqual(ctx.map.getSource("points").getData(), emptyFeatureCollection())

    ctx.command("set_features", {geojson})
    ctx.command("set_features", {geojson: null}) // explicit null
    assert.deepStrictEqual(ctx.map.getSource("points").getData(), emptyFeatureCollection())
  })

  it("replaces area features data after load, with the same empty fallback", () => {
    const {ctx} = mountAndLoad()
    const geojson = featureCollection(point(1, 1, 1))

    ctx.command("set_area_features", {geojson})
    assert.deepStrictEqual(ctx.map.getSource("areas").getData(), geojson)

    ctx.command("set_area_features", {})
    assert.deepStrictEqual(ctx.map.getSource("areas").getData(), emptyFeatureCollection())
  })

  it("caps cluster zoom at the threshold, then spiderfies until an empty click", async () => {
    const {ctx} = mountAndLoad({
      config: {clusterSpiderfyZoom: 15, events: ["cluster_selected", "feature_selected"]},
    })
    const source = ctx.map.getSource("points")
    source.clusterExpansionZoom = 24
    source.clusterLeaves = [
      point("a", 13.4, 52.5, {id: "a", title: "First"}),
      point("b", 13.4, 52.5, {id: "b", title: "Second"}),
    ]
    const cluster = {
      type: "Feature",
      id: 0,
      geometry: {type: "Point", coordinates: [13.4, 52.5]},
      properties: {cluster_id: 7, point_count: 2},
    }

    assert.strictEqual(source.def.clusterMaxZoom, 23)
    assert.strictEqual(source.def.maxzoom, 24)
    assert.strictEqual(ctx.map.getSource("overlap-stacks"), undefined)

    ctx.map._setZoom(14)
    ctx.map._fireLayer("click", "clusters", {features: [cluster]})
    ctx.map._fire("click", {point: {x: 1340, y: 5250}})
    await Promise.resolve()
    assert.strictEqual(ctx.map.easeToCalls.length, 1)
    assert.strictEqual(ctx.map.easeToCalls[0].zoom, 15)
    assert.strictEqual(ctx.map.getSource("spider").getData().features.length, 0)

    ctx.map._setZoom(15)
    ctx.map._fireLayer("click", "clusters", {features: [cluster]})
    ctx.map._fire("click", {point: {x: 1340, y: 5250}})
    await Promise.resolve()
    await Promise.resolve()

    assert.strictEqual(ctx.map.easeToCalls.length, 1)
    assert.strictEqual(ctx.spiderExpanded, true)
    assert.strictEqual(ctx.map.getSource("spider").getData().features.length, 4)
    assert.ok(ctx.map.filterCalls.some(({layerId, filter}) =>
      layerId === "clusters" && JSON.stringify(filter).includes('"cluster_id"'),
    ))

    const displayedSecond = ctx.map.getSource("spider").getData().features.find((feature) =>
      feature.geometry.type === "Point" && feature.id === "b"
    )
    ctx.map._fireLayer("click", "spider-points", {
      features: [displayedSecond],
      lngLat: {lng: displayedSecond.geometry.coordinates[0], lat: displayedSecond.geometry.coordinates[1]},
    })
    ctx.map._fire("click", {point: {x: 1340, y: 5250}})
    const selected = ctx.pushedEvents.find(({payload}) => payload?.event === "feature_selected")
    assert.strictEqual(selected.payload.payload.id, "b")
    assert.deepStrictEqual(selected.payload.payload.feature.geometry.coordinates, [13.4, 52.5])
    assert.strictEqual(ctx.spiderExpanded, true)

    ctx.map._fire("click", {point: {x: 0, y: 0}})
    assert.strictEqual(ctx.spiderExpanded, false)
    assert.strictEqual(ctx.map.getSource("spider").getData().features.length, 0)
    assert.deepStrictEqual(ctx.map.filterCalls.at(-1), {
      layerId: "cluster-count",
      filter: ["has", "point_count"],
    })
  })

  it("ignores cluster leaves that arrive after zooming away", async () => {
    const {ctx} = mountAndLoad({config: {clusterSpiderfyZoom: 15}})
    const source = ctx.map.getSource("points")
    let resolveLeaves
    source.getClusterLeaves = () => new Promise((resolve) => { resolveLeaves = resolve })
    const cluster = {
      type: "Feature",
      geometry: {type: "Point", coordinates: [13.4, 52.5]},
      properties: {cluster_id: 7, point_count: 2},
    }

    ctx.map._setZoom(15)
    ctx.map._fireLayer("click", "clusters", {features: [cluster]})
    ctx.map._fire("zoomstart", {})
    resolveLeaves([
      point("a", 13.4, 52.5, {id: "a"}),
      point("b", 13.4, 52.5, {id: "b"}),
    ])
    await Promise.resolve()
    await Promise.resolve()

    assert.strictEqual(ctx.spiderExpanded, false)
    assert.strictEqual(ctx.map.getSource("spider").getData().features.length, 0)
    assert.deepStrictEqual(ctx.map.filterCalls.at(-1), {
      layerId: "cluster-count",
      filter: ["has", "point_count"],
    })
  })

  it("does not add spider sources or layers without a cluster spiderfy threshold", () => {
    const {ctx} = mountAndLoad()
    assert.strictEqual(ctx.map.getSource("spider"), undefined)
    assert.strictEqual(ctx.map.getLayer("spider-points"), undefined)
  })

  it("set_style sets styleReloading and calls map.setStyle with diff:true; style.load restores state", () => {
    const {ctx} = mountAndLoad()
    const pointsGeo = featureCollection(point(1, 1, 1))
    const areasGeo = featureCollection(point(2, 2, 2))

    ctx.command("set_features", {geojson: pointsGeo})
    ctx.command("set_area_features", {geojson: areasGeo})

    ctx.command("set_style", {style: "https://example.com/new-style.json"})

    assert.strictEqual(ctx.styleReloading, true)
    assert.strictEqual(ctx.currentStyle, "https://example.com/new-style.json")
    assert.deepStrictEqual(ctx.map.styleCalls.at(-1), {
      style: "https://example.com/new-style.json",
      opts: {diff: true},
    })

    // The new style arrives with none of our sources/layers until style.load
    // re-adds them via onStyleLoad.
    assert.strictEqual(ctx.map.getSource("points"), undefined)
    assert.strictEqual(ctx.map.getLayer("clusters"), undefined)

    ctx.map._fire("style.load")

    assert.strictEqual(ctx.styleReloading, false)
    assert.ok(ctx.map.getLayer("clusters"), "layers were re-added")
    assert.ok(ctx.map.getLayer("unclustered-points"))
    assert.deepStrictEqual(ctx.map.getSource("points").getData(), pointsGeo)
    assert.deepStrictEqual(ctx.map.getSource("areas").getData(), areasGeo)
  })

  it("set_style removes an open popup, which the new style has nothing to anchor", () => {
    const {ctx, maplibregl} = mountAndLoad()
    const popup = new maplibregl.Popup()
    ctx.popup = popup

    ctx.command("set_style", {style: "https://example.com/new-style.json"})

    assert.strictEqual(popup.removed, true)
    assert.strictEqual(ctx.popup, null)
  })

  it("set_style leaves a non-string style alone, popup included", () => {
    const {ctx, maplibregl} = mountAndLoad()
    const popup = new maplibregl.Popup()
    ctx.popup = popup

    ctx.command("set_style", {style: 123})

    assert.strictEqual(popup.removed, false)
    assert.strictEqual(ctx.popup, popup)
  })

  it("set_style ignores a non-string style", () => {
    const {ctx} = mountAndLoad()
    ctx.command("set_style", {style: 123})
    assert.strictEqual(ctx.styleReloading, false)
    assert.strictEqual(ctx.map.styleCalls.length, 0)
  })

  it("style.load is a no-op before styleReloading is set (e.g. it doesn't fire on initial load)", () => {
    const {ctx} = mountAndLoad()
    // Firing style.load without a pending style change must not blow up or
    // re-run onStyleLoad bookkeeping unexpectedly.
    assert.doesNotThrow(() => ctx.map._fire("style.load"))
    assert.strictEqual(ctx.styleReloading, false)
  })

  it("fly_to maps center/zoom/duration onto map.flyTo, applies defaults, and no-ops without a center", () => {
    const {ctx} = mountHook()

    ctx.command("fly_to", {center: {lng: 10, lat: 20}, zoom: 6, duration: 500})
    assert.deepStrictEqual(ctx.map.flyToCalls.at(-1), {
      center: [10, 20],
      zoom: 6,
      duration: 500,
      essential: true,
    })

    ctx.command("fly_to", {center: {lng: 1, lat: 2}}) // zoom/duration default
    assert.deepStrictEqual(ctx.map.flyToCalls.at(-1), {
      center: [1, 2],
      zoom: 14,
      duration: 1500,
      essential: true,
    })

    const callsBefore = ctx.map.flyToCalls.length
    ctx.command("fly_to", {}) // no center -> no-op
    ctx.command("fly_to")
    assert.strictEqual(ctx.map.flyToCalls.length, callsBefore)
  })

  it("fit_bounds maps bounds/padding/max_zoom onto map.fitBounds, applies defaults, and no-ops without bounds", () => {
    const {ctx} = mountHook()

    ctx.command("fit_bounds", {bounds: {west: -1, south: -2, east: 3, north: 4}, padding: 12, max_zoom: 9})
    assert.deepStrictEqual(ctx.map.fitBoundsCalls.at(-1), {
      bounds: [
        [-1, -2],
        [3, 4],
      ],
      opts: {padding: 12, maxZoom: 9, duration: 800},
    })

    ctx.command("fit_bounds", {bounds: {west: 0, south: 0, east: 1, north: 1}}) // defaults
    assert.deepStrictEqual(ctx.map.fitBoundsCalls.at(-1), {
      bounds: [
        [0, 0],
        [1, 1],
      ],
      opts: {padding: 40, maxZoom: 15, duration: 800},
    })

    const callsBefore = ctx.map.fitBoundsCalls.length
    ctx.command("fit_bounds", {}) // no bounds -> no-op
    ctx.command("fit_bounds")
    assert.strictEqual(ctx.map.fitBoundsCalls.length, callsBefore)
  })

  it("destroyed() disconnects the theme observer, removes the popup and the map, and nulls the map", () => {
    const {ctx, hook, maplibregl} = mountAndLoad()
    const mapRef = ctx.map
    const observerRef = ctx.themeObserver
    const popup = new maplibregl.Popup()
    ctx.popup = popup

    assert.ok(observerRef, "theme observer was installed on mount")
    assert.strictEqual(observerRef.disconnected, false)
    assert.strictEqual(mapRef.removed, false)

    hook.destroyed.call(ctx)

    assert.strictEqual(observerRef.disconnected, true)
    assert.strictEqual(popup.removed, true)
    assert.strictEqual(mapRef.removed, true)
    assert.strictEqual(ctx.map, null)
  })

  it("destroyed() tolerates a missing popup", () => {
    const {ctx, hook} = mountAndLoad()
    ctx.popup = null
    assert.doesNotThrow(() => hook.destroyed.call(ctx))
    assert.strictEqual(ctx.map, null)
  })
})

// ---------------------------------------------------------------------------
// 8. buildPopupHTML (needs the fake `document` for escapeHTML)
// ---------------------------------------------------------------------------

describe("buildPopupHTML", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  it("escapes HTML in the title, description, and property values", () => {
    const html = buildPopupHTML({
      title: "<b>Bold</b>",
      description: "Tom & Jerry's <shop>",
      note: "\"quoted\" 'value'",
    })

    assert.ok(html.includes("&lt;b&gt;Bold&lt;/b&gt;"))
    assert.ok(html.includes("Tom &amp; Jerry&#39;s &lt;shop&gt;"))
    assert.ok(html.includes("&quot;quoted&quot; &#39;value&#39;"))
    assert.ok(!html.includes("<b>Bold</b>"))
    assert.ok(!html.includes("<shop>"))
  })

  it("skips underscore-prefixed keys and paint/style properties", () => {
    const html = buildPopupHTML({
      title: "Point",
      _internalId: "abc123",
      "fill-color": "#ff0000",
      "circle-radius": 10,
      category: "Cafe",
    })

    assert.ok(!html.includes("_internalId"))
    assert.ok(!html.includes("abc123"))
    assert.ok(!html.includes("fill-color"))
    assert.ok(!html.includes("#ff0000"))
    assert.ok(!html.includes("circle-radius"))
    assert.ok(html.includes("category"))
    assert.ok(html.includes("Cafe"))
  })

  it("omits the title/description blocks when absent, but still renders remaining rows", () => {
    const html = buildPopupHTML({category: "Cafe"})
    assert.ok(!html.includes("phx-maplibre-popup-title"))
    assert.ok(!html.includes("phx-maplibre-popup-desc"))
    assert.ok(html.includes("category"))
  })

  it("never injects a popupHTML property (removed XSS escape hatch)", () => {
    const html = buildPopupHTML({
      title: "Kept",
      popupHTML: "<img src=x onerror=alert(1)>",
    })

    assert.ok(!html.includes("<img"), "popupHTML must not reach the markup")
    assert.ok(html.includes("Kept"))
  })

  it("defaults to an empty properties object", () => {
    assert.doesNotThrow(() => buildPopupHTML())
  })
})

// ---------------------------------------------------------------------------
// showPopup: the popupContent renderer (setDOMContent path)
// ---------------------------------------------------------------------------

describe("showPopup popupContent renderer", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  const makeHook = (popupContent) => ({
    popup: null,
    popupContent: popupContent ?? null,
    maplibregl: createFakeMaplibre(),
    map: {},
  })

  const feature = point("f1", 13.4, 52.5, {title: "Berlin", popupHTML: "<b>nope</b>"})

  it("uses setDOMContent when the renderer returns a DOM Node", async () => {
    const {showPopup} = await import("../../priv/js/popup.js")
    const node = {nodeType: 1, tag: "div"}
    const hook = makeHook((f) => {
      assert.strictEqual(f.properties.title, "Berlin")
      return node
    })

    showPopup(hook, {lng: 13.4, lat: 52.5}, feature)

    assert.strictEqual(hook.popup.domContent, node)
    assert.strictEqual(hook.popup.html, null)
  })

  it("falls back to the escaped default when the renderer returns null", async () => {
    const {showPopup} = await import("../../priv/js/popup.js")
    const hook = makeHook(() => null)

    showPopup(hook, {lng: 13.4, lat: 52.5}, feature)

    assert.ok(hook.popup.html.includes("Berlin"))
    assert.ok(!hook.popup.html.includes("<b>nope</b>"), "popupHTML data must never render")
  })

  it("warns and falls back when the renderer returns a non-Node", async () => {
    const {showPopup} = await import("../../priv/js/popup.js")
    const warnings = []
    const originalWarn = console.warn
    console.warn = (...args) => warnings.push(args)

    try {
      const hook = makeHook(() => "<b>a string is not a node</b>")
      showPopup(hook, {lng: 13.4, lat: 52.5}, feature)

      assert.strictEqual(warnings.length, 1)
      assert.ok(hook.popup.html.includes("Berlin"))
      assert.ok(!hook.popup.html.includes("<b>"))
    } finally {
      console.warn = originalWarn
    }
  })

  it("renders the escaped default without any renderer configured", async () => {
    const {showPopup} = await import("../../priv/js/popup.js")
    const hook = makeHook(null)

    showPopup(hook, {lng: 13.4, lat: 52.5}, feature)

    assert.ok(hook.popup.html.includes("Berlin"))
    assert.strictEqual(hook.popup.domContent, undefined)
  })
})

// ---------------------------------------------------------------------------
// Live popup: follows its feature and re-renders on data updates
// ---------------------------------------------------------------------------

describe("popup refresh on set_features", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  const openPopupOn = (ctx, feature) => {
    ctx.map._fireLayer("click", "unclustered-points", {
      features: [feature],
      lngLat: {lng: feature.geometry.coordinates[0], lat: feature.geometry.coordinates[1]},
    })
  }

  it("moves the popup and re-renders content when its feature moves", () => {
    const {ctx} = mountAndLoad()
    const before = point("gsd-1", 13.4, 52.5, {id: "gsd-1", title: "GSD 1", status: "surveillance"})
    ctx.command("set_features", {geojson: featureCollection(before)})
    openPopupOn(ctx, before)

    assert.ok(ctx.popup, "popup opened")
    assert.ok(ctx.popup.html.includes("surveillance"))

    const after = point("gsd-1", 13.5, 52.6, {id: "gsd-1", title: "GSD 1", status: "charging"})
    ctx.command("set_features", {geojson: featureCollection(after)})

    assert.deepStrictEqual(ctx.popup.lngLat, [13.5, 52.6], "popup follows the feature")
    assert.ok(ctx.popup.html.includes("charging"), "popup content re-rendered")
    assert.ok(!ctx.popup.html.includes("surveillance"))
  })

  it("closes the popup when its feature disappears from the data", () => {
    const {ctx} = mountAndLoad()
    const feature = point("gsd-1", 13.4, 52.5, {id: "gsd-1", title: "GSD 1"})
    ctx.command("set_features", {geojson: featureCollection(feature)})
    openPopupOn(ctx, feature)

    const popup = ctx.popup
    ctx.command("set_features", {geojson: featureCollection()})

    assert.strictEqual(popup.removed, true)
    assert.strictEqual(ctx.popup, null)
    assert.strictEqual(ctx.popupFeatureId, null)
  })

  it("leaves an area popup anchored but refreshes its content", () => {
    const {ctx} = mountAndLoad()
    const area = {
      type: "Feature",
      id: "d1",
      geometry: {type: "Polygon", coordinates: [[[0, 0], [1, 0], [1, 1], [0, 0]]]},
      properties: {id: "d1", title: "District", count: 1},
    }
    ctx.command("set_area_features", {geojson: featureCollection(area)})
    ctx.map._fireLayer("click", "area-fill", {features: [area], lngLat: {lng: 0.5, lat: 0.5}})

    const anchor = ctx.popup.lngLat
    const updated = {...area, properties: {id: "d1", title: "District", count: 2}}
    ctx.command("set_area_features", {geojson: featureCollection(updated)})

    assert.deepStrictEqual(ctx.popup.lngLat, anchor, "area popup keeps its click anchor")
    assert.ok(ctx.popup.html.includes("2"))
  })
})

describe("browser readiness contract", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  it("distinguishes style initialization, initial load, data and destruction", () => {
    const {ctx, hook} = mountHook()
    assert.equal(ctx.el.dataset.mapHookReady, "true")
    assert.equal(getMapHandle(ctx.el).map, ctx.map)
    assert.equal(ctx.el.dataset.mapStyleReady, "false")
    assert.equal(ctx.el.dataset.mapLoaded, "false")
    ctx.command("set_features", {geojson: featureCollection(point("a", 1, 2))})
    assert.equal(ctx.el.dataset.mapPointsPresent, "true")
    assert.equal(getMapHandle(ctx.el).pointsData, ctx.pointsData)
    ctx.map._fire("style.load")
    assert.equal(ctx.el.dataset.mapStyleReady, "true")
    assert.equal(ctx.el.dataset.mapLoaded, "false")
    assert.ok(ctx.map.getLayer("unclustered-points"))
    ctx.map._fire("load")
    assert.equal(ctx.el.dataset.mapLoaded, "true")
    ctx.command("set_features", {geojson: emptyFeatureCollection()})
    assert.equal(ctx.el.dataset.mapPointsPresent, "false")
    hook.destroyed.call(ctx)
    assert.equal(getMapHandle(ctx.el), null)
    for (const key of ["mapHookReady", "mapStyleReady", "mapLoaded", "mapPointsPresent"]) {
      assert.equal(ctx.el.dataset[key], "false")
    }
  })

  it("invalidates style readiness until replacement layers are restored", () => {
    const {ctx} = mountAndLoad()
    ctx.command("set_style", {style: "replacement"})
    assert.equal(ctx.el.dataset.mapStyleReady, "false")
    assert.equal(ctx.map.getLayer("unclustered-points"), undefined)
    ctx.map._fire("style.load")
    assert.equal(ctx.el.dataset.mapStyleReady, "true")
    assert.ok(ctx.map.getLayer("unclustered-points"))
  })

  it("invalidates readiness for theme changes too", async () => {
    const {ctx, hook} = mountAndLoad()
    document.documentElement.dataset.theme = "dark"
    ctx.themeObserver._trigger([{attributeName: "data-theme"}])
    await new Promise(resolve => setTimeout(resolve, 350))
    assert.equal(ctx.el.dataset.mapStyleReady, "false")
    ctx.map._fire("style.load")
    assert.equal(ctx.el.dataset.mapStyleReady, "true")
    hook.destroyed.call(ctx)
  })
})


describe("public browser API and lifecycle diagnostics", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  it("returns null for absent or unmounted elements and freezes mounted handles", () => {
    assert.equal(getMapHandle(null), null)
    assert.equal(getMapHandle(createCtx().el), null)
    const {ctx, hook} = mountHook()
    const handle = getMapHandle(ctx.el)
    assert.ok(Object.isFrozen(handle))
    assert.throws(() => { handle.map = {} }, TypeError)
    assert.equal(ctx.el.dataset.mapLifecycle, "mounted")
    hook.destroyed.call(ctx)
    assert.equal(getMapHandle(ctx.el), null)
    assert.equal(ctx.el.dataset.mapLifecycle, "destroyed")
    hook.mounted.call(ctx)
    assert.notEqual(getMapHandle(ctx.el), handle)
    assert.notEqual(getMapHandle(ctx.el).map, handle.map)
    assert.equal(ctx.el.dataset.mapMountCount, "2")
    assert.equal(ctx.el.dataset.mapPointsPresent, "false")
    assert.equal(ctx.el.dataset.mapError, "")
    hook.destroyed.call(ctx)
  })

  it("records constructor failure without advertising a usable handle", (t) => {
    t.mock.method(console, "error", () => {})
    const maplibregl = createFakeMaplibre()
    const OriginalMap = maplibregl.Map
    let fail = true
    maplibregl.Map = class extends OriginalMap {
      constructor(options) {
        if (fail) throw new Error("Failed to initialize WebGL")
        super(options)
      }
    }
    const {ctx, hook} = mountHook({maplibregl})
    assert.equal(ctx.el.dataset.mapLifecycle, "error")
    assert.equal(ctx.el.dataset.mapError, "Failed to initialize WebGL")
    assert.equal(ctx.el.dataset.mapHookReady, "false")
    assert.equal(getMapHandle(ctx.el), null)
    assert.equal(console.error.mock.calls.length, 1)
    hook.destroyed.call(ctx)
    assert.equal(ctx.el.dataset.mapLifecycle, "destroyed")
    fail = false
    hook.mounted.call(ctx)
    assert.equal(ctx.el.dataset.mapLifecycle, "mounted")
    assert.equal(ctx.el.dataset.mapMountCount, "2")
    assert.equal(ctx.el.dataset.mapError, "")
    assert.ok(getMapHandle(ctx.el))
    hook.destroyed.call(ctx)
  })

  it("preserves setup diagnostics even if cleanup also fails", (t) => {
    t.mock.method(console, "error", () => {})
    const maplibregl = createFakeMaplibre()
    const OriginalMap = maplibregl.Map
    maplibregl.Map = class extends OriginalMap {
      addControl() { throw new Error("Control setup failed") }
      remove() { throw new Error("Cleanup failed") }
    }
    const {ctx} = mountHook({maplibregl})
    assert.equal(ctx.el.dataset.mapLifecycle, "error")
    assert.equal(ctx.el.dataset.mapError, "Control setup failed")
    assert.equal(ctx.el.dataset.mapHookReady, "false")
    assert.equal(ctx.map, null)
    assert.equal(getMapHandle(ctx.el), null)
    assert.equal(console.error.mock.calls.length, 2)
  })

  it("records asynchronous layer setup failure and MapLibre resource errors", (t) => {
    t.mock.method(console, "error", () => {})
    const {ctx, hook} = mountHook()
    ctx.map._fire("error", {error: new Error("Style request failed")})
    assert.equal(ctx.el.dataset.mapError, "Style request failed")
    assert.equal(ctx.el.dataset.mapStyleReady, "false")
    ctx.map.addLayer = () => { throw new Error("Layer setup failed") }
    ctx.map._fire("style.load")
    assert.equal(ctx.el.dataset.mapLifecycle, "error")
    assert.equal(ctx.el.dataset.mapError, "Layer setup failed")
    ctx.map._fire("load")
    assert.equal(ctx.el.dataset.mapLifecycle, "error")
    assert.equal(ctx.el.dataset.mapLoaded, "false")
    assert.equal(ctx.el.dataset.mapHookReady, "true")
    assert.equal(ctx.el.dataset.mapStyleReady, "false")
    hook.destroyed.call(ctx)
  })
})
