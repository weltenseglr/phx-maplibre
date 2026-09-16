// @ts-check
const { test, expect } = require('@playwright/test');

// The map id is generated per LiveView session (see GsdTrackerWeb.MapLive), so
// everything here matches on the prefix instead of a fixed id.
const MAP_ID_PREFIX = 'map-tracker-';
const MAP = `[id^="${MAP_ID_PREFIX}"]`;
const CANVAS = `${MAP} canvas`;

// Include lifecycle/error diagnostics in readiness failures rather than waiting
// blindly for a boolean. Initialization errors fail immediately.
async function waitForMapState(page, attribute, timeout = 15000) {
  await expect.poll(async () => {
    const state = await page.locator(MAP).evaluate((element, attribute) => ({
      ready: element.getAttribute(attribute),
      lifecycle: element.dataset.mapLifecycle,
      mountCount: element.dataset.mapMountCount,
      error: element.dataset.mapError,
    }), attribute);
    if (state.lifecycle === 'error') {
      throw new Error(`Map initialization failed: ${JSON.stringify(state)}`);
    }
    return state.ready === 'true' ? 'ready' : JSON.stringify(state);
  }, {timeout, message: `Waiting for ${attribute}`}).toBe('ready');
}

test.describe('GSD Tracker Map', () => {
  test('map canvas is visible', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator(MAP)).toBeVisible({ timeout: 10000 });
    await expect(page.locator(CANVAS).first()).toBeVisible({ timeout: 10000 });
  });

  test('stats sidebar is visible', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#stats-sidebar')).toBeVisible({ timeout: 5000 });
    await expect(page.locator('text=Total Pigeons')).toBeVisible({ timeout: 5000 });
  });

  test('map survives a simulation tick', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator(CANVAS).first()).toBeVisible({ timeout: 10000 });

    await expect(page.locator("#gsd-connection-status")).toHaveAttribute("data-connection", "live");
    await waitForMapState(page, "data-map-hook-ready");
    const tracker = page.locator("#gsd-tracker");
    const revision = await tracker.getAttribute("data-simulation-revision");
    await expect(tracker).not.toHaveAttribute("data-simulation-revision", revision, { timeout: 15000 });

    await expect(page.locator(CANVAS).first()).toBeVisible();
    await expect(page.locator('#stats-sidebar')).toBeVisible();
  });

  test('gsd detail panel appears when a pin is clicked', async ({ page }) => {
    // A fresh server asynchronously bootstraps the demo fleet.
    test.setTimeout(90000);
    await page.goto('/');

    const canvas = page.locator(CANVAS).first();
    await expect(canvas).toBeVisible({ timeout: 10000 });

    await expect(page.locator('#gsd-connection-status')).toHaveAttribute("data-connection", "live", {
      timeout: 15000,
    });

    await waitForMapState(page, 'data-map-hook-ready');
    await waitForMapState(page, 'data-map-style-ready');
    await waitForMapState(page, 'data-map-points-present', 60000);

    // Zoom past clustering, centered on a real position supplied by the server.
    const gsdCoordinates = await page.evaluate((selector) =>
      window.phxMaplibre.getMapHandle(document.querySelector(selector)).pointsData.features[0].geometry.coordinates,
      MAP);

    await page.evaluate(({selector, coordinates}) => {
      const hook = window.phxMaplibre.getMapHandle(document.querySelector(selector));
      hook.map.jumpTo({ center: coordinates, zoom: 15 });
    }, {selector: MAP, coordinates: gsdCoordinates});

    // The simulation broadcasts positions every 5s; poll (rather than a fixed
    // sleep) until at least one GSD pin has actually rendered. Past the
    // library's animate_min_zoom the pins live on `animated-points` instead of
    // `unclustered-points` (both fire the same feature_selected event), so
    // query whichever pin layer exists. If none ever renders, this must fail
    // the test — not silently skip it.
    const PIN_LAYERS = ['unclustered-points', 'animated-points'];

    await expect
      .poll(
        () =>
          page.evaluate(({selector, candidates}) => {
            const hook = window.phxMaplibre.getMapHandle(document.querySelector(selector));
            if (!hook?.map) return 0;
            const layers = candidates.filter((id) => hook.map.getLayer(id));
            if (!layers.length) return 0;
            return hook.map.queryRenderedFeatures({ layers }).length;
          }, {selector: MAP, candidates: PIN_LAYERS}),
        {
          timeout: 20000,
          message: 'no GSD pin ever rendered on a pin layer',
        }
      )
      .toBeGreaterThan(0);

    // Project the first rendered feature's coordinates to an exact pixel
    // position (relative to the map container, which is what map.project
    // uses and what the canvas fills) and click there.
    const point = await page.evaluate(({selector, candidates}) => {
      const hook = window.phxMaplibre.getMapHandle(document.querySelector(selector));
      const layers = candidates.filter((id) => hook.map.getLayer(id));
      const feature = hook.map.queryRenderedFeatures({ layers })[0];
      const projected = hook.map.project(feature.geometry.coordinates);
      const rect = hook.map.getContainer().getBoundingClientRect();
      return { pageX: rect.left + projected.x, pageY: rect.top + projected.y };
    }, {selector: MAP, candidates: PIN_LAYERS});

    await page.mouse.click(point.pageX, point.pageY);

    const detail = page.locator('#gsd-detail');
    await expect(detail).toBeVisible({ timeout: 5000 });
    await expect(page.locator('text=Total distance:')).toBeVisible();
    await expect(page.locator('text=Service time:')).toBeVisible();
    await expect(detail.locator('text=Speed')).toBeVisible();
    await expect(detail.locator('text=Heading')).toBeVisible();
  });
});
