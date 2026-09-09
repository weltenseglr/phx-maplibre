defmodule GsdTracker.SimulationIntegrationTest do
  use GsdTracker.DataCase, async: false

  alias GsdTracker.GSDStat
  alias GsdTracker.Ash, as: GsdDomain
  alias GsdTracker.Timeline
  alias GsdTracker.Timeline.Observer

  @moduletag :integration

  setup do
    clear_world()
    Phoenix.PubSub.subscribe(GsdTracker.PubSub, "gsd_updates")
    on_exit(&clear_world/0)
    :ok
  end

  defp quiet_env, do: [water_fun: fn _pos -> false end]

  defp clear_world do
    for table <- [Timeline.table(), Timeline.index()] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end
  end

  defp tick do
    send(Process.whereis(Observer), :tick)
    assert_receive {:update, payload}, 5_000
    # The broadcast happens mid-tick; wait for the whole handler AND the
    # background persistence task so assertions see the rows and the sandbox
    # owner never exits under a running task.
    _ = :sys.get_state(Observer)
    await_persist_idle()
    payload
  end

  defp await_persist_idle do
    Enum.reduce_while(1..200, :ok, fn _, _ ->
      if :sys.get_state(Process.whereis(Observer)).persist_ref == nil do
        {:halt, :ok}
      else
        Process.sleep(25)
        {:cont, :ok}
      end
    end)
  end

  defp stat_rows do
    GSDStat
    |> Ash.Query.for_read(:read)
    |> Ash.read!(domain: GsdDomain)
  end

  describe "full simulation integration" do
    test "bootstrap seeds the fleet and ticks broadcast the frozen payload" do
      {:ok, result} = Observer.bootstrap(gsd_count: 20, world_seed: 11, env: quiet_env())

      assert result.total == 20
      assert result.flocks + result.loners > 0

      %{positions: positions, stats: stats} = tick()

      assert length(positions) == 20
      assert stats.total == 20
      assert Map.has_key?(stats, :couples)
      assert Map.has_key?(stats, :flocks)
      assert Map.has_key?(stats, :by_state)

      for pos <- positions do
        assert %{
                 gsd_id: _,
                 lat: _,
                 lng: _,
                 status: _,
                 flock_id: _,
                 partner_id: _,
                 speed_kmh: _,
                 movement_vector: _,
                 last_update_at: %DateTime{}
               } = pos
      end
    end

    test "a tick extends every live timeline's planning horizon" do
      {:ok, _} = Observer.bootstrap(gsd_count: 10, world_seed: 12, env: quiet_env())

      pre_tick_ids = :ets.tab2list(Timeline.table()) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      tick()
      now = System.os_time(:second)

      # Newborn timelines (from leaves/splits during this very extension) get
      # their own extension next tick; every pre-existing live one must be
      # planned comfortably past now.
      live =
        :ets.tab2list(Timeline.table())
        |> Enum.filter(fn {id, tl} -> id in pre_tick_ids and tl.tombstone_t == nil end)

      assert live != []

      for {id, tl} <- live do
        assert tl.horizon_t >= now + 600, "timeline #{id} was not extended"
      end
    end

    test "ticks persist downsampled stats records" do
      {:ok, _} = Observer.bootstrap(gsd_count: 10, world_seed: 13, env: quiet_env())

      # :stat_persist_every_ticks is 1 in test config: every tick persists.
      tick()

      rows = stat_rows()
      assert length(rows) == 10
    end

    test "retention policy deletes old records" do
      previous_retention =
        Application.get_env(:demo_gsd_tracker, :stat_retention_ms, 7 * 24 * 60 * 60 * 1000)

      try do
        {:ok, _} = Observer.bootstrap(gsd_count: 5, world_seed: 14, env: quiet_env())

        tick()
        assert stat_rows() != []

        # Everything just written is now "old": the next persist pass prunes it.
        Application.put_env(:demo_gsd_tracker, :stat_retention_ms, -60_000)
        tick()

        assert stat_rows() |> length() <= 5
      after
        Application.put_env(:demo_gsd_tracker, :stat_retention_ms, previous_retention)
      end
    end
  end
end
