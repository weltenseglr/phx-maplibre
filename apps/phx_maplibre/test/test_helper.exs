Application.put_env(:phx_maplibre, PhxMaplibre.TestSupport.Endpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "phx_maplibre_test"],
  server: false
)

ExUnit.start()

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: PhxMaplibre.TestPubSub},
      PhxMaplibre.TestSupport.Endpoint
    ],
    strategy: :one_for_one
  )
