defmodule DemoWeb.Router do
  use DemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_viewer_id
  end

  # Map ids derive from this cookie-session value: stable across reloads and
  # reconnects for one browser, still unique per viewer (the security
  # property the per-session ids exist for).
  defp ensure_viewer_id(conn, _opts) do
    if get_session(conn, "viewer_id") do
      conn
    else
      put_session(conn, "viewer_id", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DemoWeb do
    pipe_through :browser

    get "/", PageController, :redirect_to_map
    live "/map", MapLive
    live "/explore", ExploreLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", DemoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:demo_berlin_districts, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DemoWeb.Telemetry
    end
  end
end
