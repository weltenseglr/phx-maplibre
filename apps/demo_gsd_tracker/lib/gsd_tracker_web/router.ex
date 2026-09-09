defmodule GsdTrackerWeb.Router do
  @moduledoc false

  use GsdTrackerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GsdTrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_viewer_id
  end

  # Map ids derive from this cookie-session value: stable across reloads and
  # reconnects for one browser, still unique per viewer.
  defp ensure_viewer_id(conn, _opts) do
    if get_session(conn, "viewer_id") do
      conn
    else
      put_session(conn, "viewer_id", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    end
  end

  scope "/", GsdTrackerWeb do
    pipe_through :browser

    live "/", MapLive
    live "/about", AboutLive
  end
end
