import {describe, it, beforeEach, afterEach} from "node:test"
import assert from "node:assert/strict"

import {frameInterval} from "../../priv/js/animate.js"
import {installGlobals, uninstallGlobals, createFakeClock, mountHook, mountAndLoad} from "./helpers.mjs"

const point = (id, lng, lat, properties = {}) => ({
  type: "Feature",
  id,
  geometry: {type: "Point", coordinates: [lng, lat]},
  properties: {id, ...properties},
})

const fc = (...features) => ({type: "FeatureCollection", features})

describe("animated position transitions", () => {
  beforeEach(() => installGlobals())
  afterEach(() => uninstallGlobals())

  function mountAnimated({zoom = 13, config = {}} = {}) {
    const clock = createFakeClock()
    const result = mountAndLoad({config, options: {now: clock.now, raf: clock.raf, caf: clock.caf}})
    result.ctx.map._setZoom(zoom, {fire: true})
    return {...result, clock}
  }

  const animated = (ctx) => ctx.map.getSource("animated").getData()

  it("is on by default: above zoom 12 the animated source renders, snapshot layers hide", () => {
    const {ctx} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 13.4, 52.5))})

    assert.equal(ctx.map._visibility["animated-points"], "visible")
    assert.equal(ctx.map._visibility["unclustered-points"], "none")
    assert.equal(ctx.map._visibility["clusters"], "none")
    assert.equal(animated(ctx).features.length, 1)
  })

  it("first-seen features appear in place, with properties applied immediately", () => {
    const {ctx} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 13.4, 52.5, {status: "flying"}))})

    const feature = animated(ctx).features[0]
    assert.deepEqual(feature.geometry.coordinates, [13.4, 52.5])
    assert.equal(feature.properties.status, "flying")
  })

  it("tweens linearly from the displayed position over the measured update interval", () => {
    const {ctx, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})

    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})

    // Interval was 1000ms; halfway through, the feature is at the midpoint.
    clock.advance(500)
    clock.pump()
    const mid = animated(ctx).features[0].geometry.coordinates[0]
    assert.ok(Math.abs(mid - 0.005) < 1e-9)

    clock.advance(600)
    clock.pump()
    assert.ok(Math.abs(animated(ctx).features[0].geometry.coordinates[0] - 0.01) < 1e-12)
  })

  it("clamps the tween duration to [250ms, 15s] and defaults to 5s on the first update", () => {
    const {ctx, clock} = mountAnimated()

    // First update: nothing to measure yet — appear in place regardless.
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})

    // 100ms gap clamps up to 250ms.
    clock.advance(100)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    clock.advance(125)
    clock.pump()
    assert.ok(Math.abs(animated(ctx).features[0].geometry.coordinates[0] - 0.005) < 1e-9)
    clock.advance(200)
    clock.pump()

    // 20s gap clamps down to 15s.
    clock.advance(20_000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.02, 0))})
    clock.advance(7_500)
    clock.pump()
    assert.ok(Math.abs(animated(ctx).features[0].geometry.coordinates[0] - 0.015) < 1e-9)
  })

  it("drops features that vanish from an update", () => {
    const {ctx, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0), point("u2", 1, 1))})
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u2", 1.001, 1))})

    const features = animated(ctx).features
    assert.equal(features.length, 1)
    assert.equal(features[0].id, "u2")
  })

  it("mutates one retained FeatureCollection across frames", () => {
    const {ctx, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    const before = animated(ctx)
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    clock.advance(500)
    clock.pump()
    assert.equal(animated(ctx), before, "same retained object")
  })

  it("idles the loop when all tweens complete and restarts on the next update", () => {
    const {ctx, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    assert.ok(clock.pending > 0, "loop running during the tween")

    // Finish the tween; the next rendered frame stops the loop.
    clock.advance(1100)
    clock.pump()
    clock.advance(50)
    clock.pump()
    assert.equal(clock.pending, 0, "loop idled")

    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.02, 0))})
    assert.ok(clock.pending > 0, "loop restarted")
  })

  it("gates by zoom with hysteresis", () => {
    const {ctx} = mountAnimated({zoom: 13})
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    assert.equal(ctx.map._visibility["animated-points"], "visible")

    ctx.map._setZoom(11.8, {fire: true})
    assert.equal(ctx.map._visibility["animated-points"], "visible", "inside the hysteresis band")

    ctx.map._setZoom(11.4, {fire: true})
    assert.equal(ctx.map._visibility["animated-points"], "none")
    assert.equal(ctx.map._visibility["unclustered-points"], "visible")

    ctx.map._setZoom(12.3, {fire: true})
    assert.equal(ctx.map._visibility["animated-points"], "visible")
  })

  it("animate_min_zoom: false disables the feature entirely", () => {
    const {ctx, clock} = mountAnimated({zoom: 14, config: {animateMinZoom: false}})
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})

    assert.equal(ctx.map._visibility["animated-points"], undefined, "never touched")
    assert.equal(animated(ctx).features.length, 0)
    assert.equal(clock.pending, 0)
  })

  it("rebuilds the animated source from stashed data across a style swap, without tweening", () => {
    const {ctx, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})

    ctx.command("set_style", {style: "https://example.com/other.json"})
    ctx.map._fire("style.load")

    const feature = animated(ctx).features[0]
    assert.deepEqual(feature.geometry.coordinates, [0.01, 0], "snapped to target, no tween")
    assert.equal(ctx.map._visibility["animated-points"], "visible")
  })

  it("keeps an open popup riding its tweening feature", () => {
    const {ctx, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})

    const lngLats = []
    ctx.popup = {setLngLat: (ll) => lngLats.push(ll), setHTML() {}, setDOMContent() {}, remove() {}}
    ctx.popupKind = "point"
    ctx.popupFeatureId = "u1"

    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    clock.advance(500)
    clock.pump()

    assert.ok(Math.abs(lngLats.at(-1)[0] - 0.005) < 1e-9)
  })

  const stateWrites = (ctx, id, key, value) =>
    ctx.map.setFeatureStateCalls.filter(
      (call) => call.target.id === id && call.state[key] === value,
    )

  const sourcesOf = (calls) => [...new Set(calls.map((call) => call.target.source))].sort()

  it("selection below the gate styles both sources, surviving the flip up", () => {
    const {ctx} = mountAnimated({zoom: 11})
    const feature = point("u1", 13.4, 52.5)
    ctx.command("set_features", {geojson: fc(feature)})

    ctx.map._fireLayer("click", "unclustered-points", {
      features: [feature],
      lngLat: {lng: 13.4, lat: 52.5},
    })

    assert.deepEqual(sourcesOf(stateWrites(ctx, "u1", "selected", true)), ["animated", "points"])

    // Crossing the gate needs no state transfer: the animated source already
    // carries the selection, and nothing clears it on the flip.
    ctx.map._setZoom(13, {fire: true})
    assert.equal(stateWrites(ctx, "u1", "selected", false).length, 0)
    assert.equal(ctx.map._visibility["animated-points"], "visible")
  })

  it("selection above the gate styles both sources too (reverse direction)", () => {
    const {ctx} = mountAnimated({zoom: 13})
    const feature = point("u2", 13.4, 52.5)
    ctx.command("set_features", {geojson: fc(feature)})

    ctx.map._fireLayer("click", "animated-points", {
      features: [feature],
      lngLat: {lng: 13.4, lat: 52.5},
    })

    assert.deepEqual(sourcesOf(stateWrites(ctx, "u2", "selected", true)), ["animated", "points"])

    ctx.map._setZoom(11.4, {fire: true})
    assert.equal(stateWrites(ctx, "u2", "selected", false).length, 0)
    assert.equal(ctx.map._visibility["unclustered-points"], "visible")
  })

  it("hover styles both sources from either layer", () => {
    const {ctx} = mountAnimated({zoom: 13})
    const feature = point("u3", 13.4, 52.5)
    ctx.command("set_features", {geojson: fc(feature)})

    ctx.map._fireLayer("mousemove", "animated-points", {features: [feature]})
    assert.deepEqual(sourcesOf(stateWrites(ctx, "u3", "hover", true)), ["animated", "points"])
  })

  it("deselecting clears both sources", () => {
    const {ctx} = mountAnimated({zoom: 13})
    const feature = point("u4", 13.4, 52.5)
    ctx.command("set_features", {geojson: fc(feature)})

    ctx.map._fireLayer("click", "animated-points", {
      features: [feature],
      lngLat: {lng: 13.4, lat: 52.5},
    })
    ctx.map._fire("click", {point: {x: 1, y: 1}})

    assert.deepEqual(sourcesOf(stateWrites(ctx, "u4", "selected", false)), ["animated", "points"])
  })

  it("highlights a selected feature's linked-id in orange state on both sources", () => {
    const {ctx} = mountAnimated({zoom: 13})
    const selected = point("u5", 13.4, 52.5, {"linked-id": "u6"})
    const partner = point("u6", 13.41, 52.51)
    ctx.command("set_features", {geojson: fc(selected, partner)})

    ctx.map._fireLayer("click", "animated-points", {
      features: [selected],
      lngLat: {lng: 13.4, lat: 52.5},
    })

    assert.deepEqual(sourcesOf(stateWrites(ctx, "u6", "linked", true)), ["animated", "points"])
    assert.equal(ctx.selectedPointIdLinkedId, "u6")

    ctx.map._fire("click", {point: {x: 1, y: 1}})
    assert.deepEqual(sourcesOf(stateWrites(ctx, "u6", "linked", false)), ["animated", "points"])
  })

  it("frame interval follows the ladder with inclusive boundaries", () => {
    assert.equal(frameInterval(1), 33)
    assert.equal(frameInterval(1000), 33)
    assert.equal(frameInterval(1001), 67)
    assert.equal(frameInterval(3000), 67)
    assert.equal(frameInterval(3001), 200)
    assert.equal(frameInterval(24000), 200)
  })

  const spyPointsSetData = (ctx) => {
    const source = ctx.map.getSource("points")
    const original = source.setData.bind(source)
    const calls = []
    source.setData = (data) => {
      calls.push(data)
      original(data)
    }
    return calls
  }

  it("skips the hidden clustered source while animated mode is active, flushing once on the downward flip", () => {
    const {ctx, clock} = mountAnimated({zoom: 13})
    const calls = spyPointsSetData(ctx)

    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    assert.equal(calls.length, 0, "no points.setData while animation displays")

    ctx.map._setZoom(11.4, {fire: true})
    assert.equal(calls.length, 1, "exactly one flush on the flip down")
    assert.equal(calls[0].features[0].geometry.coordinates[0], 0.01, "flushed from the stash")
    assert.equal(ctx.map._visibility["unclustered-points"], "visible")

    // Once inactive, updates feed the snapshot source directly again.
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.02, 0))})
    assert.equal(calls.length, 2)
  })

  it("feeds the snapshot source normally below the gate and when animation is disabled", () => {
    const below = mountAnimated({zoom: 11})
    const belowCalls = spyPointsSetData(below.ctx)
    below.ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    assert.equal(belowCalls.length, 1)

    const disabled = mountAnimated({zoom: 14, config: {animateMinZoom: false}})
    const disabledCalls = spyPointsSetData(disabled.ctx)
    disabled.ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    disabled.ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    assert.equal(disabledCalls.length, 2)
  })

  it("falls back to the snapshot path above the feature cap, warns once, and recovers", () => {
    const {ctx} = mountAnimated({zoom: 13})
    const calls = spyPointsSetData(ctx)
    const warns = []
    const originalWarn = console.warn
    console.warn = (...args) => warns.push(args.join(" "))

    try {
      const huge = fc(...Array.from({length: 10_001}, (_, i) => point(`u${i}`, 0, 0)))
      ctx.command("set_features", {geojson: huge})

      assert.equal(ctx.map.getSource("animated").getData().features.length, 0)
      assert.equal(ctx.map._visibility["unclustered-points"], "visible", "snapshot fallback")
      assert.equal(calls.length, 1, "points source fed as in inactive mode")
      assert.equal(warns.length, 1)
      assert.ok(warns[0].includes("MAX_ANIMATED_FEATURES"))

      // Second over-cap update does not warn again.
      ctx.command("set_features", {geojson: huge})
      assert.equal(warns.length, 1)

      // A sane update recovers animated mode.
      ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
      assert.equal(ctx.map.getSource("animated").getData().features.length, 1)
      assert.equal(ctx.map._visibility["animated-points"], "visible")
    } finally {
      console.warn = originalWarn
    }
  })

  it("animates only bounded string or finite-number ids", () => {
    const {ctx} = mountAnimated({zoom: 13})

    const withId = (id) => ({
      type: "Feature",
      id,
      geometry: {type: "Point", coordinates: [0, 0]},
      properties: {},
    })

    ctx.command("set_features", {
      geojson: fc(
        withId("ok"),
        withId(42),
        withId("x".repeat(129)),
        withId({nested: "object"}),
        withId(Infinity),
      ),
    })

    const ids = ctx.map.getSource("animated").getData().features.map((f) => f.id)
    assert.deepEqual(ids.sort(), [42, "ok"].sort())
  })

  it("cancels the animation frame on teardown", () => {
    const {ctx, hook, clock} = mountAnimated()
    ctx.command("set_features", {geojson: fc(point("u1", 0, 0))})
    clock.advance(1000)
    ctx.command("set_features", {geojson: fc(point("u1", 0.01, 0))})
    assert.ok(clock.pending > 0)

    hook.destroyed.call(ctx)
    assert.equal(clock.pending, 0)
  })
})
