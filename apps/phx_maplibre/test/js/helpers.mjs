// Minimal fakes for the browser globals and the MapLibre GL module that
// apps/phx_maplibre/priv/js/*.js touch, plus small helpers for driving the
// hook the way Phoenix LiveView does. Node-native (node:test + node:assert)
// only — no npm dependencies, no jsdom.

import {createMapHook} from "../../priv/js/phx_maplibre.js"

// ---------------------------------------------------------------------------
// document / window / MutationObserver
// ---------------------------------------------------------------------------

function escapeForInnerHTML(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

/**
 * Install fake `document`, `window`, and `MutationObserver` globals for the
 * duration of a test. `theme` seeds `document.documentElement.dataset.theme`.
 * Call `uninstallGlobals()` afterwards (e.g. in `afterEach`) to avoid leaking
 * state between tests.
 */
export function installGlobals({theme} = {}) {
  const documentElement = {dataset: theme ? {theme} : {}}

  const fakeDocument = {
    documentElement,
    createElement(_tag) {
      let text = ""
      return {
        set textContent(value) {
          text = String(value)
        },
        get textContent() {
          return text
        },
        get innerHTML() {
          return escapeForInnerHTML(text)
        },
      }
    },
  }

  const fakeWindow = {
    matchMedia(query) {
      return {matches: false, media: query, addListener() {}, removeListener() {}}
    },
  }

  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback
      this.disconnected = false
      this.observeArgs = null
    }

    observe(target, options) {
      this.observeArgs = {target, options}
    }

    disconnect() {
      this.disconnected = true
    }

    // test helper, not part of the real MutationObserver API
    _trigger(changes) {
      this.callback(changes, this)
    }
  }

  globalThis.document = fakeDocument
  globalThis.window = fakeWindow
  globalThis.MutationObserver = FakeMutationObserver

  return {document: fakeDocument, window: fakeWindow, MutationObserver: FakeMutationObserver}
}

export function uninstallGlobals() {
  delete globalThis.document
  delete globalThis.window
  delete globalThis.MutationObserver
}

// ---------------------------------------------------------------------------
// Fake maplibregl module
// ---------------------------------------------------------------------------

/**
 * A fake `maplibregl.Map`. Records every call the hook makes so tests can
 * assert on them, and lets tests fire the events the hook registers with
 * `map.on(...)` (both the plain `map.on(type, handler)` form and the
 * layer-scoped `map.on(type, layer, handler)` form).
 */
export class FakeMap {
  constructor(options = {}) {
    this.options = options
    this.container = options.container
    this.style = options.style
    this._sources = {}
    this._layers = new Set()
    this._handlers = {}
    this.controls = []
    this.styleCalls = []
    this.flyToCalls = []
    this.fitBoundsCalls = []
    this.easeToCalls = []
    this.setFeatureStateCalls = []
    this.layoutCalls = []
    this._visibility = {}
    this._zoom = 10
    this.removed = false
  }

  on(type, layerOrHandler, maybeHandler) {
    const layer = typeof maybeHandler === "function" ? layerOrHandler : undefined
    const handler = typeof maybeHandler === "function" ? maybeHandler : layerOrHandler
    ;(this._handlers[type] ||= []).push({layer, handler})
  }

  /** Fire every plain (non layer-scoped) handler registered for `type`. */
  _fire(type, event) {
    for (const {layer, handler} of this._handlers[type] || []) {
      if (layer === undefined) handler(event)
    }
  }

  /** Fire every handler registered for `type` on the given `layer`. */
  _fireLayer(type, layer, event) {
    for (const {layer: boundLayer, handler} of this._handlers[type] || []) {
      if (boundLayer === layer) handler(event)
    }
  }

  addSource(id, def) {
    this._sources[id] = {
      id,
      def,
      data: def.data,
      setData(data) {
        this.data = data
      },
      getData() {
        return this.data
      },
      getClusterExpansionZoom(_clusterId) {
        return Promise.resolve(14)
      },
    }
  }

  getSource(id) {
    return this._sources[id]
  }

  addLayer(layerDef) {
    this._layers.add(layerDef.id)
  }

  getLayer(id) {
    return this._layers.has(id) ? {id} : undefined
  }

  addControl(control, position) {
    this.controls.push({control, position})
  }

  setStyle(style, opts) {
    this.style = style
    this.styleCalls.push({style, opts})
    // Real MapLibre swaps in a style with none of our custom sources/layers;
    // they only come back once `addSources`/`addLayers` re-run on style.load.
    this._sources = {}
    this._layers = new Set()
  }

  flyTo(opts) {
    this.flyToCalls.push(opts)
  }

  fitBounds(bounds, opts) {
    this.fitBoundsCalls.push({bounds, opts})
  }

