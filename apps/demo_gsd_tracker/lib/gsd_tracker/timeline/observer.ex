defmodule GsdTracker.Timeline.Observer do
  @moduledoc """
  The one periodic process of the simulation.

  Every `:tick_ms` it executes due database side effects, extends timelines
  approaching their planning horizon, checks replenishment, evaluates
  `World.at(now)`, broadcasts the frozen `"gsd_updates"` payload, and — every
  `:stat_persist_every_ticks` ticks — hands the evaluated positions to a
  supervised background task that persists the downsampled history and prunes
  it past `:stat_retention_ms` (one task at a time; a still-running one skips
  the batch with a warning). It owns the timeline ETS tables and the
  water-grid cache. Everything else about the world is a pure function.

  A tick touches the timeline table exactly once in full (the `World.at`
  fold); planning and cleanup candidates come from a cheap `:ets.select` over
  `{id, horizon_t, tombstone_t}` with targeted lookups, and the replenishment
  deficit uses the previous evaluation's live count.

  ## Scale ceiling

  One Observer evaluates ~24k members in 210–380 ms per 5 s tick; the
  conservative 380 ms measurement extrapolates the single-process ceiling to
  roughly 250–315k members. Beyond that, partitioning the timeline table
  across several evaluator processes (sharded folds feeding one broadcast) is
  the known scale-out path — deliberately deferred at the 24k target.
  """

  use GenServer

  alias GsdTracker.Repo
  alias GsdTracker.Timeline
  alias GsdTracker.Timeline.{Bootstrap, Plan, Rng, World}

  require Logger

  @horizon_s 1800
  @horizon_min_s 600
  @bootstrap_delay_ms 1_000
  @bootstrap_task_name :gsd_timeline_bootstrap_task

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Seed a fresh fleet (wipes the population tables). Returns `{:ok, summary}`.

  The database work runs in the calling process (which owns the sandbox
  connection under test); only the resulting timelines are installed into the
  Observer's ETS tables via a call.
  """
  def bootstrap(opts \\ []) do
    world_seed =
      Keyword.get(
        opts,
        :world_seed,
        Application.get_env(:demo_gsd_tracker, :world_seed) || :erlang.phash2(make_ref())
      )

    result = Bootstrap.run(Keyword.put(opts, :world_seed, world_seed))
    GenServer.call(__MODULE__, {:install, result.timelines, world_seed}, 60_000)
    {:ok, Map.take(result, [:total, :flocks, :loners])}
  end

  @impl true
  def init(_opts) do
    ensure_table(Timeline.table())
    ensure_table(Timeline.index())
    GsdTracker.Simulation.WaterGrid.ensure_table()

    maybe_schedule_tick()

    {:ok,
     %{
       world_seed:
         Application.get_env(:demo_gsd_tracker, :world_seed) || :erlang.phash2(make_ref()),
       tick: 0,
       respawn_at: nil,
       effects: [],
       # live population as of the last evaluation (or install); the
       # replenishment deficit reads this instead of re-walking the table
       live_count: 0,
       persist_ref: nil
     }, {:continue, :maybe_bootstrap}}
  end

  # The ETS tables die with this process, so a crash-restart comes back to an
  # empty world with stale DB rows. Self-heal by re-running the same loud
  # bootstrap the application boot uses — this is the ONLY place that spawns
  # it (first boot included), and the task registers a name so racing
  # restarts can never double-bootstrap. Bootstrap TRUNCATEs first: reseeding
  # is the accepted crash semantics (pending effects are lost with the plans).
  @impl true
  def handle_continue(:maybe_bootstrap, state) do
    if needs_bootstrap?(), do: start_bootstrap_task()
    {:noreply, state}
  end

  @doc """
  Whether an automatic (re)bootstrap should run: `:auto_bootstrap` is enabled
  and the timeline table is missing or empty.
  """
  def needs_bootstrap? do
    Application.get_env(:demo_gsd_tracker, :auto_bootstrap, true) and world_empty?()
  end

  defp world_empty? do
    case :ets.whereis(Timeline.table()) do
      :undefined -> true
      _tid -> :ets.info(Timeline.table(), :size) == 0
    end
  end

  defp start_bootstrap_task do
    Task.start(fn ->
      try do
        Process.register(self(), @bootstrap_task_name)
      rescue
        # another bootstrap task is already running; let it finish alone
        ArgumentError -> exit(:normal)
      end

      :timer.sleep(@bootstrap_delay_ms)
      run_bootstrap()
    end)
  end

  # Deliberately loud: a failed bootstrap leaves an empty map and must say so.
  defp run_bootstrap do
    case bootstrap() do
      {:ok, %{total: 0}} ->
        Logger.error("""
        GSD simulation bootstrap produced an empty population (0 GSDs). \
        The map will stay empty. Check that the database is migrated and \
        seeded: `mix ecto.setup` and `mix gsd_tracker.fetch_land_cover`.\
        """)

      {:ok, %{total: total, flocks: flocks, loners: loners}} ->
        Logger.info(
          "GSD simulation bootstrapped: #{total} GSDs (#{flocks} flocks, #{loners} loners)"
        )
    end
  rescue
    error ->
      Logger.error("""
      GSD simulation bootstrap failed: #{Exception.message(error)}
      The map will stay empty. This usually means the database is missing, \
      unmigrated, or has no land cover data. Try `mix ecto.setup` followed by \
      `mix gsd_tracker.fetch_land_cover`.

      #{Exception.format(:error, error, __STACKTRACE__)}\
      """)
  catch
    kind, reason ->
      Logger.error("""
      GSD simulation bootstrap exited: #{inspect(kind)} #{inspect(reason)}
      The map will stay empty. This usually means the database is missing, \
      unmigrated, or has no land cover data. Try `mix ecto.setup` followed by \
      `mix gsd_tracker.fetch_land_cover`.

      #{Exception.format(kind, reason, __STACKTRACE__)}\
      """)
  end

  defp ensure_table(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  rescue
    ArgumentError -> name
  end

  @impl true
  def handle_call({:install, timelines, world_seed}, _from, state) do
    :ets.delete_all_objects(Timeline.table())
    :ets.delete_all_objects(Timeline.index())

    Enum.each(timelines, &store_timeline/1)
    live = Enum.reduce(timelines, 0, fn tl, acc -> acc + length(tl.members) end)

    {:reply, :ok,
     %{state | world_seed: world_seed, respawn_at: nil, effects: [], tick: 0, live_count: live}}
  end

  @impl true
  def handle_info(:tick, state) do
    started = System.monotonic_time(:millisecond)
    now_dt = DateTime.utc_now() |> DateTime.truncate(:second)
    now_s = DateTime.to_unix(now_dt)
    env = Plan.env()

    state = execute_due_effects(state, now_s)

    {extend_ids, finished_ids} = scan_metadata(now_s)
    Enum.each(finished_ids, &:ets.delete(Timeline.table(), &1))
    state = extend_timelines(state, extend_ids, now_s, env)
    state = maybe_replenish(state, now_s, now_dt, env)

    {positions, stats} = World.at(now_s, now_dt)

    Phoenix.PubSub.broadcast(
      GsdTracker.PubSub,
      "gsd_updates",
      {:update, %{positions: positions, stats: stats}}
    )

    state = %{state | live_count: stats.total}
    state = maybe_persist(state, positions, now_dt)

    Logger.debug(fn ->
      "Observer tick #{state.tick}: #{length(positions)} units in #{System.monotonic_time(:millisecond) - started}ms"
    end)

    maybe_schedule_tick()
    {:noreply, %{state | tick: state.tick + 1}}
  end

  # Completion / crash of the background persistence task.
  @impl true
  def handle_info({ref, _result}, %{persist_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | persist_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{persist_ref: ref} = state) do
    Logger.warning("Observer: stat persistence task died: #{inspect(reason)}")
    {:noreply, %{state | persist_ref: nil}}
  end

  # Stale task messages (e.g. after an install reset) are dropped.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  ## Side effects

  defp execute_due_effects(state, now_s) do
    {due, later} =
      Enum.split_with(state.effects, fn effect ->
        elem(effect, tuple_size(effect) - 1) <= now_s
      end)

    # New flocks must exist before members point at them; a dissolved flock's
    # row is deleted only after every member reference was nil'ed.
    due
    |> Enum.sort_by(fn
      {:insert_flock, _, _, _, t} -> {t, 0}
      {:delete_flock, _, t} -> {t, 2}
      effect -> {elem(effect, tuple_size(effect) - 1), 1}
    end)
    |> Enum.each(&execute_effect/1)

    %{state | effects: later}
  end

  @doc false
  def apply_effect(effect), do: execute_effect(effect)

  defp execute_effect({:delete_gsd, gsd_id, _t}) do
    with {:ok, uuid} <- Ecto.UUID.dump(gsd_id) do
      Repo.query("DELETE FROM gsds WHERE id = $1", [uuid])
    end

    :ets.delete(Timeline.index(), gsd_id)
  rescue
    error -> Logger.debug("Observer: delete_gsd failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.debug("Observer: delete_gsd exited: #{inspect(reason)}")
  end

  defp execute_effect({:update_partner, gsd_id, partner_id, _t}) do
    update_gsd_column("partner_id", gsd_id, partner_id)
  end

  defp execute_effect({:update_flock_ref, gsd_id, flock_id, _t}) do
    update_gsd_column("flock_id", gsd_id, flock_id)
  end

  defp execute_effect({:insert_flock, flock_id, center, member_count, _t}) do
    with {:ok, uuid} <- Ecto.UUID.dump(flock_id) do
      Repo.query(
        """
        INSERT INTO flocks (id, member_count, center_location)
        VALUES ($1, $4, ST_SetSRID(ST_MakePoint($2, $3), 4326))
        ON CONFLICT (id) DO NOTHING
        """,
        [uuid, center.lng, center.lat, member_count]
      )
    end
  rescue
    error -> Logger.debug("Observer: insert_flock failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.debug("Observer: insert_flock exited: #{inspect(reason)}")
  end

  defp execute_effect({:update_flock_count, flock_id, member_count, _t}) do
    with {:ok, uuid} <- Ecto.UUID.dump(flock_id) do
      Repo.query("UPDATE flocks SET member_count = $2 WHERE id = $1", [uuid, member_count])
    end
  rescue
    error -> Logger.debug("Observer: update_flock_count failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.debug("Observer: update_flock_count exited: #{inspect(reason)}")
  end

  defp execute_effect({:delete_flock, flock_id, _t}) do
    with {:ok, uuid} <- Ecto.UUID.dump(flock_id) do
      Repo.query("DELETE FROM flocks WHERE id = $1", [uuid])
    end
  rescue
    error -> Logger.debug("Observer: delete_flock failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.debug("Observer: delete_flock exited: #{inspect(reason)}")
  end

  defp update_gsd_column(column, gsd_id, value) do
    with {:ok, uuid} <- Ecto.UUID.dump(gsd_id) do
      dumped_value =
        case value do
          nil -> nil
          other -> Ecto.UUID.dump!(other)
        end

      Repo.query("UPDATE gsds SET #{column} = $2 WHERE id = $1", [uuid, dumped_value])
    end
  rescue
    error -> Logger.debug("Observer: update #{column} failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.debug("Observer: update #{column} exited: #{inspect(reason)}")
  end

  ## Planning

  # One cheap pass over {id, horizon_t, tombstone_t} — no member/segment terms
  # are copied out of ETS — yielding the timelines that need extension and the
  # tombstoned ones that are finished. The only full-table materialization of
  # a tick is the World.at evaluation fold.
  defp scan_metadata(now_s) do
    threshold = now_s + @horizon_min_s

    :ets.select(Timeline.table(), [
      {{:"$1", %{horizon_t: :"$2", tombstone_t: :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
    |> Enum.reduce({[], []}, fn {id, horizon_t, tombstone_t}, {extend, finished} ->
      cond do
        tombstone_t != nil and tombstone_t <= now_s -> {extend, [id | finished]}
        tombstone_t == nil and horizon_t < threshold -> {[id | extend], finished}
        true -> {extend, finished}
      end
    end)
  end

  defp extend_timelines(state, extend_ids, now_s, env) do
    effects =
      Enum.reduce(extend_ids, [], fn id, fx_acc ->
        case :ets.lookup(Timeline.table(), id) do
          [{_id, tl}] ->
            {timelines, effects} = Plan.extend(tl, now_s + @horizon_s, env)

            Enum.each(timelines, fn extended ->
              store_timeline(prune_segments(extended, now_s))
            end)

            effects ++ fx_acc

          [] ->
            fx_acc
        end
      end)

    %{state | effects: effects ++ state.effects}
  end

  defp prune_segments(tl, now_s) do
    keep_after = now_s - @horizon_min_s
    {old, kept} = Enum.split_while(tl.segments, fn seg -> seg.t1 < keep_after end)

    flown =
      Enum.reduce(old, 0.0, fn
        %{kind: :fly, length_m: length_m}, acc -> acc + length_m
        _seg, acc -> acc
      end)

    case kept do
      [] -> tl
      _ -> %{tl | segments: kept, distance_base_m: tl.distance_base_m + flown}
    end
  end

  defp store_timeline(tl) do
    :ets.insert(Timeline.table(), {tl.id, tl})
    Enum.each(tl.members, fn m -> :ets.insert(Timeline.index(), {m.gsd_id, tl.id}) end)
  end

  ## Replenishment (population fluctuates by design)

  # The deficit reads the PREVIOUS evaluation's live count (one tick of lag,
  # well inside the minutes-scale respawn delay) so replenishment costs no
  # table walk of its own.
  defp maybe_replenish(state, now_s, now_dt, env) do
    target = Application.get_env(:demo_gsd_tracker, :gsd_count, 10_000)
    deficit = target - state.live_count

    cond do
      deficit <= 0 ->
        %{state | respawn_at: nil}

      state.respawn_at == nil ->
        {min_ms, max_ms} =
          Application.get_env(:demo_gsd_tracker, :replenish_delay_ms, {60_000, 300_000})

        u = Rng.roll(state.world_seed, {:replenish_delay, state.tick})
        %{state | respawn_at: now_s + (min_ms + u * (max_ms - min_ms)) / 1000.0}

      now_s >= state.respawn_at ->
        # Replace the whole observed deficit. A fixed-size batch imposes a
        # replacement-rate ceiling while departures scale with fleet size,
        # causing the population to settle far below the configured target.
        # The randomized delay still allows natural short-term fluctuations.
        replenish(deficit, state, now_s, now_dt, env)
        %{state | respawn_at: nil}

      true ->
        state
    end
  end

  defp replenish(batch, state, now_s, now_dt, env) do
    units =
      Enum.map(1..batch, fn i ->
        %{
          gsd_id: Rng.uuid(state.world_seed, {:replenish, state.tick, i}),
          origin: Bootstrap.spawn_location(state.world_seed, {:replenish, state.tick, i}, env)
        }
      end)

    units
    |> Enum.map(&Bootstrap.gsd_row(&1.gsd_id, nil, &1.origin, now_dt))
    |> Bootstrap.insert_gsds()

    Enum.each(units, fn unit ->
      member =
        Plan.member(unit.gsd_id,
          birth_t: now_s,
          partner_id: nil,
          commissioning_date: now_dt,
          noise_seed: :erlang.phash2({state.world_seed, unit.gsd_id})
        )

      member
      |> Plan.new_loner(unit.origin, now_s, :erlang.phash2({state.world_seed, unit.gsd_id}), env)
      |> store_timeline()
    end)

    Logger.info("Observer: replenished #{batch} units")
  rescue
    error -> Logger.warning("Observer: replenishment failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("Observer: replenishment exited: #{inspect(reason)}")
  end

  ## Persistence

  # Record preparation AND the IO (48 upsert batches at 24k, plus the
  # retention DELETE) run off the tick path in one supervised task at a time.
  # If the previous batch is still running when the next persist tick
  # arrives, that batch is skipped with a warning — bounded backpressure,
  # never a queue.
  defp maybe_persist(state, positions, now_dt) do
    persist_every = Application.get_env(:demo_gsd_tracker, :stat_persist_every_ticks, 60)

    if rem(state.tick, max(persist_every, 1)) == 0 do
      start_persist_task(state, positions, now_dt)
    else
      state
    end
  end

  defp start_persist_task(%{persist_ref: ref} = state, _positions, _now_dt) when ref != nil do
    Logger.warning("Observer: previous stat persistence still running — skipping this batch")
    state
  end

  defp start_persist_task(state, positions, now_dt) do
    task =
      Task.Supervisor.async_nolink(GsdTracker.TaskSupervisor, fn ->
        persist_stats(positions, now_dt)
        delete_old_records()
      end)

    %{state | persist_ref: task.ref}
  end

  defp persist_stats([], _now_dt), do: :ok

  defp persist_stats(positions, now_dt) do
    records =
      Enum.map(positions, fn pos ->
        %{
          timestamp: now_dt,
          gsd_id: pos.gsd_id,
          flock_id: pos.flock_id,
          partner_id: pos.partner_id,
          location: %Geo.Point{coordinates: {pos.lng, pos.lat}, srid: 4326},
          status: pos.status,
          movement_vector: pos.movement_vector,
          speed_kmh: Decimal.from_float(pos.speed_kmh * 1.0)
        }
      end)

    result =
      Ash.bulk_create(records, GsdTracker.GSDStat, :bulk_upsert,
        domain: GsdTracker.Ash,
        batch_size: 500,
        return_records?: false,
        return_errors?: true
      )

    case result do
      %{status: :success} -> :ok
      other -> Logger.warning("Observer: stat persistence issues: #{inspect(other.status)}")
    end
  rescue
    error -> Logger.warning("Observer: stat persistence failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("Observer: stat persistence exited: #{inspect(reason)}")
  end

  defp delete_old_records do
    retention_ms =
      Application.get_env(:demo_gsd_tracker, :stat_retention_ms, 7 * 24 * 60 * 60 * 1000)

    cutoff = DateTime.add(DateTime.utc_now(), -retention_ms, :millisecond)
    Repo.query("DELETE FROM gsd_stats WHERE timestamp < $1", [cutoff])
    :ok
  rescue
    error -> Logger.debug("Observer: retention prune failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.debug("Observer: retention prune exited: #{inspect(reason)}")
  end

  defp maybe_schedule_tick do
    if Application.get_env(:demo_gsd_tracker, :auto_schedule_simulation, true) do
      tick_ms = Application.get_env(:demo_gsd_tracker, :tick_ms, 5_000)
      Process.send_after(self(), :tick, tick_ms)
    end
  end
end
