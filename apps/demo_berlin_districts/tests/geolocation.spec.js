const { test, expect } = require("@playwright/test")

const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4001"

// The map id is generated per LiveView session (see DemoWeb.MapLive), so
// everything here matches on the id prefix instead of a fixed id.
const MAP_ID_PREFIX = "map-geolocation-"
const MAP = `[id^="${MAP_ID_PREFIX}"]`
const GEOLOCATE_BUTTON = `${MAP} .maplibregl-ctrl-geolocate`
const LOCATION_DOT = `${MAP} .maplibregl-user-location-dot`
const ACCURACY_CIRCLE = `${MAP} .maplibregl-user-location-accuracy-circle`

/**
 * The library hook (`priv/js/hook.js`) only *adds* a MapLibre
 * `GeolocateControl` (trackUserLocation: false, showAccuracyCircle: true,
 * showUserLocation: true) and flies to the reported position. It never
 * triggers geolocation on its own and never adds a custom "user-location"
 * source/layer, so every marker below comes from the control itself and only
 * appears after the geolocate button is clicked (or the server sends the
 * `request_geolocation` command, which this page does not).
 */
async function installHookFinder(page) {
  await page.addInitScript(() => {
    window.__findMapElement = (mapIdPrefix) => document.querySelector(`[id^="${mapIdPrefix}"]`)

    window.__findMapHook = (mapIdPrefix) => {
      const queue = [{ value: window.liveSocket, depth: 0 }]
      const visited = new Set()

      while (queue.length > 0) {
        const current = queue.shift()
        if (!current) continue

        const { value, depth } = current
        if (!value || typeof value !== "object" || visited.has(value)) continue
        if (value instanceof Node || value === window) continue

        visited.add(value)

        if (typeof value.mapId === "string" && value.mapId.startsWith(mapIdPrefix) && value.map) {
          return value
        }
        if (depth >= 6) continue

        for (const key of Object.keys(value)) {
          if (key === "ownerDocument" || key === "window") continue

          let child
          try {
            child = value[key]
          } catch {
            continue
          }

          if (child && typeof child === "object") queue.push({ value: child, depth: depth + 1 })
        }
      }

      return null
    }
  })
}

function collectMessages(page, { captureAll = false } = {}) {
  const errors = []
  const logs = []

  page.on("console", (message) => {
    const entry = { type: message.type(), text: message.text() }
    if (captureAll) logs.push(entry)
    if (entry.type === "error") errors.push(entry.text)
  })

  page.on("pageerror", (error) => {
    errors.push(error.message)
    if (captureAll) logs.push({ type: "pageerror", text: error.message })
  })

  return { errors, logs }
}

async function readGeolocationState(page) {
  const dot = page.locator(LOCATION_DOT).first()
  const circle = page.locator(ACCURACY_CIRCLE).first()

  return {
    dotVisible: await dot.isVisible().catch(() => false),
    circleVisible: await circle.isVisible().catch(() => false),
  }
}

async function waitForGeolocationMarker(page, timeout = 7_500) {
  await expect
    .poll(async () => {
      const { dotVisible, circleVisible } = await readGeolocationState(page)
      return dotVisible || circleVisible
    }, { timeout })
    .toBe(true)
}

async function clickGeolocate(page, timeout = 7_500) {
  const geoButton = page.locator(GEOLOCATE_BUTTON).first()
  await expect(geoButton).toBeVisible({ timeout })
  await expect(geoButton).toBeEnabled({ timeout })
  await geoButton.click()
  return geoButton
}

