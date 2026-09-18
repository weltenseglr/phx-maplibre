import {MaplibreTerradrawControl, MaplibreMeasureControl} from "@watergis/maplibre-gl-terradraw"
import {TerraDrawModeUndoRedo} from "terra-draw"
import {getMapHandle} from "./browser.js"
import {createUpdateGate} from "./update_gate.js"
import {createCursorMotion} from "./editor/cursor_motion.mjs"
import {clone, coordinateState, geometryOperations, editingFeature, acceptSnapshot, projectFeature, isHelperFeature, mutableProperties, previewFeature, boundedPreview, takeGestureBatch, sanitizeFinishedFeature} from "./editor/operations.mjs"

export {createUpdateGate} from "./update_gate.js"

const handles = new WeakMap()
export const getEditorHandle = element => handles.get(element) || null

// Separate entry point: the ordinary map hook never imports drawing packages.
export function createEditorHook(maplibregl) {
  return {
    mounted() {
      this.config = JSON.parse(this.el.dataset.editorConfig || "{}")
      this.container = document.getElementById(this.el.dataset.mapId)
      this.states = new Map(); this.pending = new Map(); this.inflight = new Map(); this.sequences = new Map()
      this.creating = new Set(); this.gestures = new Map(); this.finishing = new Set(); this.completedGestures = new Map(); this.collaborators = new Map(); this.markers = new Map()
      this.snapshot = null; this.online = false; this.applying = false; this.disposed = false; this.epoch = 0; this.commands = 0; this.permitted = new Set()
      this.prefix = `phx-editor-${this.el.id}`; this.role = name => this.el.querySelector(`[data-role="${name}"]`)
      this.error = message => { const node = this.role("error"); if (node) node.textContent = message || "" }
      this.gate = createUpdateGate({send: () => { this.flush(true); this.sendPresence() }})
      this.interpolation = true
      try { this.interpolation = localStorage.getItem(`${this.prefix}:interpolation`) !== "off" } catch (_) {}
      this.motion = createCursorMotion({interpolationEnabled: this.interpolation, reducedMotion: matchMedia("(prefers-reduced-motion: reduce)").matches,
        render: (id, coordinate) => this.markers.get(id)?.setLngLat(new maplibregl.MercatorCoordinate(...coordinate).toLngLat().wrap())})
      this.listeners = []
      this.motionPreference = matchMedia("(prefers-reduced-motion: reduce)")
      this.motionChanged = event => this.motion.setReducedMotion(event.matches)
      this.motionPreference.addEventListener("change", this.motionChanged)

      this.listen = (node, event, fn) => { if (node) { node.addEventListener(event, fn); this.listeners.push(() => node.removeEventListener(event, fn)) } }
      this.listen(this.role("interval"), "input", event => { if (this.role("interval-value")) this.role("interval-value").textContent = `${event.target.value} ms` })
      this.listen(this.role("interval"), "change", event => this.request("settings", {update_interval_ms: Number(event.target.value)}))
      const interpolation = this.role("interpolation")
      if (interpolation) interpolation.checked = this.interpolation
      this.listen(interpolation, "change", event => { this.interpolation = event.target.checked; this.motion.setInterpolationEnabled(this.interpolation); try { localStorage.setItem(`${this.prefix}:interpolation`, this.interpolation ? "on" : "off") } catch (_) {} })
      this.listen(this.role("apply-properties"), "click", () => {
        const properties = {}
        if (this.role("selected-name")) properties.name = this.role("selected-name").value
        if (this.role("selected-color")) properties.color = this.role("selected-color").value
        if (this.selected) this.mutate({action: "properties", id: this.selected, properties})
      })
      this.listen(this.el, "click", event => { const button = event.target.closest("[data-feature-id]"); if (button) this.select(button.dataset.featureId) })
      this.handleEvent(`maplibre:editor:${this.el.id}:snapshot`, state => this.receive(state))
      this.handleEvent(`maplibre:editor:${this.el.id}:presence`, update => this.receivePresence(update))
      this.listen(this.container, "phx-maplibre:style-changing", () => this.pauseStyle())
      this.observer = new MutationObserver(() => this.setup())
      this.observer.observe(this.container, {attributes: true, attributeFilter: ["data-map-style-ready", "data-map-hook-ready"]})
      const hook = this
      handles.set(this.el, Object.freeze({get map() { return hook.map }, get draw() { return hook.draw }, get state() { return clone(hook.snapshot) }, get online() { return hook.online }, select: id => hook.select(id), setMode: mode => { hook.mode = mode; hook.draw?.setMode(mode) }, mutate: payload => new Promise(resolve => hook.mutate(payload, resolve)), undo: () => hook.historyAction("undo"), redo: () => hook.historyAction("redo")}))
      this.setup(); this.synchronize()
    },
    request(event, payload = {}, callback) {
      if (this.disposed || (!this.online && event !== "sync")) { callback?.({error: "The shared editor is disconnected."}); return }
      const epoch = this.epoch
      const command = ["mutate", "undo", "redo"].includes(event)
      if (command) { this.commands++; this.history?.notify() }
      this.pushEvent("maplibre:editor", {id: this.el.id, event, payload}, reply => {
        if (this.disposed || epoch !== this.epoch) return
        if (command) this.commands = Math.max(0, this.commands - 1)
        if (reply.error || command || event === "settings") this.error(reply.error)
        if (reply.snapshot) this.receive(reply.snapshot, event === "sync")
        else if (Number.isInteger(reply.revision)) this.receive(reply, event === "sync")
        callback?.(reply)
        this.history?.notify()
      })
    },
    synchronize() {
      this.epoch++; this.online = false; this.pending.clear(); this.inflight.clear(); this.states.clear(); this.gestures.clear(); this.finishing.clear(); this.creating.clear(); this.draft = null; this.permitted.clear(); this.commands = 0; this.sequences.clear(); this.collaborators.clear(); this.motion.clear(); for (const marker of this.markers.values()) marker.remove(); this.markers.clear()
      this.request("sync", {}, reply => {
        if (reply.error) return
        this.actorId = reply.actor_id; this.identityColor = reply.color || "#f97316"; this.online = true; this.draw?.setMode(this.mode || this.idleMode())
        for (const entry of (reply.presence?.entries || this.snapshot?.presence?.entries || [])) this.receivePresence({actor_id: entry.actor_id || entry.id, entry})
        this.reconcile(); this.renderUI()
      })
    },
    setup() {
      if (this.container.dataset.mapStyleReady !== "true") return
      if (this.control) {
        if (this.stylePaused) {
          this.stylePaused = false
          this.renderShared(); this.renderPresence()
          this.el.dataset.editorReady = "true"
          this.el.dispatchEvent(new CustomEvent("phx-maplibre:editor-ready", {bubbles: true, detail: getEditorHandle(this.el)}))
        }
        return
      }
      const handle = getMapHandle(this.container); if (!handle) return
      this.map = handle.map
      const hook = this
      this.history = {
        register({onHistoryChange}) { this.onChange = onHistoryChange },
        unregister() {}, clearHistory() {},
        undo() { if (!this.canUndo()) return false; hook.historyAction("undo"); return true }, redo() { if (!this.canRedo()) return false; hook.historyAction("redo"); return true },
        canUndo() { return hook.online && !hook.busy() && (hook.snapshot?.history?.undo_size || 0) > 0 },
        canRedo() { return hook.online && !hook.busy() && (hook.snapshot?.history?.redo_size || 0) > 0 },
        undoSize() { return hook.online && !hook.busy() ? hook.snapshot?.history?.undo_size || 0 : 0 }, redoSize() { return hook.online && !hook.busy() ? hook.snapshot?.history?.redo_size || 0 : 0 },
        notify() { this.onChange?.({cause:"push", stack:"session", undoStackSize:this.undoSize(), redoStackSize:this.redoSize()}) },
      }
      const Control = this.config.control === "measure" ? MaplibreMeasureControl : MaplibreTerradrawControl
      const options = this.config.control_options || {}
      this.control = new Control({...options, modes: this.config.modes || options.modes, adapterOptions: {...options.adapterOptions, prefixId: this.prefix}, undoRedo: {modeLevel: new TerraDrawModeUndoRedo({maxStackSize: 100}), sessionLevel: this.history}})
      this.map.addControl(this.control, this.config.position || "top-left")
      this.draw = this.control.getTerraDrawInstance()
      if (!this.draw.enabled) this.draw.start()
      if (this.draft?.feature && !this.draw.getSnapshot().some(feature => String(feature.id) === this.draft.id)) {
        this.applying = true
        try { this.draw.addFeatures([editingFeature(this.draft.feature, {mode: this.draft.mode})]) } finally { this.applying = false }
      }
      for (const mode of this.config.modes || []) if (!["select","delete","delete-selection","undo","redo","download","render"].includes(mode)) {
        this.draw.updateModeOptions(mode, {styles:{fillOpacity:f => this.gestures.has(f.id) ? 0 : .25, outlineOpacity:f => this.gestures.has(f.id) ? 0 : 1, lineStringOpacity:f => this.gestures.has(f.id) ? 0 : 1, fillColor:f => f.properties.color || this.identityColor || "#3b82f6", outlineColor:f => f.properties.color || this.identityColor || "#3b82f6", lineStringColor:f => f.properties.color || this.identityColor || "#3b82f6"}})
      }
      if ((this.config.modes || []).includes("select")) this.draw.updateModeOptions("select", {dragEventThrottle:0, styles:{selectedPolygonFillOpacity:f => this.gestures.has(f.id) ? 0 : .25, selectedPolygonOutlineOpacity:f => this.gestures.has(f.id) ? 0 : 1, selectedLineStringOpacity:f => this.gestures.has(f.id) ? 0 : 1}})
      this.draw.setMode(this.online ? this.mode || this.idleMode() : "static")
      this.draw.on("change", (ids, type, context) => this.changed(ids, type, context))
      this.draw.on("finish", id => this.finished(id))
      this.draw.on("select", id => { if (this.applying) return; this.selected = id; this.renderUI(); this.gate.request({immediate: true}) })
      this.draw.on("deselect", () => { if (this.applying) return; this.selected = null; this.renderUI(); this.gate.request({immediate: true}) })
      this.pointer = event => { if (!this.online) return; const bounds = this.map.getCanvas().getBoundingClientRect(); const position = this.map.unproject([event.clientX - bounds.x, event.clientY - bounds.y]).wrap(); this.cursor = {lng: position.lng, lat: position.lat}; this.gate.sample([event.clientX, event.clientY]) }
      this.interact = () => this.gate.request({immediate: true})
      this.leave = () => { this.cursor = null; this.gate.request({immediate: true}) }
      this.canvas = this.map.getCanvas(); this.canvas.addEventListener("pointermove", this.pointer); this.canvas.addEventListener("pointerup", this.interact); this.canvas.addEventListener("click", this.interact); this.canvas.addEventListener("contextmenu", this.interact); this.canvas.addEventListener("pointerleave", this.leave)
      this.reconcile(); this.renderPresence(); this.el.dataset.editorReady = "true"
      this.el.dispatchEvent(new CustomEvent("phx-maplibre:editor-ready", {bubbles: true, detail: getEditorHandle(this.el)}))
    },
    idleMode() { return this.config.modes && !this.config.modes.includes("render") ? "default" : "render" },
    changed(ids, type, context) {
      if (this.applying || !this.online || context?.origin === "api") return
      const features = this.draw.getSnapshot()
      let immediate = type === "delete"
      for (const id of ids) {
        const feature = features.find(f => f.id === id), authoritative = this.snapshot?.features.find(f => f.id === id)
        if (type === "delete" && authoritative) { this.mutate({action: "delete", id}); continue }
        if (!feature) { if (String(id) === this.draft?.id) this.draft = null; continue }
        if (isHelperFeature(feature)) continue
        if (!authoritative) { this.draft = {id: String(id), feature: clone(feature), mode: feature.properties.mode, sequence: (this.draft?.sequence || 0) + 1}; continue }
        if (context?.target === "properties") { this.queueModeProperties(id, feature); continue }
        const previous = this.states.get(id) || coordinateState(editingFeature(authoritative, this.snapshot.metadata[id]), this.snapshot.metadata[id])
        const {state, operations} = geometryOperations(previous, feature, this.snapshot.metadata[id])
        if (!operations.length) continue
        immediate ||= operations.some(operation => ["insert", "remove"].includes(operation.type))
        this.states.set(id, state)
        const gesture = this.activeGesture(id)
        this.pending.set(id, [...(this.pending.get(id) || []), ...operations.map(operation => ({...operation, __gesture_id: gesture}))])
      }
      this.renderShared(); this.history?.notify(); this.gate.request({immediate})
    },
    finished(id) {
      if (!this.online || this.applying) return
      const feature = this.draw.getSnapshot().find(f => f.id === id); if (!feature) return
      if (!this.snapshot?.features.some(f => f.id === id)) {
        if (this.creating.has(id)) return
        this.creating.add(id)
        const mode = feature.properties.mode, completed = sanitizeFinishedFeature(feature, mode), ordinary = clone(completed)
        const terraProperties = clone(feature.properties); delete ordinary.properties.mode; delete ordinary.properties.currentlyDrawing; delete ordinary.properties.selected
        ordinary.properties = Object.fromEntries((this.config.fields || ["name","color"]).filter(key => feature.properties[key] !== undefined).map(key => [key,feature.properties[key]]))
        if ((this.config.fields || ["name", "color"]).includes("color") && !ordinary.properties.color) ordinary.properties.color = this.identityColor || "#3b82f6"
        const state = coordinateState(completed)
        this.mutate({action: "create", feature: ordinary, mode, mode_properties: terraProperties, vertex_ids: state?.ids || []}, () => { this.creating.delete(id); this.draft = null; this.reconcile(); this.sendPresence() })
      } else {
        this.queueModeProperties(id, feature)
        const gesture = this.gestures.get(id)
        if (gesture) { const completed = this.completedGestures.get(id) || new Set(); completed.add(gesture); this.completedGestures.set(id, completed) }
        this.finishing.add(id); this.flush(true); this.settle(id)
      }
    },
    activeGesture(id) {
      let gesture = this.gestures.get(id)
      if (!gesture || this.completedGestures.get(id)?.has(gesture)) { gesture = crypto.randomUUID(); this.gestures.set(id, gesture) }
      return gesture
    },
    queueModeProperties(id, feature) {
      const metadata = this.snapshot?.metadata?.[id]
      if (metadata?.mode !== "text" || typeof feature.properties.text !== "string" || feature.properties.text === metadata.properties?.text) return
      const operations = (this.pending.get(id) || []).filter(operation => operation.type !== "mode_properties")
      operations.push({type: "mode_properties", properties: {text: feature.properties.text}, expected_version: metadata.version, __gesture_id: this.activeGesture(id)})
      this.pending.set(id, operations)
    },
    mutate(payload, callback) { this.request("mutate", payload, callback) },
    flush(permit = false) {
      if (!this.online) return
      for (const [id, operations] of this.pending) {
        if (permit) this.permitted.add(id)
        if (!operations.length || this.inflight.has(id) || !this.permitted.has(id)) continue
        const batch = takeGestureBatch(operations)
        this.permitted.delete(id)
        if (batch.remaining.length) this.pending.set(id, batch.remaining); else this.pending.delete(id)
        this.inflight.set(id, {operations: batch.operations, gesture_id: batch.gesture_id, sequence:Math.max(this.sequences.get(id) || 0, this.snapshot?.metadata[id]?.acknowledgements?.[this.actorId] || 0) + 1})
        const sequence = Math.max(this.sequences.get(id) || 0, this.snapshot?.metadata[id]?.acknowledgements?.[this.actorId] || 0) + 1; this.sequences.set(id, sequence)
        this.mutate({action: "edit", id, sequence, gesture_id: batch.gesture_id, operations: batch.operations, finish: this.completedGestures.get(id)?.has(batch.gesture_id) || false}, reply => {
          this.inflight.delete(id)
          if (reply.error) {
            // Known rejection discards this batch; preserve only later operations
            // whose stable coordinate dependencies still exist.
            const ids = this.snapshot?.metadata[id]?.vertex_ids || []
            const anchors = this.snapshot?.metadata[id]?.nodes || {}
            this.pending.set(id, (this.pending.get(id) || []).filter(op => op.type === "translate" || op.type === "move" && ids.includes(op.vertex_id) || op.type === "remove" && ids.includes(op.vertex_id) || op.type === "insert" && (op.after_id == null || Object.hasOwn(anchors, op.after_id))))
          }
          this.settle(id)
          if (this.pending.get(id)?.length) this.flush(this.finishing.has(id)); else { this.pending.delete(id); this.reconcile() }
          this.history?.notify()
        })
      }
    },
    settle(id) {
      const completed = this.completedGestures.get(id)
      for (const gesture_id of completed || []) {
        if (this.inflight.get(id)?.gesture_id === gesture_id || this.pending.get(id)?.some(operation => operation.__gesture_id === gesture_id)) continue
        completed.delete(gesture_id)
        if (this.gestures.get(id) === gesture_id) this.gestures.delete(id)
        this.mutate({action: "finish", id, gesture_id})
      }
      if (!completed?.size) { this.finishing.delete(id); this.completedGestures.delete(id) }
    },
    busy() { return this.commands > 0 || this.gestures.size > 0 || this.inflight.size > 0 || [...this.pending.values()].some(ops => ops.length) },
    historyAction(event) { if (!this.online) return; if (this.busy()) { this.error("Finish the current edit before using undo or redo."); return }; this.request(event) },
    receive(snapshot, syncing = false) {
      const decision = acceptSnapshot(this.snapshot, snapshot, syncing)
      if (decision === "ignore") return
      if (decision === "sync") { this.synchronize(); return }
      if (this.snapshot && snapshot.generation !== this.snapshot.generation) {
        this.epoch++; this.pending.clear(); this.inflight.clear(); this.states.clear(); this.sequences.clear(); this.gestures.clear()
        this.finishing.clear(); this.creating.clear(); this.permitted.clear(); this.commands = 0; this.draft = null; this.selected = null
        this.collaborators.clear(); this.motion.clear(); for (const marker of this.markers.values()) marker.remove(); this.markers.clear(); this.gate.reset()
        snapshot.history = {undo_size: 0, redo_size: 0}
        for (const entry of snapshot.presence?.entries || []) this.receivePresence({actor_id: entry.actor_id || entry.id, entry})
      }
      snapshot.history ||= snapshot.generation === this.snapshot?.generation ? this.snapshot.history : {undo_size:0,redo_size:0}
      this.snapshot = snapshot
      const interval = snapshot.settings?.update_interval_ms || 500; this.gate.setHeartbeatMs(interval); this.motion.setIntervalMs(interval)
      this.reconcile(); this.renderShared(); this.renderPresence(); this.renderUI(); this.history?.notify()
    },
    reconcile() {
      if (!this.draw || !this.snapshot || this.stylePaused) return
      this.applying = true
      try {
        const current = this.draw.getSnapshot()
        const ids = new Set(this.snapshot.features.map(f => f.id))
        for (const feature of current) if (!isHelperFeature(feature) && !ids.has(feature.id) && String(feature.id) !== this.draft?.id && !this.creating.has(feature.id)) {
          this.draw.removeFeatures([feature.id]); this.pending.delete(feature.id); this.inflight.delete(feature.id); this.gestures.delete(feature.id); this.finishing.delete(feature.id); this.states.delete(feature.id)
          if (this.selected === feature.id) this.selected = null
        }
        for (const feature of this.snapshot.features) {
          if (this.inflight.has(feature.id) || this.pending.get(feature.id)?.length || this.gestures.has(feature.id)) continue
          const metadata = this.snapshot.metadata?.[feature.id] || {}, editable = editingFeature(feature, metadata)
          const existing = current.find(f => f.id === feature.id)
          if (!existing) { const results = this.draw.addFeatures([editable]); if (!results[0]?.valid) { this.error(results[0]?.reason || "Feature could not be restored"); continue } }
          else { this.draw.updateFeatureGeometry(feature.id, editable.geometry); this.draw.updateFeatureProperties(feature.id, mutableProperties(editable.properties)) }
          this.states.set(feature.id, coordinateState(editable, metadata))
        }
      } catch (error) { this.error(error.message) } finally { this.applying = false }
    },
    renderShared() {
      if (!this.map || !this.draw || !this.snapshot || this.stylePaused) return
      const features = []
      for (const feature of this.snapshot.features) if (this.gestures.has(feature.id)) {
        const flight = this.inflight.get(feature.id), metadata = this.snapshot.metadata[feature.id]
        const unacknowledged = flight && (metadata.acknowledgements?.[this.actorId] || 0) < flight.sequence
        const ops = [...(unacknowledged ? flight.operations : []), ...(this.pending.get(feature.id) || [])]
        features.push({...projectFeature(feature,metadata,ops).feature,properties:{...feature.properties,color:feature.properties.color || this.identityColor || "#3b82f6"}})
      }
      const source = `${this.prefix}-editing`
      if (!this.map.getSource(source)) {
        this.map.addSource(source,{type:"geojson",data:{type:"FeatureCollection",features:[]}})
        this.map.addLayer({id:`${source}-fill`,source,type:"fill",filter:["==",["geometry-type"],"Polygon"],paint:{"fill-color":["get","color"],"fill-opacity":.25}})
        this.map.addLayer({id:`${source}-line`,source,type:"line",filter:["!=",["geometry-type"],"Point"],paint:{"line-color":["get","color"],"line-width":2}})
      }
      this.map.getSource(source).setData({type:"FeatureCollection",features})
    },
    select(id) { if (this.online && this.draw) { this.mode = "select"; this.draw.setMode("select"); this.draw.selectFeature(id) } },
    sendPresence() {
      if (!this.online) return
      // Detect cancelled local drafts even when the engine emits no finish event.
      if (this.draft && !this.draw?.getSnapshot().some(f => String(f.id) === this.draft.id)) this.draft = null
      const draft = this.draft ? {...this.draft, feature: boundedPreview(this.draft.feature)} : null
      this.request("presence", {cursor: this.cursor || null, selected: this.selected || null, editing: [...this.gestures.keys()], draft})
    },
    receivePresence({actor_id, entry}) {
      if (!actor_id || actor_id === this.actorId) return
      if (entry) this.collaborators.set(actor_id, entry)
      else { this.collaborators.delete(actor_id); this.markers.get(actor_id)?.remove(); this.markers.delete(actor_id); this.motion.remove(actor_id) }
      this.renderPresence(); this.renderUI()
    },
    renderPresence() {
      if (!this.map || !this.draw || this.stylePaused) return
      const features = []
      for (const [id, entry] of this.collaborators) {
        if (entry.cursor) {
          let marker = this.markers.get(id)
          if (!marker) { const element = document.createElement("span"); element.textContent = "●"; element.style.color = entry.color || "#64748b"; element.title = entry.name || id; element.className = "phx-maplibre-cursor"; element.dataset.actorId = id; marker = new maplibregl.Marker({element}).setLngLat([entry.cursor.lng, entry.cursor.lat]).addTo(this.map); this.markers.set(id, marker) }
          const position = maplibregl.MercatorCoordinate.fromLngLat(entry.cursor); this.motion.update(id, [position.x, position.y])
        } else { this.markers.get(id)?.remove(); this.markers.delete(id); this.motion.remove(id) }
        if (entry.draft?.feature?.geometry && !this.snapshot?.features.some(feature => String(feature.id) === entry.draft.id)) features.push({...previewFeature(entry.draft.feature), properties: {...entry.draft.feature.properties, color: entry.color || "#64748b"}})
      }
      const source = `${this.prefix}-drafts`
      if (!this.map.getSource(source)) {
        this.map.addSource(source, {type: "geojson", data: {type: "FeatureCollection", features: []}})
        this.map.addLayer({id: `${source}-fill`, source, type: "fill", filter: ["==", ["geometry-type"], "Polygon"], paint: {"fill-color": ["get", "color"], "fill-opacity": 0.15}})
        this.map.addLayer({id: `${source}-line`, source, type: "line", filter: ["!=", ["geometry-type"], "Point"], paint: {"line-color": ["get", "color"], "line-width": 2}})
        this.map.addLayer({id: `${source}-point`, source, type: "circle", filter: ["==", ["geometry-type"], "Point"], paint: {"circle-color": ["get", "color"], "circle-radius": 5}})
      }
      this.map.getSource(source).setData({type: "FeatureCollection", features})
    },
    renderUI() {
      if (this.role("status")) this.role("status").textContent = this.online ? "Shared editor connected" : "Connecting shared editor…"
      const interval = this.snapshot?.settings?.update_interval_ms || 500
      if (this.role("interval") && document.activeElement !== this.role("interval")) this.role("interval").value = interval
      if (this.role("interval-value")) this.role("interval-value").textContent = `${interval} ms`
      if (this.role("presence")) this.role("presence").textContent = `${this.collaborators.size + (this.online ? 1 : 0)} collaborators`
      if (this.role("interval")) this.role("interval").disabled = !this.online
      const feature = this.snapshot?.features.find(f => f.id === this.selected)
      for (const key of ["name", "color"]) { const node = this.role(`selected-${key}`); if (node) { node.disabled = !feature || !this.online; if (document.activeElement !== node) node.value = feature?.properties?.[key] || (key === "color" ? this.identityColor || "#f97316" : "") } }
      if (this.role("apply-properties")) this.role("apply-properties").disabled = !feature || !this.online
      if (this.role("details")) this.role("details").textContent = feature ? JSON.stringify(feature.geometry.coordinates) : ""
      const list = this.role("list")
      if (list) { list.replaceChildren(); for (const feature of this.snapshot?.features || []) { const button = document.createElement("button"); button.type = "button"; button.dataset.featureId = feature.id; button.textContent = feature.properties?.name || `${this.snapshot.metadata?.[feature.id]?.mode || feature.geometry.type} ${String(feature.id).slice(0, 8)}`; list.append(button) } }
    },
    pauseStyle() {
      // The WaterGIS control restores itself through MapLibre's style lifecycle.
      // Keep it active: pausing resets upstream per-mode gesture state.
      this.stylePaused = true; this.el.dataset.editorReady = "false"
    },
    teardownControl() {
      this.mode = this.draw?.getMode() || this.mode; this.gate?.flush(); this.gate?.reset()
      if (this.canvas) { this.canvas.removeEventListener("pointermove", this.pointer); this.canvas.removeEventListener("pointerup", this.interact); this.canvas.removeEventListener("click", this.interact); this.canvas.removeEventListener("contextmenu", this.interact); this.canvas.removeEventListener("pointerleave", this.leave) }
      if (this.control) { this.applying = true; try { this.map.removeControl(this.control) } finally { this.applying = false } }
      this.draw = null; this.control = null
      const source = `${this.prefix}-drafts`
      for (const suffix of ["fill", "line", "point"]) if (this.map?.getLayer(`${source}-${suffix}`)) this.map.removeLayer(`${source}-${suffix}`)
      if (this.map?.getSource(source)) this.map.removeSource(source)
      const editing = `${this.prefix}-editing`
      for (const suffix of ["fill","line"]) if (this.map?.getLayer(`${editing}-${suffix}`)) this.map.removeLayer(`${editing}-${suffix}`)
      if (this.map?.getSource(editing)) this.map.removeSource(editing)
    },
    disconnected() { this.epoch++; this.online = false; this.pending.clear(); this.inflight.clear(); this.gestures.clear(); this.draft = null; this.gate.reset(); this.commands = 0; this.permitted.clear(); this.motion.clear(); for (const marker of this.markers.values()) marker.remove(); this.markers.clear(); this.collaborators.clear(); this.draw?.setMode("static"); this.renderPresence(); this.renderUI() },
    reconnected() { this.synchronize() },
    destroyed() { this.disposed = true; this.epoch++; this.observer?.disconnect(); this.teardownControl(); this.gate.destroy(); this.motion.destroy(); this.motionPreference.removeEventListener("change",this.motionChanged); for (const marker of this.markers.values()) marker.remove(); this.listeners.forEach(remove => remove()); handles.delete(this.el) },
  }
}
