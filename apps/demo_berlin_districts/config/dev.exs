import Config

config :demo_berlin_districts, DemoWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "4ru7zSujfDOh3bX89l5nXqTmfjvKGfyzD75CuU65dVFlAgp7JYc+i9pwItLNYBsp",
  watchers: [
    esbuild:
      {Esbuild, :install_and_run, [:demo_berlin_districts, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:demo_berlin_districts, ~w(--watch)]}
  ]

config :demo_berlin_districts, DemoWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/demo_web/router\.ex$",
      ~r"lib/demo_web/(components|controllers|live)/.*\.(ex|heex)$"
    ]
  ]

config :demo_berlin_districts, :dev_routes, true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
