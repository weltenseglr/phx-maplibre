import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import maplibregl from "maplibre-gl"
import {createMapHook} from "phx_maplibre"

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
