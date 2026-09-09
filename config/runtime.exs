import Config

# The umbrella's single runtime config: every app's config_path points at the
# umbrella root, so this file owns runtime settings for both demo endpoints
# (import_config is not allowed in runtime files, hence no per-app split).

if System.get_env("PHX_SERVER") do
  config :demo_berlin_districts, DemoWeb.Endpoint, server: true
  config :demo_gsd_tracker, GsdTrackerWeb.Endpoint, server: true
end

config :demo_berlin_districts, DemoWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("DEMO_PORT", "4001"))]

config :demo_gsd_tracker, GsdTrackerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("GSD_PORT", "4002"))]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Both demo endpoints run in one BEAM, so each reads its own host variable
  # (with the generic PHX_HOST as a shared fallback).
  demo_host =
    System.get_env("DEMO_PHX_HOST") || System.get_env("PHX_HOST") || "example.com"

  gsd_host = System.get_env("GSD_PHX_HOST") || System.get_env("PHX_HOST") || "example.com"

  config :demo_berlin_districts, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :demo_berlin_districts, DemoWeb.Endpoint,
    url: [host: demo_host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    check_origin: ["https://#{demo_host}"]

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://postgres:postgres@localhost/gsd_tracker_prod
      """

  config :demo_gsd_tracker, GsdTracker.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: if(System.get_env("ECTO_IPV6"), do: [:inet6], else: [])

  config :demo_gsd_tracker, GsdTrackerWeb.Endpoint,
    url: [host: gsd_host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    # Let's Encrypt refuses underscores, so gsd-tracker.* carries the valid
    # certificate; the underscore variant stays reachable regardless.
    check_origin: [
      "https://#{gsd_host}",
      "https://gsd-tracker.weltenseglr.de",
      "https://gsd_tracker.weltenseglr.de"
    ]

  config :demo_gsd_tracker,
         :gsd_count,
         String.to_integer(System.get_env("GSD_COUNT", "24000"))
end
