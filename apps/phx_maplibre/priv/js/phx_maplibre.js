import {createHook, parseConfig} from "./hook.js"
export {parseConfig}

/**
 * Build the PhxMaplibre LiveView hook around your own MapLibre GL import.
 * Register the result as `PhxMaplibreHook` in the LiveSocket's `hooks`.
 *
 * Options:
 *   popupContent(feature) — optional renderer for the click popup. Return a
 *   DOM Node (shown via `Popup#setDOMContent`) or null/undefined to fall back
 *   to the library's escaped default popup. Build nodes with
 *   `createElement`/`textContent` and they are XSS-safe by construction;
 *   feature data itself can never inject markup.
 *
 *   now/raf/caf — timing seams (performance.now / requestAnimationFrame /
 *   cancelAnimationFrame by default), used by the animation loop.
 *   Override them in tests; production code never needs to.
 */
export function createMapHook(maplibregl, options = {}) {
  return createHook(maplibregl, options)
}