test.describe("geolocation", () => {
  test.use({
    geolocation: { latitude: 52.52, longitude: 13.405, accuracy: 30 },
  })

  test("shows user location after clicking geolocate with granted permission", async ({ page, context }) => {
    await context.grantPermissions(["geolocation"])
    const { errors } = collectMessages(page)

    await page.goto(`${baseURL}/map`, { waitUntil: "networkidle" })

    await clickGeolocate(page)
    await waitForGeolocationMarker(page)

    const state = await readGeolocationState(page)
    expect(state.dotVisible).toBe(true)
    expect(state.circleVisible).toBe(true)
    expect(errors).toEqual([])
  })

  test("keeps the user-location marker visible after the fly-to settles", async ({ page, context }) => {
    await context.grantPermissions(["geolocation"])

    await page.goto(`${baseURL}/map`, { waitUntil: "networkidle" })

    await clickGeolocate(page)
    await waitForGeolocationMarker(page)

    // flyOnGeolocate is on by default; the marker must survive the camera move.
    await expect
      .poll(async () => {
        const state = await readGeolocationState(page)
        return state.dotVisible || state.circleVisible
      }, { timeout: 5_000 })
      .toBe(true)
  })

  test("exposes geolocation control internals with init-script instrumentation", async ({ page, context }) => {
    await context.grantPermissions(["geolocation"])
    const { errors, logs } = collectMessages(page, { captureAll: true })
    await installHookFinder(page)

    await page.addInitScript(() => {
      const geolocation = navigator.geolocation
      const originalGetCurrentPosition = geolocation.getCurrentPosition.bind(geolocation)
      const originalWatchPosition = geolocation.watchPosition.bind(geolocation)

      geolocation.getCurrentPosition = (...args) => {
        console.log("navigator.geolocation.getCurrentPosition called", args.length)
        return originalGetCurrentPosition(...args)
      }

      geolocation.watchPosition = (...args) => {
        console.log("navigator.geolocation.watchPosition called", args.length)
        return originalWatchPosition(...args)
      }
    })

    await page.goto(`${baseURL}/map`, { waitUntil: "networkidle" })
    await clickGeolocate(page)
    await waitForGeolocationMarker(page)

    const internals = await page.evaluate((mapIdPrefix) => {
      const element = window.__findMapElement(mapIdPrefix)
      const hook = window.__findMapHook(mapIdPrefix)

      let config = null
      try {
        config = JSON.parse(element?.dataset.config ?? "null")
      } catch {
        config = null
      }

      return {
        hasMap: !!hook?.map,
        hasGeolocateControl: !!hook?.geolocate,
        config: config ? { geolocation: config.geolocation, flyOnGeolocate: config.flyOnGeolocate } : null,
        geoButton: !!document.querySelector(`[id^="${mapIdPrefix}"] .maplibregl-ctrl-geolocate`),
      }
    }, MAP_ID_PREFIX)

    expect(internals.geoButton).toBe(true)
    expect(internals.hasMap).toBe(true)
    expect(internals.hasGeolocateControl).toBe(true)
    expect(internals.config).toEqual({ geolocation: true, flyOnGeolocate: true })
    expect(errors).toEqual([])

    // trackUserLocation is false, so the control uses getCurrentPosition.
    expect(logs.some((entry) => entry.text.includes("getCurrentPosition called"))).toBe(true)

    test.info().annotations.push(
      { type: "internals", description: JSON.stringify(internals) },
      { type: "logs", description: JSON.stringify(logs.slice(0, 50)) },
    )
  })

  test("renders geolocation marker when permission is granted after load", async ({ page }) => {
    const { logs } = collectMessages(page, { captureAll: true })

    await page.goto(`${baseURL}/map`, { waitUntil: "domcontentloaded" })

    const geoButton = page.locator(GEOLOCATE_BUTTON).first()
    await expect(geoButton).toBeVisible()

    await page.context().grantPermissions(["geolocation"])

    await clickGeolocate(page)
    await waitForGeolocationMarker(page)

    const state = await readGeolocationState(page)
    expect(state.dotVisible).toBe(true)
    expect(state.circleVisible).toBe(true)

    test.info().annotations.push({ type: "logs", description: JSON.stringify(logs) })
  })

  test("does not add custom geolocation layers alongside the built-in control", async ({ page, context }) => {
    await context.grantPermissions(["geolocation"])
    await installHookFinder(page)

    await page.goto(`${baseURL}/map`, { waitUntil: "networkidle" })

    await clickGeolocate(page)
    await waitForGeolocationMarker(page)

    const state = await page.evaluate((mapIdPrefix) => {
      const map = window.__findMapHook(mapIdPrefix)?.map

      return {
        hasMap: !!map,
        hasCustomSource: !!(map && map.getSource("user-location")),
        hasCustomAccuracyLayer: !!(map && map.getLayer("user-location-accuracy")),
        hasCustomPointLayer: !!(map && map.getLayer("user-location-point")),
      }
    }, MAP_ID_PREFIX)

    expect(state.hasMap).toBe(true)
    expect(state.hasCustomSource).toBe(false)
    expect(state.hasCustomAccuracyLayer).toBe(false)
    expect(state.hasCustomPointLayer).toBe(false)
  })

  test("survives delayed style loading without race-condition errors", async ({ page, context }) => {
    await context.grantPermissions(["geolocation"])
    const { errors } = collectMessages(page)

    await page.route(/style\.json/, async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 4_000))
      await route.continue()
    })

    await page.goto(`${baseURL}/map`, { waitUntil: "domcontentloaded" })

    await clickGeolocate(page, 15_000)
    await waitForGeolocationMarker(page, 10_000)

    const state = await readGeolocationState(page)
    expect(state.dotVisible).toBe(true)
    expect(state.circleVisible).toBe(true)
    expect(errors).toEqual([])
  })
})
