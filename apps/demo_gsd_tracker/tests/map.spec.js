// @ts-check
const { test, expect } = require('@playwright/test');

// The map id is generated per LiveView session (see GsdTrackerWeb.MapLive), so
// everything here matches on the prefix instead of a fixed id.
const MAP_ID_PREFIX = 'map-tracker-';
const MAP = `[id^="${MAP_ID_PREFIX}"]`;
const CANVAS = `${MAP} canvas`;

/**
 * Expose `window.__findMapHook()` on the page, which walks `window.liveSocket`
 * (the same BFS pattern used in apps/demo_berlin_districts/tests) to find the
 * phx_maplibre hook instance whose id starts with `MAP_ID_PREFIX`. Must be
 * installed before `page.goto` so it exists by the time the hook mounts.
 */
function installMapHookFinder(page) {
  return page.addInitScript((mapIdPrefix) => {
    window.__findMapHook = () => {
      const queue = [{ value: window.liveSocket, depth: 0 }];
      const visited = new Set();

      while (queue.length > 0) {
        const current = queue.shift();
        if (!current) continue;

        const { value, depth } = current;
        if (!value || typeof value !== 'object' || visited.has(value)) continue;
        if (value instanceof Node || value === window) continue;

        visited.add(value);

        // The library hook sets `this.mapId = this.el.id` in `mounted()`.
        if (typeof value.mapId === 'string' && value.mapId.startsWith(mapIdPrefix) && value.map) {
          return value;
        }
        if (depth >= 6) continue;

        for (const key of Object.keys(value)) {
          if (key === 'ownerDocument' || key === 'window') continue;

          let child;
          try {
            child = value[key];
          } catch {
            continue;
          }

          if (child && typeof child === 'object') queue.push({ value: child, depth: depth + 1 });
        }
      }

      return null;
    };
  }, MAP_ID_PREFIX);
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

    // Simulation ticks every 5s; wait for at least one broadcast.
    await page.waitForTimeout(7000);

    await expect(page.locator(CANVAS).first()).toBeVisible();
    await expect(page.locator('#stats-sidebar')).toBeVisible();
  });

  test('gsd detail panel appears when a pin is clicked', async ({ page }) => {
    await installMapHookFinder(page);
    await page.goto('/');

    const canvas = page.locator(CANVAS).first();
    await expect(canvas).toBeVisible({ timeout: 10000 });

    await page.waitForFunction(
      () => {
        const hook = window.__findMapHook && window.__findMapHook();
        return Boolean(hook?.map && hook.pointsData?.features?.length);
      },
      { timeout: 15000 }
    );

    // At the map's default zoom (11), every GSD lands in a single cluster
    // (clusterMaxZoom is 14 — see apps/phx_maplibre/priv/js/sources_layers.js),
    // so `unclustered-points` never has a feature there regardless of how long
    // we wait. Wait for the server to have pushed real GSD position data onto
    // the hook, then jump the view to zoom past clusterMaxZoom centered on an
    // actual GSD position (not the map's default center, which only
    // approximately overlaps where the simulation places them) — deterministic
    // setup, not a timing workaround.
    const gsdCoordinates = await page.evaluate(async () => {
      const hook = window.__findMapHook();
      for (let attempt = 0; attempt < 40; attempt += 1) {
        const feature = hook.pointsData?.features?.[0];
        if (feature) return feature.geometry.coordinates;
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      return null;
    });

    if (!gsdCoordinates) throw new Error('no GSD position data was ever pushed to the map hook');

    await page.evaluate((coordinates) => {
      const hook = window.__findMapHook();
      hook.map.jumpTo({ center: coordinates, zoom: 15 });
    }, gsdCoordinates);

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
          page.evaluate((candidates) => {
            const hook = window.__findMapHook();
            if (!hook?.map) return 0;
            const layers = candidates.filter((id) => hook.map.getLayer(id));
            if (!layers.length) return 0;
            return hook.map.queryRenderedFeatures({ layers }).length;
          }, PIN_LAYERS),
        {
          timeout: 20000,
          message: 'no GSD pin ever rendered on a pin layer',
        }
      )
      .toBeGreaterThan(0);

    // Project the first rendered feature's coordinates to an exact pixel
    // position (relative to the map container, which is what map.project
    // uses and what the canvas fills) and click there.
    const point = await page.evaluate((candidates) => {
      const hook = window.__findMapHook();
      const layers = candidates.filter((id) => hook.map.getLayer(id));
      const feature = hook.map.queryRenderedFeatures({ layers })[0];
      const projected = hook.map.project(feature.geometry.coordinates);
      const rect = hook.map.getContainer().getBoundingClientRect();
      return { pageX: rect.left + projected.x, pageY: rect.top + projected.y };
    }, PIN_LAYERS);

    await page.mouse.click(point.pageX, point.pageY);

    const detail = page.locator('#gsd-detail');
    await expect(detail).toBeVisible({ timeout: 5000 });
    await expect(page.locator('text=Total distance:')).toBeVisible();
    await expect(page.locator('text=Service time:')).toBeVisible();
    await expect(detail.locator('text=Speed')).toBeVisible();
    await expect(detail.locator('text=Heading')).toBeVisible();
  });
});