  easeTo(opts) {
    this.easeToCalls.push(opts)
  }

  setFeatureState(target, state) {
    this.setFeatureStateCalls.push({target, state})
  }

  getCanvas() {
    this._canvas ||= {style: {cursor: ""}}
    return this._canvas
  }

  queryRenderedFeatures(_pointOrOpts, _opts) {
    return []
  }

  getBounds() {
    return {getWest: () => -1, getSouth: () => -2, getEast: () => 1, getNorth: () => 2}
  }

  getCenter() {
    return {lng: 0, lat: 0}
  }

  getZoom() {
    return this._zoom
  }

  /** test helper: set the zoom `getZoom` reports (optionally firing zoomend). */
  _setZoom(zoom, {fire = false} = {}) {
    this._zoom = zoom
    if (fire) this._fire("zoomend", {})
  }

  setLayoutProperty(layerId, name, value) {
    this.layoutCalls.push({layerId, name, value})
    if (name === "visibility") this._visibility[layerId] = value
  }

  remove() {
    this.removed = true
  }
}

export class FakeNavigationControl {}

export class FakeGeolocateControl {
  constructor(options) {
    this.options = options
    this._handlers = {}
    this.triggered = false
  }

  on(type, handler) {
    ;(this._handlers[type] ||= []).push(handler)
  }

  trigger() {
    this.triggered = true
  }

  _fire(type, event) {
    for (const handler of this._handlers[type] || []) handler(event)
  }
}

export class FakePopup {
  constructor(options) {
    this.options = options
    this.removed = false
    this.html = null
    this.lngLat = null
    this.addedToMap = null
  }

  setLngLat(lngLat) {
    this.lngLat = lngLat
    return this
  }

  setHTML(html) {
    this.html = html
    return this
  }

  setDOMContent(node) {
    this.domContent = node
    return this
  }

  addTo(map) {
    this.addedToMap = map
    return this
  }

  remove() {
    this.removed = true
    return this
  }
}

export function createFakeMaplibre() {
  return {
    Map: FakeMap,
    NavigationControl: FakeNavigationControl,
    GeolocateControl: FakeGeolocateControl,
    Popup: FakePopup,
  }
}

// ---------------------------------------------------------------------------
// LiveView-shaped hook context
// ---------------------------------------------------------------------------

/**
 * A fake LiveView hook context: `el` (with `id` and `dataset.config`),
 * `pushEvent` (recorded), and `handleEvent` (recorded by name so tests can
 * dispatch commands the way LiveView's `push_event` would).
 */
export function createCtx({id = "map-1", config = {}} = {}) {
  const el = {id, dataset: {config: JSON.stringify(config)}}
  const handlers = new Map()
  const pushedEvents = []

  return {
    el,
    pushedEvents,
    pushEvent(name, payload) {
      pushedEvents.push({name, payload})
    },
    handleEvent(name, handler) {
      handlers.set(name, handler)
    },
    /** Dispatch a raw LiveView event name (e.g. from `handleEvent`). */
    dispatch(name, payload) {
      const handler = handlers.get(name)
      if (!handler) throw new Error(`no handler registered for "${name}"`)
      return handler(payload)
    },
    /** Dispatch a `maplibre:{id}:{name}` command, as PhxMaplibre.push_event does. */
    command(name, payload) {
      return this.dispatch(`maplibre:${id}:${name}`, payload)
    },
  }
}

/** Build a hook via `createMapHook` and mount it onto a fresh ctx. */
export function mountHook({
  id = "map-1",
  config = {},
  maplibregl = createFakeMaplibre(),
  options = {},
} = {}) {
  const ctx = createCtx({id, config})
  const hook = createMapHook(maplibregl, options)
  hook.mounted.call(ctx)
  return {ctx, hook, maplibregl}
}

/**
 * A manual-pump clock + rAF pair for animation tests: `clock.now()` is the
 * time source, `clock.advance(ms)` moves it, and `clock.pump()` runs every
 * callback scheduled since the last pump (one frame).
 */
export function createFakeClock(startMs = 100_000) {
  let now = startMs
  let nextId = 1
  let scheduled = new Map()

  return {
    now: () => now,
    raf: (cb) => {
      const id = nextId++
      scheduled.set(id, cb)
      return id
    },
    caf: (id) => scheduled.delete(id),
    advance(ms) {
      now += ms
    },
    pump() {
      const due = scheduled
      scheduled = new Map()
      for (const cb of due.values()) cb()
    },
    get pending() {
      return scheduled.size
    },
  }
}

/** `mountHook`, then fire the map's `load` event so the hook is fully ready. */
export function mountAndLoad(opts) {
  const result = mountHook(opts)
  result.ctx.map._fire("load")
  return result
}
