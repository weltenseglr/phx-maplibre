defmodule GsdTrackerWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :demo_gsd_tracker

  @session_options [
    store: :cookie,
    key: "_gsd_tracker_key",
    signing_salt: "gY7hR4s2",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :demo_gsd_tracker,
    gzip: not code_reloading?,
    only: GsdTrackerWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GsdTrackerWeb.Router
end
