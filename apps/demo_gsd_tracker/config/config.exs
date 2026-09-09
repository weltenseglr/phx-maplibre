import Config

db_host = System.get_env("PGHOST", "localhost")
db_user = System.get_env("PGUSER", "postgres")
db_password = System.get_env("PGPASSWORD", "postgres")
db_name = System.get_env("PGDATABASE", "gsd_tracker_dev")

config :ash, :validate_domain_resource_inclusion?, false

config :demo_gsd_tracker,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [GsdTracker.Repo],
  ash_domains: [GsdTracker.Ash]

config :demo_gsd_tracker,
       :land_cover_geojson_path,
       "apps/demo_gsd_tracker/priv/data/land_cover.geojson"

config :demo_gsd_tracker, :gsd_count, 24_000
config :demo_gsd_tracker, :tick_ms, 5_000
# Live positions are broadcast on PubSub every tick; the database keeps a
# DOWNSAMPLED history — one row per GSD every :stat_persist_every_ticks ticks
# (5 minutes at 5s ticks), pruned after :stat_retention_ms. Persisting every
# tick at 24k GSDs over 7 days would be ~2.9 billion rows; the 5-minute
# sample keeps it near 48M (roughly 5-10 GB with indexes).
config :demo_gsd_tracker, :stat_persist_every_ticks, 60
config :demo_gsd_tracker, :stat_retention_ms, 7 * 24 * 60 * 60 * 1000
config :demo_gsd_tracker, :auto_schedule_simulation, true
# Seed the fleet automatically shortly after boot (tests turn this off and
# bootstrap their own, smaller worlds).
config :demo_gsd_tracker, :auto_bootstrap, true

# Optional: pin the timeline world seed for fully deterministic plans
# (tests do; unset, a random seed is drawn once at boot).
# config :demo_gsd_tracker, :world_seed, 1

config :demo_gsd_tracker, GsdTracker.Repo,
  username: db_user,
  password: db_password,
  hostname: db_host,
  database: db_name,
  types: GsdTracker.PostgresTypes

config :demo_gsd_tracker, GsdTrackerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GsdTrackerWeb.ErrorHTML, json: GsdTrackerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GsdTracker.PubSub,
  live_view: [signing_salt: "wCrCKJ8V"]

config :phoenix_live_view,
  root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  demo_gsd_tracker: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../assets", __DIR__),
        Path.expand("../../../deps", __DIR__),
        Path.expand("../..", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ]

config :tailwind,
  version: "4.3.0",
  demo_gsd_tracker: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
config :geo_postgis, json_library: Jason

import_config "#{config_env()}.exs"
