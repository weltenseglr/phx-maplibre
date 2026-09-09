defmodule GsdTracker.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias GsdTracker.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GsdTracker.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, sandbox_owner: pid}
  end
end
