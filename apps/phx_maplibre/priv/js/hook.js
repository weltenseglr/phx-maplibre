import {pushMapEvent, viewportPayload} from "./events.js"
import {addLayers, addSources, emptyFeatureCollection} from "./sources_layers.js"
import {observeTheme, onStyleLoad, preferredStyle} from "./theme.js"
import {bindInteractions} from "./interactions.js"
import {clearPopupTracking, refreshPopup} from "./popup.js"
import {initAnimateState, stopAnimateLoop, updateAnimateMode, updateAnimatedFeatures} from "./animate.js"

const LIGHT = "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json"
const DARK = "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json"

const defaults = {
  center: {lng: 13.405, lat: 52.52},
  zoom: 11,
  lightStyle: LIGHT,
  darkStyle: DARK,
  cluster: true,
  navigation: true,
  geolocation: false,
  flyOnGeolocate: true,
  events: [],
  moveEndThrottleMs: 1000,
  animateMinZoom: 12,
}

const number = (value, fallback) => (Number.isFinite(Number(value)) ? Number(value) : fallback)

/**
 * Read the hook element's JSON `data-config` and coerce every field to the type
 * the rest of the hook expects. Malformed JSON or a bad field falls back to the
 * default rather than throwing, so a broken attribute still yields a live map.
 */
export function parseConfig(el) {
  let raw = {}
  try {
    raw = JSON.parse(el.dataset.config || "{}")
  } catch (_) {
    // fall through to defaults on malformed JSON
  }

  return {
    center: {
      lng: number(raw.center?.lng, defaults.center.lng),
      lat: number(raw.center?.lat, defaults.center.lat),
    },
    zoom: number(raw.zoom, defaults.zoom),
    lightStyle: typeof raw.lightStyle === "string" ? raw.lightStyle : defaults.lightStyle,
    darkStyle: typeof raw.darkStyle === "string" ? raw.darkStyle : defaults.darkStyle,
    cluster: typeof raw.cluster === "boolean" ? raw.cluster : defaults.cluster,
    clusterColor: typeof raw.clusterColor === "string" ? raw.clusterColor : null,
    navigation: typeof raw.navigation === "boolean" ? raw.navigation : defaults.navigation,
    geolocation: raw.geolocation === true,
    flyOnGeolocate: raw.flyOnGeolocate !== false,
    events: Array.isArray(raw.events) ? raw.events.filter((event) => typeof event === "string") : [],
    moveEndThrottleMs: Math.max(0, number(raw.moveEndThrottleMs, defaults.moveEndThrottleMs)),
    // false is the canonical disabled value on the wire; null is accepted as
    // its alias. Absent or malformed falls back to the default (on).
    animateMinZoom:
      raw.animateMinZoom === false || raw.animateMinZoom === null
        ? null
        : number(raw.animateMinZoom, defaults.animateMinZoom),
  }
}

function addControls(hook, maplibregl) {
  if (hook.config.navigation) {
    hook.map.addControl(new maplibregl.NavigationControl(), "top-right")
  }

  if (hook.config.geolocation) {
    hook.geolocate = new maplibregl.GeolocateControl({
      positionOptions: {enableHighAccuracy: true, timeout: 8000, maximumAge: 0},
      trackUserLocation: false,
      showAccuracyCircle: true,
      showUserLocation: true,
    })
    hook.map.addControl(hook.geolocate, "top-right")

    hook.geolocate.on("geolocate", (event) => {
      const coords = event.coords
      pushMapEvent(hook, "geolocation_success", {
        lng: coords.longitude,
        lat: coords.latitude,
        accuracy: coords.accuracy,
      })
      if (hook.config.flyOnGeolocate) {
        hook.map.flyTo({center: [coords.longitude, coords.latitude], zoom: 14, essential: true})
      }
    })

    hook.geolocate.on("error", (event) => {
      pushMapEvent(hook, "geolocation_error", {code: event.code, message: event.message})
    })
  }
}

