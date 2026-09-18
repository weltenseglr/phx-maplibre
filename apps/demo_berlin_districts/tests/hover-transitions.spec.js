const { test, expect } = require("@playwright/test")

const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4001"
// The map id is generated per LiveView session (see DemoWeb.MapLive), so
// everything here matches on the id prefix instead of a fixed id.
const MAP_ID_PREFIX = "map-districts-"

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

/**
 * Installs the instrumentation helpers used by every `page.evaluate` below.
 *
 * The phx_maplibre hook pushes map events with
 * `hook.pushEvent("maplibre:event", {id, event, payload})`, so patching
 * `hook.pushEvent` records exactly what the browser emits, before any server
 * round trip. `window.__districtHoverEvents` is the client-side mirror of the
 * `#district-hover-events` server harness (which keeps the last 3 events and a
 * monotonic counter) — we slice to the same window so the contract assertions
 * stay identical.
 */
async function installInstrumentation(page) {
  await page.addInitScript(() => {
    window.__districtHoverEvents = []
    window.__districtHoverStateTransitions = []

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

        // The library hook sets `this.mapId = this.el.id` in `mounted()`.
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

    window.__instrumentMapHook = (mapIdPrefix) => {
      const hook = window.__findMapHook(mapIdPrefix)
      if (!hook || !hook.map) return false
      if (hook.__hoverHarnessPatched) return true

      const originalPushEvent = hook.pushEvent.bind(hook)

      hook.pushEvent = (event, payload, onReply) => {
        if (
          event === "maplibre:event" &&
          payload &&
          payload.id === hook.mapId &&
          (payload.event === "feature_hovered" || payload.event === "feature_unhovered")
        ) {
          window.__districtHoverEvents.push({
            event: payload.event,
            payload: payload.payload,
            at: Math.round(performance.now()),
          })
        }

        return originalPushEvent(event, payload, onReply)
      }

      const originalSetFeatureState = hook.map.setFeatureState.bind(hook.map)

      hook.map.setFeatureState = (target, state) => {
        if (target?.source === "areas" && Object.prototype.hasOwnProperty.call(state, "hover")) {
          window.__districtHoverStateTransitions.push({
            featureStateId: target.id,
            hover: state.hover,
            at: Math.round(performance.now()),
          })
        }

        return originalSetFeatureState(target, state)
      }

      hook.__hoverHarnessPatched = true
      return true
    }
  })
}

async function readHarnessState(page) {
  return page.evaluate((mapIdPrefix) => {
    const readDomHoverEvents = () => {
      const node = document.getElementById("district-hover-events")
      if (!node?.textContent) return []

      try {
        return JSON.parse(node.textContent)
      } catch {
        return []
      }
    }

    const readDomHoverEventCount = () => {
      const node = document.getElementById("district-hover-event-count")
      const value = Number.parseInt(node?.textContent ?? "0", 10)
      return Number.isFinite(value) ? value : 0
    }

    const hook = window.__findMapHook(mapIdPrefix)
    const events = window.__districtHoverEvents

    return {
      hoveredAreaId: hook?.hoveredAreaId ?? null,
      transitions: window.__districtHoverStateTransitions.slice(),
      // same window the server harness keeps (`Enum.take(events, -3)`)
      hoverEvents: events.slice(-3),
      hoverEventCount: events.length,
      domHoverEvents: readDomHoverEvents(),
      domHoverEventCount: readDomHoverEventCount(),
    }
  }, MAP_ID_PREFIX)
}

