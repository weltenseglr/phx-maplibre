import Config

config :demo_berlin_districts, DemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "T7jREhYabqDr/9Kr6vdBnKNJwKOhV6ge5yv29E64h0YI0JSgV3gviQO4YRtQ8fpo",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
