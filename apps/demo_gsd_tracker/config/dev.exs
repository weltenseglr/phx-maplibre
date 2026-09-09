import Config

config :demo_gsd_tracker, GsdTracker.Repo,
  database: "gsd_tracker_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  log: :warning

config :demo_gsd_tracker, GsdTrackerWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  check_origin: false,
  code_reloader: true,
  reloadable_apps: [:demo_gsd_tracker],
  debug_errors: true,
  secret_key_base: "4ru7zSujfDOh3bX89l5nXqTmfjvKGfyzD75CuU65dVFlAgp7JYc+i9pwItLNYBsp",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:demo_gsd_tracker, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:demo_gsd_tracker, ~w(--watch)]}
  ]

config :demo_gsd_tracker, GsdTrackerWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/gsd_tracker_web/router\.ex$",
      ~r"lib/gsd_tracker_web/(components|controllers|live)/.*\.(ex|heex)$"
    ]
  ]

config :logger, :default_formatter, format: "[$level] $message\n"

config :logger, level: :warning

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: false,
  debug_attributes: false,
  enable_expensive_runtime_checks: true
