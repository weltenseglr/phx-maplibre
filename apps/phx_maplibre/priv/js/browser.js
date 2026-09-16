/** @typedef {{map: object, readonly pointsData: object}} MapHandle */
const handles = new WeakMap()

/**
 * Return the public map handle for a container, or null before successful mount
 * and after destruction. Reacquire after remount; do not retain old handles.
 * The handle is frozen. Its pointsData getter returns the current point
 * collection, which callers must treat as read-only. This is not a readiness
 * predicate: wait for the container's style flag before querying map layers.
 * @param {HTMLElement | null} element
 * @returns {MapHandle | null}
 */
export function getMapHandle(element) {
  return element ? handles.get(element) || null : null
}

// Lifecycle registration is private to the hook, not exported by the package.
export function registerMapHandle(hook) {
  handles.set(hook.el, Object.freeze({
    map: hook.map,
    get pointsData() { return hook.pointsData },
  }))
}

export function unregisterMapHandle(element) {
  handles.delete(element)
}