function registerCommands(hook) {
  const command = (name, handler) => hook.handleEvent(`maplibre:${hook.mapId}:${name}`, handler)

  command("set_features", ({geojson} = {}) => {
    hook.pointsData = geojson || emptyFeatureCollection()
    updateAnimatedFeatures(hook)

    if (hook.animActive) {
      // The clustered source is hidden; rebuilding (and reclustering) it every
      // update would be pure waste. The stash flushes on the downward flip.
      hook.pointsDirty = true
    } else {
      hook.map.getSource("points")?.setData(hook.pointsData)
      refreshPopup(hook, "point", hook.pointsData)
      hook.pointsDirty = false
    }
  })

  command("set_area_features", ({geojson} = {}) => {
    hook.areasData = geojson || emptyFeatureCollection()
    hook.map.getSource("areas")?.setData(hook.areasData)
    refreshPopup(hook, "area", hook.areasData)
  })

  command("fly_to", (params = {}) => {
    if (!params.center) return
    hook.map.flyTo({
      center: [params.center.lng, params.center.lat],
      zoom: number(params.zoom, 14),
      duration: number(params.duration, 1500),
      essential: true,
    })
  })

  command("fit_bounds", (params = {}) => {
    const bounds = params.bounds
    if (!bounds) return
    hook.map.fitBounds([[bounds.west, bounds.south], [bounds.east, bounds.north]], {
      padding: params.padding ?? 40,
      maxZoom: params.max_zoom ?? 15,
      duration: 800,
    })
  })

  command("set_style", ({style} = {}) => {
    if (typeof style !== "string") return
    hook.currentStyle = style
    hook.styleReloading = true
    // The popup is anchored to a layer the new style arrives without, so it
    // would hang around pointing at nothing. Same as the theme swap does.
    if (hook.popup) {
      hook.popup.remove()
      hook.popup = null
      clearPopupTracking(hook)
    }
    hook.map.setStyle(style, {diff: true})
  })

  command("request_geolocation", () => hook.geolocate?.trigger())
}

/**
 * Build the hook object LiveView mounts, closing over the MapLibre GL module
 * the caller supplies. Nothing here imports MapLibre, so the app stays in
 * charge of which version ships and where its stylesheet comes from.
 */
export function createHook(maplibregl, options = {}) {
  const popupContent = typeof options.popupContent === "function" ? options.popupContent : null
  // Timing seams: production uses the browser clock and rAF; tests inject.
  const now = typeof options.now === "function" ? options.now : () => performance.now()
  const raf =
    typeof options.raf === "function"
      ? options.raf
      : typeof requestAnimationFrame === "function"
        ? (cb) => requestAnimationFrame(cb)
        : () => null
  const caf =
    typeof options.caf === "function"
      ? options.caf
      : typeof cancelAnimationFrame === "function"
        ? (id) => cancelAnimationFrame(id)
        : () => {}

  return {
    mounted() {
      this.maplibregl = maplibregl
      this.popupContent = popupContent
      this.now = now
      this.raf = raf
      this.caf = caf
      this.mapId = this.el.id
      this.config = parseConfig(this.el)
      this.pointsData = emptyFeatureCollection()
      this.areasData = emptyFeatureCollection()
      this.hoveredAreaId = null
      this.selectedAreaId = null
      this.hoveredPointId = null
      this.selectedPointId = null
      this.selectedPointIdLinkedId = null
      this.hoveredClusterId = null
      this.lastMoveEnd = 0
      this.ready = false
      this.styleReloading = false
      this.currentStyle = preferredStyle(this.config)
      initAnimateState(this)

      this.map = new maplibregl.Map({
        container: this.el,
        style: this.currentStyle,
        center: [this.config.center.lng, this.config.center.lat],
        zoom: this.config.zoom,
        attributionControl: true,
        hash: false,
      })

      addControls(this, maplibregl)

      this.map.on("load", () => {
        addSources(this.map, this.config.cluster)
        addLayers(this.map, this.config.cluster, this.config.clusterColor)
        // Commands can arrive between mount and the initial style load;
        // apply whatever data they stored so it isn't lost.
        this.map.getSource("points")?.setData(this.pointsData)
        this.map.getSource("areas")?.setData(this.areasData)
        bindInteractions(this)
        this.ready = true
        // Features buffered before the initial style load snap into place on
        // the animated source too (nothing meaningful to tween from yet).
        updateAnimatedFeatures(this, {tween: false})
        pushMapEvent(this, "ready", viewportPayload(this.map))
      })

      this.map.on("zoomend", () => updateAnimateMode(this))

      this.map.on("style.load", () => {
        if (this.ready && this.styleReloading) onStyleLoad(this)
      })

      observeTheme(this)
      registerCommands(this)
    },

    destroyed() {
      stopAnimateLoop(this)
      clearTimeout(this.themeTimer)
      this.themeObserver?.disconnect()
      if (this.popup) this.popup.remove()
      this.map?.remove()
      this.map = null
    },
  }
}
