defmodule GsdTracker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GsdTracker.Repo,
      {Phoenix.PubSub, name: GsdTracker.PubSub},
      {Task.Supervisor, name: GsdTracker.TaskSupervisor},
      GsdTracker.Timeline.Observer,
      GsdTrackerWeb.Endpoint
    ]

    # The boot-time fleet bootstrap is owned by the Observer: its init
    # detects an empty world (first boot AND crash-restarts, whose ETS
    # tables die with it) and spawns one loud, deduplicated bootstrap task.
    opts = [strategy: :one_for_one, name: GsdTracker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GsdTrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
