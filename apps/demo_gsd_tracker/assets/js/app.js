import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import * as maplibregl from "maplibre-gl"
import {createMapHook, getMapHandle} from "phx_maplibre"

// esbuild bundles the main module; MapLibre 6's separate worker stays static.
if (maplibregl.getVersion?.().startsWith("6.")) {
  maplibregl.setWorkerUrl("/assets/js/maplibre-gl-worker.mjs")
}

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {
    PhxMaplibreHook: createMapHook(maplibregl),
    ConnectionStatus: {
      mounted() { this.setConnection(true) },
      reconnected() { this.setConnection(true) },
      disconnected() { this.setConnection(false) },
      updated() { this.setConnection(this.connectionLive) },
      setConnection(live) {
        this.connectionLive = live
        this.el.dataset.connection = live ? "live" : "offline"
        this.el.classList.toggle("is-offline", !live)
      },
    },
  }
})

liveSocket.connect()

window.liveSocket = liveSocket

// Documented library API exposed for the demo browser tests and developer console.
window.phxMaplibre = Object.freeze({getMapHandle})
