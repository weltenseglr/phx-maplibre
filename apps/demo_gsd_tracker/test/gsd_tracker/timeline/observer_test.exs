defmodule GsdTracker.Timeline.ObserverTest do
  use GsdTracker.DataCase, async: false

  alias GsdTracker.Timeline
  alias GsdTracker.Timeline.{Observer, Segment, World}

  @center %{lat: 52.52, lng: 13.405}

  setup do
    clear_world()
    on_exit(&clear_world/0)
    :ok
  end

  defp quiet_env, do: [water_fun: fn _pos -> false end]

  defp clear_world do
    for table <- [Timeline.table(), Timeline.index()] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end
  end

  defp bootstrap!(count, seed) do
    {:ok, summary} = Observer.bootstrap(gsd_count: count, world_seed: seed, env: quiet_env())
    summary
  end

  defp db_count!(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
    n
  end

  # Persistence runs in a background task; drain it so the sandbox owner
  # never exits underneath it.
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

  test "bootstrap creates rows, timelines, and the paired/flocked structure" do
    summary = bootstrap!(40, 1)

    assert summary.total == 40
    assert summary.flocks >= 1
    assert db_count!("gsds") == 40
    assert db_count!("flocks") == summary.flocks

    # Persisted member counts account for every flocked unit.
    %{rows: [[member_sum]]} =
      Repo.query!("SELECT coalesce(sum(member_count), 0)::bigint FROM flocks")

    assert member_sum == 40 - summary.loners

    %{rows: [[partnered]]} = Repo.query!("SELECT count(*) FROM gsds WHERE partner_id IS NOT NULL")
    assert partnered == trunc(40 * 0.85)

    now = System.os_time(:second)
    assert World.live_count(now) == 40

    # every unit is indexed and every spawn sits on the 30 km disc
    {positions, _stats} = World.at(now, DateTime.utc_now())
    assert length(positions) == 40

    for pos <- positions do
      assert [{_, _timeline_id}] = :ets.lookup(Timeline.index(), pos.gsd_id)
      assert Segment.distance_m(%{lat: pos.lat, lng: pos.lng}, @center) <= 31_000.0
    end
  end

  test "a pinned world seed and clock reproduce byte-identical worlds" do
    now_dt = DateTime.utc_now() |> DateTime.truncate(:second)
    now = DateTime.to_unix(now_dt)

    {:ok, _} = Observer.bootstrap(gsd_count: 20, world_seed: 7, env: quiet_env(), now: now_dt)
    first_world = :ets.tab2list(Timeline.table()) |> Map.new()
    {first, _} = World.at(now + 120, now_dt)

    clear_world()

    {:ok, _} = Observer.bootstrap(gsd_count: 20, world_seed: 7, env: quiet_env(), now: now_dt)
    second_world = :ets.tab2list(Timeline.table()) |> Map.new()
    {second, _} = World.at(now + 120, now_dt)

    assert first_world == second_world

    sort = fn positions -> Enum.sort_by(positions, & &1.gsd_id) end
    assert sort.(first) == sort.(second)
  end

  test "a tick broadcasts the frozen gsd_updates payload" do
    bootstrap!(10, 2)
    Phoenix.PubSub.subscribe(GsdTracker.PubSub, "gsd_updates")

    send(Process.whereis(Observer), :tick)

    assert_receive {:update, %{positions: positions, stats: stats}}, 5_000
    _ = :sys.get_state(Observer)
    await_persist_idle()
    assert length(positions) == 10
    assert stats.total == 10

    assert %{
             gsd_id: _,
             lat: _,
             lng: _,
             status: _,
             flock_id: _,
             partner_id: _,
             speed_kmh: _,
             movement_vector: %{lat: _, lng: _},
             last_update_at: %DateTime{}
           } = hd(positions)
  end

  test "replenishment tops a depleted world back up" do
    previous_count = Application.get_env(:demo_gsd_tracker, :gsd_count)
    Application.put_env(:demo_gsd_tracker, :gsd_count, 10)
    Application.put_env(:demo_gsd_tracker, :replenish_delay_ms, {0, 0})

    on_exit(fn ->
      Application.put_env(:demo_gsd_tracker, :gsd_count, previous_count)
      Application.delete_env(:demo_gsd_tracker, :replenish_delay_ms)
    end)

    bootstrap!(4, 3)
    Phoenix.PubSub.subscribe(GsdTracker.PubSub, "gsd_updates")
    observer = Process.whereis(Observer)

    # first tick arms the (zero-delay) respawn timer, second one replenishes
    send(observer, :tick)
    assert_receive {:update, _}, 5_000
    send(observer, :tick)
    assert_receive {:update, %{stats: stats}}, 5_000
    _ = :sys.get_state(observer)
    await_persist_idle()

    assert stats.total > 4
    assert db_count!("gsds") == stats.total
  end

  test "flock effects maintain the persisted member_count" do
    flock_id = Ecto.UUID.generate()
    t = System.os_time(:second)

    Observer.apply_effect({:insert_flock, flock_id, %{lat: 52.5, lng: 13.4}, 4, t})
    assert flock_count!(flock_id) == 4

    Observer.apply_effect({:update_flock_count, flock_id, 3, t})
    assert flock_count!(flock_id) == 3

    Observer.apply_effect({:delete_flock, flock_id, t})
    assert flock_count!(flock_id) == nil
  end

  test "needs_bootstrap? requires auto_bootstrap and an empty world" do
    # Test config disables auto_bootstrap, so the boot continue never seeds.
    refute Observer.needs_bootstrap?()

    Application.put_env(:demo_gsd_tracker, :auto_bootstrap, true)
    on_exit(fn -> Application.put_env(:demo_gsd_tracker, :auto_bootstrap, false) end)

    # The world was cleared in setup — an empty table demands a (re)bootstrap…
    assert Observer.needs_bootstrap?()

    # …and a populated one does not.
    bootstrap!(4, 9)
    refute Observer.needs_bootstrap?()
  end

  test "a crash-restart comes back with fresh empty tables and re-arms bootstrap" do
    bootstrap!(4, 8)
    assert :ets.info(Timeline.table(), :size) > 0

    pid = Process.whereis(Observer)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    new_pid =
      Enum.find_value(1..500, fn _ ->
        Process.sleep(10)

        case Process.whereis(Observer) do
          nil -> nil
          ^pid -> nil
          restarted -> restarted
        end
      end)

    assert is_pid(new_pid)
    _ = :sys.get_state(new_pid)

    # The owned ETS tables died with the crash and were recreated empty…
    assert :ets.info(Timeline.table(), :size) == 0
    assert :ets.info(Timeline.index(), :size) == 0

    # …which is exactly what the restart's continue checks: with
    # auto_bootstrap on (dev/prod) it spawns the loud reseeding task.
    Application.put_env(:demo_gsd_tracker, :auto_bootstrap, true)
    on_exit(fn -> Application.put_env(:demo_gsd_tracker, :auto_bootstrap, false) end)
    assert Observer.needs_bootstrap?()
  end

  defp flock_count!(flock_id) do
    {:ok, uuid} = Ecto.UUID.dump(flock_id)

    case Repo.query!("SELECT member_count FROM flocks WHERE id = $1", [uuid]).rows do
      [[count]] -> count
      [] -> nil
    end
  end
end
