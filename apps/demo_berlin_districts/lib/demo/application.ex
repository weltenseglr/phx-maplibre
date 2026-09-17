defmodule Demo.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DemoWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:demo_berlin_districts, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Demo.PubSub},
      {PhxMaplibre.Editor.Runtime, name: Demo.EditorRuntime, pubsub: Demo.PubSub},
      DemoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Demo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