async function ensureDistrictHoverHarness(page) {
  return page.evaluate((mapIdPrefix) => {
    if (!window.__instrumentMapHook(mapIdPrefix)) return null

    const element = window.__findMapElement(mapIdPrefix)
    if (!element) return null

    window.__districtHoverStateTransitions = []

    const rect = element.getBoundingClientRect()
    return { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
  }, MAP_ID_PREFIX)
}

async function readDistrictFeatureAt(page, localX, localY) {
  return page.evaluate(({ mapIdPrefix, localX, localY }) => {
    const hook = window.__findMapHook(mapIdPrefix)
    if (!hook?.map) return null

    const feature = hook.map.queryRenderedFeatures({ x: localX, y: localY }, { layers: ["area-fill"] })[0]
    if (!feature) return null

    return {
      featureStateId: feature.id,
      payloadId: feature.properties?.id ?? null,
      title: feature.properties?.title ?? null,
    }
  }, { mapIdPrefix: MAP_ID_PREFIX, localX, localY })
}

async function discoverPreparationViaMouse(page) {
  const rect = await ensureDistrictHoverHarness(page)
  if (!rect) return null

  const moveAndRead = async (point, steps = 1, pause = 80) => {
    await page.mouse.move(point.pageX, point.pageY, { steps })
    await sleep(pause)
    return readHarnessState(page)
  }

  const makePoint = (localX, localY) => ({
    pageX: Math.round(rect.left + localX),
    pageY: Math.round(rect.top + localY),
    localX,
    localY,
  })

  await page.mouse.move(Math.max(Math.round(rect.left) - 20, 0), Math.round(rect.top + (rect.height / 2)), { steps: 1 })
  await sleep(80)

  for (let localY = 24; localY <= rect.height - 24; localY += 20) {
    for (let localX = 24; localX <= rect.width - 24; localX += 20) {
      const fromPoint = makePoint(localX, localY)
      const enteredState = await moveAndRead(fromPoint, 1, 70)
      if (!enteredState.hoveredAreaId) continue

      const fromFeature = await readDistrictFeatureAt(page, localX, localY)
      if (!fromFeature || fromFeature.featureStateId !== enteredState.hoveredAreaId) continue

      let intraPoint = null

      for (let radius = 2; radius <= 24 && !intraPoint; radius += 2) {
        for (let angle = 0; angle < 360; angle += 30) {
          const radians = (angle * Math.PI) / 180
          const candidateX = localX + Math.round(radius * Math.cos(radians))
          const candidateY = localY + Math.round(radius * Math.sin(radians))

          if (candidateX < 0 || candidateX > rect.width || candidateY < 0 || candidateY > rect.height) continue

          const baseline = await moveAndRead(fromPoint, 1, 40)
          const candidatePoint = makePoint(candidateX, candidateY)
          const candidateState = await moveAndRead(candidatePoint, 1, 40)

          if (candidateState.hoveredAreaId === baseline.hoveredAreaId && candidateState.hoverEventCount === baseline.hoverEventCount) {
            intraPoint = candidatePoint
            break
          }
        }
      }

      if (!intraPoint) continue

      for (let radius = 12; radius <= 220; radius += 12) {
        for (let angle = 0; angle < 360; angle += 15) {
          const radians = (angle * Math.PI) / 180
          const candidateX = intraPoint.localX + Math.round(radius * Math.cos(radians))
          const candidateY = intraPoint.localY + Math.round(radius * Math.sin(radians))

          if (candidateX < 0 || candidateX > rect.width || candidateY < 0 || candidateY > rect.height) continue

          const baseline = await moveAndRead(intraPoint, 1, 40)
          const candidatePoint = makePoint(candidateX, candidateY)
          const transitionState = await moveAndRead(candidatePoint, 18, 120)
          const delta = transitionState.hoverEventCount - baseline.hoverEventCount
          const second = transitionState.hoverEvents.at(-2)
          const third = transitionState.hoverEvents.at(-1)

          if (
            delta === 2 &&
            transitionState.hoveredAreaId !== baseline.hoveredAreaId &&
            second?.event === "feature_unhovered" &&
            third?.event === "feature_hovered"
          ) {
            return {
              from: {
                ...fromFeature,
                ...fromPoint,
                payloadId: second.payload?.id ?? fromFeature.payloadId,
                title: second.payload?.title ?? fromFeature.title,
              },
              intra: { ...fromFeature, ...intraPoint },
              to: {
                ...candidatePoint,
                featureStateId: transitionState.hoveredAreaId,
                payloadId: third.payload?.id ?? null,
                title: third.payload?.title ?? null,
              },
              initialHoverEvents: [],
              discoveredWithMouse: true,
            }
          }
        }
      }
    }
  }

  return null
}

async function runHoverScenario(page, testInfo, { injectDuplicateMeasuredPhase = false } = {}) {
  const consoleMessages = []
  const pageErrors = []

  page.on("console", (message) => {
    consoleMessages.push({ type: message.type(), text: message.text() })
  })

  page.on("pageerror", (error) => {
    pageErrors.push(error.message)
  })

  await installInstrumentation(page)
  // The hover contract concerns the local district source, not basemap tiles.
  await page.route('https://basemaps.cartocdn.com/gl/**/style.json', route => route.fulfill({json: {
    version: 8,
    sources: {},
    layers: [{id: 'background', type: 'background', paint: {'background-color': '#ffffff'}}],
  }}))
  await page.setViewportSize({ width: 1600, height: 1400 })
  await page.goto(`${baseURL}/map`)
  await expect.poll(() => page.evaluate(mapIdPrefix => {
    const hook = window.__findMapHook(mapIdPrefix)
    return {
      hookReady: Boolean(hook?.ready),
      featuresReady: Boolean(hook?.areasData?.features.length),
      layerReady: Boolean(hook?.map.getLayer('area-fill')),
      sourceReady: Boolean(hook?.map.getSource('areas') && hook.map.isSourceLoaded('areas')),
    }
  }, MAP_ID_PREFIX), {timeout: 15_000, message: 'district source is ready for hover queries'})
    .toEqual({hookReady: true, featuresReady: true, layerReady: true, sourceReady: true})

  let preparation = await page.evaluate(async (mapIdPrefix) => {
    const sleep = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms))

    const waitForHook = async () => {
      for (let attempt = 0; attempt < 20; attempt += 1) {
        const hook = window.__findMapHook(mapIdPrefix)
        if (hook && hook.map && typeof hook.map.queryRenderedFeatures === "function") {
          return hook
        }
        await sleep(250)
      }

      return null
    }

    const hook = await waitForHook()
    if (!hook) return { error: `Could not locate the ${mapIdPrefix}* hook via window.liveSocket.` }

    window.__instrumentMapHook(mapIdPrefix)

    const map = hook.map
    const element = window.__findMapElement(mapIdPrefix)
    const rect = element.getBoundingClientRect()

    // Listen before the camera change and wait for the rendered camera, rather
    // than global idle (which may never occur while other sources are updating).
    await new Promise(resolve => {
      map.once('render', resolve)
      map.fitBounds([[13.05, 52.32], [13.78, 52.68]], { padding: 24, duration: 0 })
    })

    const flattenCoordinates = (coordinates) => {
      if (!Array.isArray(coordinates) || coordinates.length === 0) return []
      if (coordinates.length === 2 && typeof coordinates[0] === "number" && typeof coordinates[1] === "number") return [coordinates]
      return coordinates.flatMap((entry) => flattenCoordinates(entry))
    }

    const computeBBox = (feature) => {
      const points = flattenCoordinates(feature.geometry?.coordinates ?? [])
      return points.reduce(
        (accumulator, [lng, lat]) => ({
          west: Math.min(accumulator.west, lng),
          south: Math.min(accumulator.south, lat),
          east: Math.max(accumulator.east, lng),
          north: Math.max(accumulator.north, lat),
        }),
        { west: Infinity, south: Infinity, east: -Infinity, north: -Infinity },
      )
    }

    const bboxGap = (left, right) => {
      const xGap = Math.max(0, Math.max(left.west, right.west) - Math.min(left.east, right.east))
      const yGap = Math.max(0, Math.max(left.south, right.south) - Math.min(left.north, right.north))
      return Math.sqrt((xGap ** 2) + (yGap ** 2))
    }

    const bboxCenter = (bbox) => ({ lng: (bbox.west + bbox.east) / 2, lat: (bbox.south + bbox.north) / 2 })
    const distanceBetween = (left, right) => Math.sqrt(((left.lng - right.lng) ** 2) + ((left.lat - right.lat) ** 2))

    // The library hook keeps the last pushed area FeatureCollection on `areasData`.
    let sourceFeatures = hook.areasData?.features ?? []
    for (let attempt = 0; attempt < 10 && sourceFeatures.length === 0; attempt += 1) {
      await sleep(250)
      sourceFeatures = hook.areasData?.features ?? []
    }

    if (sourceFeatures.length === 0) {
      return { error: "Could not load district area features from the map hook." }
    }

    const featureCandidates = sourceFeatures.map((feature) => ({ feature, bbox: computeBBox(feature) }))
    const candidatePairs = []

    for (let leftIndex = 0; leftIndex < featureCandidates.length; leftIndex += 1) {
      for (let rightIndex = leftIndex + 1; rightIndex < featureCandidates.length; rightIndex += 1) {
        const left = featureCandidates[leftIndex]
        const right = featureCandidates[rightIndex]
        const gap = bboxGap(left.bbox, right.bbox)
        if (gap > 0.03) continue

        candidatePairs.push({
          left,
          right,
          gap,
          distance: distanceBetween(bboxCenter(left.bbox), bboxCenter(right.bbox)),
        })
      }
    }

    candidatePairs.sort((left, right) => left.distance - right.distance)

    const tryScreenPoint = (lng, lat, targetPayloadId) => {
      const projected = map.project([lng, lat])
      if (projected.x < 0 || projected.x > rect.width || projected.y < 0 || projected.y > rect.height) return null

      const renderedFeatures = map.queryRenderedFeatures({ x: Math.round(projected.x), y: Math.round(projected.y) }, { layers: ["area-fill"] })
      const renderedPayloadIds = renderedFeatures.map((feature) => feature.properties?.id ?? null).filter(Boolean)

      if (renderedPayloadIds.includes(targetPayloadId)) {
        return { x: Math.round(projected.x), y: Math.round(projected.y) }
      }

      return null
    }

    const findRenderedPointForFeature = (feature, { sampleCount = 12 } = {}) => {
      const bbox = computeBBox(feature)
      const targetPayloadId = feature.properties?.id ?? feature.id
      const targetTitle = feature.properties?.title ?? null

      const tryAndWrap = (lng, lat) => {
        const point = tryScreenPoint(lng, lat, targetPayloadId)
        if (!point) return null
        return { x: point.x, y: point.y, feature: { featureStateId: feature.id, payloadId: targetPayloadId, title: targetTitle } }
      }

      const centerResult = tryAndWrap((bbox.west + bbox.east) / 2, (bbox.south + bbox.north) / 2)
      if (centerResult) return centerResult

      for (let step = 1; step <= sampleCount; step += 1) {
        const progress = step / (sampleCount + 1)
        const lng = bbox.west + ((bbox.east - bbox.west) * progress)
        const lat = bbox.south + ((bbox.north - bbox.south) * progress)
        const result = tryAndWrap(lng, lat)
        if (result) return result
      }

      return null
    }

    let pair = null
    for (const candidatePair of candidatePairs) {
      const leftCell = findRenderedPointForFeature(candidatePair.left.feature)
      const rightCell = findRenderedPointForFeature(candidatePair.right.feature)
      if (!leftCell || !rightCell) continue

      pair = { from: leftCell, intra: leftCell, to: rightCell }
      break
    }

    if (!pair) {
      return {
        error: "Could not find an adjacent Berlin district transition target.",
        debug: {
          sourceFeatureCount: sourceFeatures.length,
          sourceFeatureIds: sourceFeatures.map((feature) => feature.properties?.id ?? feature.id).slice(0, 20),
          sourceFeatureTitles: sourceFeatures.map((feature) => feature.properties?.title ?? null).slice(0, 20),
          pairCount: candidatePairs.length,
        },
      }
    }

    window.__districtHoverStateTransitions = []

    window.__districtHoverHarness = {
      rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      from: pair.from,
      intra: pair.intra,
      to: pair.to,
    }

    const existingOverlay = document.getElementById("district-hover-harness-overlay")
    if (existingOverlay) existingOverlay.remove()

    const overlay = document.createElement("div")
    overlay.id = "district-hover-harness-overlay"
    overlay.style.position = "fixed"
    overlay.style.inset = "0"
    overlay.style.pointerEvents = "none"
    overlay.style.zIndex = "99999"

    const addMarker = (label, color, point) => {
      const marker = document.createElement("div")
      marker.textContent = label
      marker.style.position = "fixed"
      marker.style.left = `${rect.left + point.x}px`
      marker.style.top = `${rect.top + point.y}px`
      marker.style.transform = "translate(-50%, -50%)"
      marker.style.width = "22px"
      marker.style.height = "22px"
      marker.style.borderRadius = "9999px"
      marker.style.display = "flex"
      marker.style.alignItems = "center"
      marker.style.justifyContent = "center"
      marker.style.fontSize = "11px"
      marker.style.fontWeight = "700"
      marker.style.color = "white"
      marker.style.background = color
      marker.style.boxShadow = "0 0 0 2px white, 0 4px 12px rgba(0,0,0,0.35)"
      overlay.appendChild(marker)
    }

    addMarker("A", "#2563eb", pair.from)
    addMarker("A2", "#0f766e", pair.intra)
    addMarker("B", "#dc2626", pair.to)
    document.body.appendChild(overlay)

    return {
      from: { pageX: Math.round(rect.left + pair.from.x), pageY: Math.round(rect.top + pair.from.y), localX: pair.from.x, localY: pair.from.y, featureStateId: pair.from.feature.featureStateId, payloadId: pair.from.feature.payloadId, title: pair.from.feature.title },
      intra: { pageX: Math.round(rect.left + pair.intra.x), pageY: Math.round(rect.top + pair.intra.y), localX: pair.intra.x, localY: pair.intra.y, featureStateId: pair.intra.feature.featureStateId, payloadId: pair.intra.feature.payloadId, title: pair.intra.feature.title },
      to: { pageX: Math.round(rect.left + pair.to.x), pageY: Math.round(rect.top + pair.to.y), localX: pair.to.x, localY: pair.to.y, featureStateId: pair.to.feature.featureStateId, payloadId: pair.to.feature.payloadId, title: pair.to.feature.title },
      initialHoverEvents: window.__districtHoverEvents.slice(-3),
    }
  }, MAP_ID_PREFIX)

  if (preparation.error) {
    const discoveredPreparation = await discoverPreparationViaMouse(page)
    if (!discoveredPreparation) throw new Error(`${preparation.error} ${JSON.stringify(preparation.debug || {})}`)
    preparation = discoveredPreparation
  }

  await page.evaluate(({ mapIdPrefix, resolvedPreparation }) => {
    const element = window.__findMapElement(mapIdPrefix)
    if (!element) return

    const rect = element.getBoundingClientRect()
    window.__districtHoverHarness = {
      rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
      from: { x: resolvedPreparation.from.localX, y: resolvedPreparation.from.localY, feature: { featureStateId: resolvedPreparation.from.featureStateId, payloadId: resolvedPreparation.from.payloadId, title: resolvedPreparation.from.title } },
      intra: { x: resolvedPreparation.intra.localX, y: resolvedPreparation.intra.localY, feature: { featureStateId: resolvedPreparation.intra.featureStateId, payloadId: resolvedPreparation.intra.payloadId, title: resolvedPreparation.intra.title } },
      to: { x: resolvedPreparation.to.localX, y: resolvedPreparation.to.localY, feature: { featureStateId: resolvedPreparation.to.featureStateId, payloadId: resolvedPreparation.to.payloadId, title: resolvedPreparation.to.title } },
    }
  }, { mapIdPrefix: MAP_ID_PREFIX, resolvedPreparation: preparation })

  await page.mouse.move(preparation.from.pageX - 60, preparation.from.pageY, { steps: 4 })
  await page.mouse.move(preparation.from.pageX, preparation.from.pageY, { steps: 8 })
  await sleep(250)

  await page.mouse.move(preparation.from.pageX, preparation.from.pageY, { steps: 1 })
  await sleep(200)

  const afterEnter = await readHarnessState(page)

  if (injectDuplicateMeasuredPhase) {
    await page.evaluate((mapIdPrefix) => {
      const hook = window.__findMapHook(mapIdPrefix)
      if (!hook) return

      const { from } = window.__districtHoverHarness

      // The wire format the library uses for every map event.
      hook.pushEvent("maplibre:event", {
        id: hook.mapId,
        event: "feature_hovered",
        payload: {
          id: from.feature.payloadId ?? from.feature.featureStateId,
          kind: "area",
          title: from.feature.title ?? null,
        },
      })
    }, MAP_ID_PREFIX)
    await sleep(250)
  }

  await page.mouse.move(preparation.intra.pageX, preparation.intra.pageY, { steps: 1 })
  await sleep(200)

  const afterIntraMove = await readHarnessState(page)

  const measuredTransition = preparation.to

  let resolvedTransition = measuredTransition
  if (!resolvedTransition) throw new Error(`Could not find a direct adjacent transition target for hovered district ${afterIntraMove.hoveredAreaId}`)

  await page.mouse.move(resolvedTransition.pageX, resolvedTransition.pageY, { steps: 18 })
  await sleep(300)

  const afterTransition = await page.evaluate(({ mapIdPrefix, targetX, targetY }) => {
    const readDomHoverEvents = () => {
      const node = document.getElementById("district-hover-events")
      if (!node?.textContent) return []
      try {
        return JSON.parse(node.textContent)
      } catch {
        return []
      }
    }

    const readDomHoverEventCount = () => {
      const node = document.getElementById("district-hover-event-count")
      const value = Number.parseInt(node?.textContent ?? "0", 10)
      return Number.isFinite(value) ? value : 0
    }

    const hook = window.__findMapHook(mapIdPrefix)
    const map = hook.map
    const featureAtTarget = map.queryRenderedFeatures({ x: targetX, y: targetY }, { layers: ["area-fill"] })[0]
    const events = window.__districtHoverEvents

    return {
      hoveredAreaId: hook.hoveredAreaId,
      featureUnderTargetPoint: featureAtTarget
        ? { featureStateId: featureAtTarget.id, payloadId: featureAtTarget.properties?.id ?? null, title: featureAtTarget.properties?.title ?? null }
        : null,
      transitions: window.__districtHoverStateTransitions.slice(),
      hoverEvents: events.slice(-3),
      hoverEventCount: events.length,
      domHoverEvents: readDomHoverEvents(),
      domHoverEventCount: readDomHoverEventCount(),
    }
  }, { mapIdPrefix: MAP_ID_PREFIX, targetX: resolvedTransition.localX, targetY: resolvedTransition.localY })

  const activeFromPayloadId = preparation.from.payloadId ?? afterEnter.hoverEvents.at(-1)?.payload?.id
  const futureContractSatisfied = (() => {
    const events = afterTransition.hoverEvents
    if (events.length !== 3) return false

    const [first, second, third] = events
    return (
      first.event === "feature_hovered" &&
      first.payload?.id === activeFromPayloadId &&
      second.event === "feature_unhovered" &&
      second.payload?.id === activeFromPayloadId &&
      third.event === "feature_hovered" &&
      third.payload?.id === resolvedTransition.payloadId
    )
  })()

  const baselineStickyHoverDetected =
    Boolean(afterTransition.hoveredAreaId) &&
    Boolean(afterTransition.featureUnderTargetPoint?.featureStateId) &&
    afterTransition.hoveredAreaId !== afterTransition.featureUnderTargetPoint.featureStateId &&
    afterTransition.hoverEvents.length === 0

  const measuredHoverEventDelta = afterIntraMove.hoverEventCount - afterEnter.hoverEventCount
  const withinFeatureProducedNoExtraTransitions = measuredHoverEventDelta === 0

  const screenshot = await page.screenshot({ fullPage: true })
  await testInfo.attach(`hover-${injectDuplicateMeasuredPhase ? "inject" : "future"}.png`, {
    body: screenshot,
    contentType: "image/png",
  })

  return {
    preparation,
    afterEnter,
    afterIntraMove,
    afterTransition,
    baselineStickyHoverDetected,
    measuredHoverEventDelta,
    withinFeatureProducedNoExtraTransitions,
    futureContractSatisfied,
    consoleMessages,
    pageErrors,
  }
}

test.describe("district hover transitions", () => {
  test.describe.configure({ timeout: 90_000 })

  test("keeps exact-once hover ordering across adjacent Berlin districts", async ({ page }, testInfo) => {
    test.setTimeout(90_000)
    const result = await runHoverScenario(page, testInfo)

    expect(result.withinFeatureProducedNoExtraTransitions).toBe(true)
    expect(result.futureContractSatisfied).toBe(true)
    expect(result.pageErrors).toEqual([])

    // The events also have to survive the PubSub round trip into the LiveView
    // harness (`#district-hover-events` / `#district-hover-event-count`).
    await expect
      .poll(async () => {
        const state = await readHarnessState(page)
        return state.domHoverEvents.map((entry) => entry.event)
      }, { timeout: 5_000 })
      .toEqual(["feature_hovered", "feature_unhovered", "feature_hovered"])
  })

  test("detects duplicate hover broadcasts inside the measured phase", async ({ page }, testInfo) => {
    test.setTimeout(90_000)
    const result = await runHoverScenario(page, testInfo, { injectDuplicateMeasuredPhase: true })

    expect(result.measuredHoverEventDelta).toBe(1)
    expect(result.withinFeatureProducedNoExtraTransitions).toBe(false)
  })
})
