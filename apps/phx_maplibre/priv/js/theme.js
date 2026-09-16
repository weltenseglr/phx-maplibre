import {addLayers, addSources} from "./sources_layers.js"
import {clearPopupTracking} from "./popup.js"
import {updateAnimatedFeatures} from "./animate.js"
import {collapseSpider} from "./spiderfy.js"

/** Pick the style URL for the current theme. An explicit `data-theme` beats the OS preference. */
export function preferredStyle(config) {
  const theme = document.documentElement.dataset.theme
  const dark = theme === "dark" || (theme !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches)
  return dark ? config.darkStyle : config.lightStyle
}

export function captureFeatureStates(hook) {
  return {
    hoveredAreaId: hook.hoveredAreaId,
    selectedAreaId: hook.selectedAreaId,
    hoveredPointId: hook.hoveredPointId,
    selectedPointId: hook.selectedPointId,
    selectedPointIdLinkedId: hook.selectedPointIdLinkedId,
    hoveredClusterId: hook.hoveredClusterId,
  }
}

export function restoreFeatureStates(hook, states) {
  const entries = [
    ["areas", states.hoveredAreaId, {hover: true}],
    ["areas", states.selectedAreaId, {selected: true}],
    ["points", states.hoveredPointId, {hover: true}],
    ["points", states.selectedPointId, {selected: true}],
    ["animated", states.hoveredPointId, {hover: true}],
    ["animated", states.selectedPointId, {selected: true}],
    ["points", states.selectedPointIdLinkedId, {linked: true}],
    ["animated", states.selectedPointIdLinkedId, {linked: true}],
    ["points", states.hoveredClusterId, {hover: true}],
  ]

  for (const [source, id, state] of entries) {
    if (id === null || id === undefined) continue
    try {
      hook.map.setFeatureState({source, id}, state)
    } catch (_) {
      // the feature may not exist in the re-added source
    }
  }
}

/**
 * Put the map back together after a style swap: a new style arrives empty, so
 * re-add the sources and layers, push the last known data into them, and
 * restore whatever was hovered or selected before.
 */
export function onStyleLoad(hook) {
  const states = captureFeatureStates(hook)
  const clusterSpiderfy = typeof hook.config.clusterSpiderfyZoom === "number"
  addSources(hook.map, hook.config.cluster, hook.config.clusterSpiderfyZoom)
  addLayers(hook.map, hook.config.cluster, hook.config.clusterColor, clusterSpiderfy)
  hook.map.getSource("points")?.setData(hook.pointsData)
  hook.pointsDirty = false
  hook.map.getSource("areas")?.setData(hook.areasData)
  // Rebuild the animated source from the same stashed data; targets are
  // current, so nothing tweens on a style swap.
  updateAnimatedFeatures(hook, {tween: false})
  collapseSpider(hook)
  restoreFeatureStates(hook, states)
  hook.styleReloading = false
  hook.el.dataset.mapStyleReady = "true"
}

/**
 * Watch `data-theme` on <html> and swap the map style when the resolved theme
 * actually changes. Debounced by 300ms so a toggle animation or a burst of
 * attribute writes triggers at most one reload.
 */
export function observeTheme(hook) {
  hook.themeObserver = new MutationObserver((changes) => {
    if (!changes.some((change) => change.attributeName === "data-theme")) return

    clearTimeout(hook.themeTimer)
    hook.themeTimer = setTimeout(() => {
      const style = preferredStyle(hook.config)
      if (!hook.ready || style === hook.currentStyle) return

      hook.currentStyle = style
      hook.styleReloading = true
      hook.el.dataset.mapStyleReady = "false"
      hook.el.dataset.mapLifecycle = "style-loading"
      if (hook.popup) {
        hook.popup.remove()
        hook.popup = null
        clearPopupTracking(hook)
      }
      hook.map.setStyle(style, {diff: true})
    }, 300)
  })

  hook.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
}
