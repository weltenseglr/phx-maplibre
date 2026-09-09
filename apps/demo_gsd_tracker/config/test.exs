import Config

db_host = System.get_env("PGHOST", "localhost")
db_user = System.get_env("PGUSER", "postgres")
db_password = System.get_env("PGPASSWORD", "postgres")
db_name = System.get_env("PGDATABASE", "gsd_tracker_test")

config :demo_gsd_tracker, GsdTracker.Repo,
  username: db_user,
  password: db_password,
  hostname: db_host,
  database: "#{db_name}_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :demo_gsd_tracker, GsdTrackerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "T7jREhYabqDr/9Kr6vdBnKNJwKOhV6ge5yv29E64h0YI0JSgV3gviQO4YRtQ8fpo",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true

config :demo_gsd_tracker, :auto_schedule_simulation, false
# Tests seed their own worlds; the boot-time bootstrap task has no sandbox
# connection and would only race the suite.
config :demo_gsd_tracker, :auto_bootstrap, false

# Tests drive :collect manually and expect every tick persisted.
config :demo_gsd_tracker, :stat_persist_every_ticks, 1
