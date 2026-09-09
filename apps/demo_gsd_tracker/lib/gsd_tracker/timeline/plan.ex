defmodule GsdTracker.Timeline.Plan do
  @moduledoc """
  The planner: lazily extends timelines with new segments and materializes
  pre-rolled events.

  Extension is a deterministic unfold of `(seed, counter)` — the wall-clock
  timing of extension calls cannot change a plan's content, only how much of
  it is materialized. Randomness enters exactly twice: decision draws at
  segment boundaries (status, dwell, waypoints, event targets) and the
  pre-rolled next-event times (`Exp(λ)` inverse-CDF). Events fire quantized
  to the first segment boundary at or after their rolled time, so segments
  are never cut mid-profile and every boundary keeps `v = 0`.
  """

  alias GsdTracker.Timeline
  alias GsdTracker.Timeline.{Member, Rng, Segment}

  @grounded_statuses [:charging, :maintenance]
  @active_statuses [
    :surveillance,
    :simulating,
    :target_tracking,
    :aerial_surveillance,
    :moving_to_new_target
  ]

  # seconds {min, max}, ported from the tick-based simulation
  @dwell %{
    charging: {4 * 3600, 8 * 3600},
    maintenance: {1 * 3600, 3 * 3600},
    surveillance: {600, 3600},
    simulating: {600, 2700},
    aerial_surveillance: {900, 5400},
    target_tracking: {1200, 10_800}
  }

  # Daytime ground stops are deliberately brief: they represent opportunistic
  # charging and maintenance rotations, not an overnight stand-down.
  @day_grounded_dwell %{
    charging: {60 * 60, 3 * 3600},
    maintenance: {30 * 60, 90 * 60}
  }

  @default_rates %{
    # per member per second (old 0.001 per 5s tick)
    leave: 2.0e-4,
    # per member per second (old 0.0002·n per 5s tick)
    split: 4.0e-5,
    bond_drop_mean_s: 8 * 3600,
    bond_form_mean_s: 2 * 3600,
    departure_mean_s: 12 * 3600
  }

  @moving_target_range {2_000.0, 140_000.0}
  @patrol_leg_range {2_000.0, 20_000.0}
  @target_attempts 8
  @water_attempts 6

  # Status-pool mix (statistical, not absolute): share of DAY draws that
  # land in the grounded pool, and of NIGHT draws that land in the active
  # pool ("just a very small percentage should be up at night").
  @day_grounded_fraction 0.10
  @night_active_fraction 0.03

  @doc "The planning environment with config-derived defaults; all overridable."
  def env(overrides \\ []) do
    Map.merge(
      %{
        center:
          Application.get_env(:demo_gsd_tracker, :tracking_center, %{lat: 52.52, lng: 13.405}),
        spawn_radius_m: Application.get_env(:demo_gsd_tracker, :spawn_radius_m, 30_000.0),
        tracking_radius_m: Application.get_env(:demo_gsd_tracker, :tracking_radius_m, 75_000.0),
        dwell_scale: Application.get_env(:demo_gsd_tracker, :status_dwell_scale, 1.0),
        water_fun: &GsdTracker.Simulation.WaterGrid.water?/1,
        rates: @default_rates
      },
      Map.new(overrides)
    )
  end

  def dwell_windows, do: @dwell
  def day_grounded_dwell_windows, do: @day_grounded_dwell
  def grounded_statuses, do: @grounded_statuses
  def active_statuses, do: @active_statuses
  def day_grounded_fraction, do: @day_grounded_fraction
  def night_active_fraction, do: @night_active_fraction

  @doc "Solar-hour night rule, unchanged from the tick simulation."
  def night?(lng, t) do
    utc_hour = t |> trunc() |> DateTime.from_unix!() |> Map.fetch!(:hour)
    solar_hour = rem(trunc(lng / 15.0) + utc_hour + 24, 24)
    solar_hour < 6 or solar_hour >= 22
  end

  @doc "The flock-validity rule: ≥3 members, or exactly 2 that are not a couple."
  def valid_flock?(members, t) do
    case members do
      [_, _, _ | _] ->
        true

      [a, b] ->
        Timeline.partner_at(a, t) != b.gsd_id and Timeline.partner_at(b, t) != a.gsd_id

      _ ->
        false
    end
  end

  ## Timeline construction

  @doc "A new flock timeline at `origin`, members already carrying slots/phases."
  def new_flock(id, flock_id, members, origin, birth_t, seed, env) do
    %Timeline{
      id: id,
      flock_id: flock_id,
      seed: seed,
      counter: 0,
      birth_t: birth_t,
      segments: [],
      horizon_t: birth_t,
      members: members,
      events: %{},
      tombstone_t: nil
    }
    |> seed_initial_segment(origin, birth_t, env)
    |> roll_all_events(birth_t, env)
  end

  @doc "A new loner timeline (single member, no slot)."
  def new_loner(%Member{} = member, origin, birth_t, seed, env) do
    new_flock(member.gsd_id, nil, [%Member{member | slot: nil}], origin, birth_t, seed, env)
  end

  @doc "Build a member struct; `slot: nil` for loners."
  def member(gsd_id, opts) do
    noise_seed = Keyword.get(opts, :noise_seed, gsd_id)

    %Member{
      gsd_id: gsd_id,
      partner: [{Keyword.fetch!(opts, :birth_t), Keyword.get(opts, :partner_id)}],
      commissioning_date: Keyword.fetch!(opts, :commissioning_date),
      decommission_t: decommission_t(Keyword.fetch!(opts, :commissioning_date)),
      slot: Keyword.get(opts, :slot),
      phi1: 2.0 * :math.pi() * Rng.roll(noise_seed, {:phi, 1}),
      phi2: 2.0 * :math.pi() * Rng.roll(noise_seed, {:phi, 2}),
      birth_t: Keyword.fetch!(opts, :birth_t),
      death: nil
    }
  end

  @doc "Deterministic decommission time: commissioning + 730..1460 days."
  def decommission_t(%DateTime{} = commissioned) do
    days = 730 + :erlang.phash2(commissioned, 731)
    DateTime.to_unix(commissioned) + days * 86_400
  end

  defp seed_initial_segment(tl, origin, birth_t, env) do
    {status, tl} = draw_status(tl, origin, birth_t)
    append_status_block(tl, origin, birth_t, status, env)
  end

  ## Extension

  @doc """
  Extend a timeline so its horizon covers `until_t`.

  Returns `{[timeline], side_effects}`: the head is the (possibly tombstoned)
  original; the tail are newborn timelines from leaves/splits/dissolutions.
  Side effects are `{op, ..., at_t}` tuples the Observer executes when due.
  """
  def extend(%Timeline{tombstone_t: ts} = tl, _until_t, _env) when ts != nil, do: {[tl], []}

  def extend(%Timeline{} = tl, until_t, env) do
    do_extend(tl, until_t, env, [], [])
  end

  defp do_extend(%Timeline{} = tl, until_t, env, newborns, effects) do
    cond do
      tl.tombstone_t != nil or tl.horizon_t >= until_t ->
        {[tl | Enum.reverse(newborns)], Enum.reverse(effects)}

      true ->
        case due_event(tl) do
          {kind, _t} ->
            {tl, born, fx} = materialize(kind, tl, tl.horizon_t, env)
            do_extend(tl, until_t, env, born ++ newborns, Enum.reverse(fx) ++ effects)

          nil ->
            pos = end_position(tl)
            boundary = tl.horizon_t

            tl =
              if decommissioned_loner?(tl, boundary) do
                park(tl, pos, boundary, until_t)
              else
                {status, tl} = draw_status(tl, pos, boundary)
                append_status_block(tl, pos, boundary, status, env)
              end

            do_extend(tl, until_t, env, newborns, effects)
        end
    end
  end

  defp due_event(%Timeline{events: events, horizon_t: horizon}) do
    events
    |> Enum.filter(fn {_kind, t} -> t <= horizon end)
    |> Enum.min_by(fn {_kind, t} -> t end, fn -> nil end)
  end

  defp decommissioned_loner?(%Timeline{flock_id: nil, members: [m]}, t),
    do: m.decommission_t != nil and t >= m.decommission_t

  defp decommissioned_loner?(_tl, _t), do: false

  defp park(%Timeline{} = tl, pos, boundary, until_t) do
    seg = Segment.hold(pos, :maintenance, boundary, max(until_t, boundary) + 8 * 3600)
    %Timeline{tl | segments: tl.segments ++ [seg], horizon_t: seg.t1, events: %{}}
  end

  @doc "End position of the last planned segment."
  def end_position(%Timeline{segments: []}), do: raise("timeline has no segments")

  def end_position(%Timeline{segments: segments}) do
    case List.last(segments) do
      %Segment{kind: :hold, at: at} -> at
      %Segment{kind: :fly, to: to} -> to
    end
  end

  ## Status blocks

  # Day/night pick which pool DOMINATES, not which is exclusive: by day a
  # small fraction of units charges or sits in maintenance; at night just a
  # very small percentage is up. Two counter draws — one for the pool, one
  # for the status within it — keep this fully deterministic per seed.
  defp draw_status(%Timeline{} = tl, pos, t) do
    {u_pool, tl} = draw(tl)
    {u, tl} = draw(tl)

    pool =
      if night?(pos.lng, t) do
        if u_pool < @night_active_fraction, do: @active_statuses, else: @grounded_statuses
      else
        if u_pool < @day_grounded_fraction, do: @grounded_statuses, else: @active_statuses
      end

    {Enum.at(pool, trunc(u * length(pool))), tl}
  end

  defp append_status_block(%Timeline{} = tl, pos, t0, status, env)
       when status in [:charging, :maintenance, :surveillance, :simulating] do
    {dwell, tl} = draw_dwell(tl, status, env, pos, t0)
    seg = Segment.hold(pos, status, t0, t0 + dwell)
    %Timeline{tl | segments: tl.segments ++ [seg], horizon_t: seg.t1}
  end

  defp append_status_block(%Timeline{} = tl, pos, t0, :moving_to_new_target, env) do
    {min_m, max_m} = @moving_target_range
    {target, tl} = draw_target(tl, pos, min_m, max_m, env)
    append_leg(tl, pos, target, :moving_to_new_target, t0)
  end

  defp append_status_block(%Timeline{} = tl, pos, t0, status, env)
       when status in [:target_tracking, :aerial_surveillance] do
    {dwell, tl} = draw_dwell(tl, status, env)
    append_patrol_legs(tl, pos, t0, t0 + dwell, status, env)
  end

  defp append_patrol_legs(%Timeline{} = tl, pos, t, dwell_end, status, env) when t >= dwell_end do
    _ = {pos, status, env}
    tl
  end

  defp append_patrol_legs(%Timeline{} = tl, pos, t, dwell_end, status, env) do
    {min_m, max_m} = @patrol_leg_range
    {target, tl} = draw_target(tl, pos, min_m, max_m, env)
    tl = append_leg(tl, pos, target, status, t)
    append_patrol_legs(tl, target, tl.horizon_t, dwell_end, status, env)
  end

  defp append_leg(%Timeline{} = tl, from, to, status, t0) do
    {cruise, tl} = draw_with(tl, &Segment.draw_cruise_kmh(tl.seed, &1))
    seg = Segment.fly(from, to, status, t0, cruise)
    %Timeline{tl | segments: tl.segments ++ [seg], horizon_t: seg.t1}
  end

  defp draw_dwell(%Timeline{} = tl, status, env, pos, t) do
    windows =
      if status in @grounded_statuses and not night?(pos.lng, t),
        do: @day_grounded_dwell,
        else: @dwell

    {min_s, max_s} = Map.fetch!(windows, status)
    {u, tl} = draw(tl)
    {max((min_s + u * (max_s - min_s)) * env.dwell_scale, 1.0), tl}
  end

  defp draw_dwell(%Timeline{} = tl, status, env) do
    {min_s, max_s} = Map.fetch!(@dwell, status)
    {u, tl} = draw(tl)
    {max((min_s + u * (max_s - min_s)) * env.dwell_scale, 1.0), tl}
  end

  @doc false
  def draw_target(%Timeline{} = tl, pos, min_m, max_m, env) do
    {target, tl} = draw_target_in_disc(tl, pos, min_m, max_m, env, @target_attempts)
    reject_water(tl, target, pos, min_m, max_m, env, @water_attempts)
  end

  defp draw_target_in_disc(%Timeline{} = tl, pos, min_m, max_m, env, attempts_left) do
    {u_d, tl} = draw(tl)
    {u_b, tl} = draw(tl)
    distance = min_m + u_d * (max_m - min_m)
    bearing = 2.0 * :math.pi() * u_b
    candidate = Rng.offset(pos, distance * :math.cos(bearing), distance * :math.sin(bearing))

    cond do
      Segment.distance_m(candidate, env.center) <= env.tracking_radius_m ->
        {candidate, tl}

      attempts_left > 1 ->
        draw_target_in_disc(tl, pos, min_m, max_m, env, attempts_left - 1)

      true ->
        {pull_inside(env.center, candidate, env.tracking_radius_m), tl}
    end
  end

  defp pull_inside(center, candidate, radius_m) do
    {north, east} = Segment.metric_delta(center, candidate)
    norm = max(:math.sqrt(north * north + east * east), 1.0e-6)
    Rng.offset(center, north / norm * radius_m * 0.9, east / norm * radius_m * 0.9)
  end

  # TODO: Water must be a hard no-go. On retry exhaustion, retain a known-land
  # position or select a deterministic land fallback instead of returning target.
  defp reject_water(%Timeline{} = tl, target, _pos, _min, _max, _env, 0), do: {target, tl}

  defp reject_water(%Timeline{} = tl, target, pos, min_m, max_m, env, attempts_left) do
    if env.water_fun.(target) do
      {target2, tl} = draw_target_in_disc(tl, pos, min_m, max_m, env, @target_attempts)
      reject_water(tl, target2, pos, min_m, max_m, env, attempts_left - 1)
    else
      {target, tl}
    end
  end

  ## Events

  defp roll_all_events(%Timeline{flock_id: nil} = tl, from_t, env) do
    roll_event(tl, :departure, from_t, env)
  end

  defp roll_all_events(tl, from_t, env) do
    tl
    |> roll_event(:leave, from_t, env)
    |> roll_event(:split, from_t, env)
    |> roll_event(:bond_drop, from_t, env)
    |> roll_event(:bond_form, from_t, env)
  end

  defp roll_event(%Timeline{} = tl, kind, from_t, env) do
    case event_mean_s(kind, tl, env) do
      nil ->
        %Timeline{tl | events: Map.delete(tl.events, kind)}

      mean ->
        {u, tl} = draw(tl)
        %Timeline{tl | events: Map.put(tl.events, kind, from_t + Rng.exp(u, mean))}
    end
  end

  defp event_mean_s(:departure, _tl, env), do: env.rates.departure_mean_s

  defp event_mean_s(:leave, tl, env) do
    n = alive_count(tl)
    if n > 0, do: 1.0 / (env.rates.leave * n), else: nil
  end

  defp event_mean_s(:split, tl, env) do
    n = alive_count(tl)
    if n >= 6, do: 1.0 / (env.rates.split * n), else: nil
  end

  defp event_mean_s(:bond_drop, tl, env) do
    couples = couples_in(tl)
    if couples > 0, do: env.rates.bond_drop_mean_s / couples, else: nil
  end

  defp event_mean_s(:bond_form, tl, env) do
    singles = tl |> alive_members() |> Enum.count(&(Timeline.partner_at(&1, tl.horizon_t) == nil))
    if singles >= 2, do: env.rates.bond_form_mean_s / max(div(singles, 2), 1), else: nil
  end

  defp alive_members(%Timeline{members: members}) do
    Enum.reject(members, &(&1.death != nil))
  end

  defp alive_count(tl), do: length(alive_members(tl))

  defp couples_in(tl) do
    ids = MapSet.new(alive_members(tl), & &1.gsd_id)

    tl
    |> alive_members()
    |> Enum.count(fn m ->
      partner = Timeline.partner_at(m, tl.horizon_t)
      partner != nil and MapSet.member?(ids, partner) and m.gsd_id < partner
    end)
  end

  # --- materializations, all at boundary `tq` ---

  defp materialize(:leave, %Timeline{} = tl, tq, env) do
    case alive_members(tl) do
      [] ->
        {clear_and_reroll(tl, :leave, tq, env), [], []}

      alive ->
        {u, tl} = draw(tl)
        leaver = Enum.at(alive, trunc(u * length(alive)))
        pos = member_boundary_position(tl, leaver, tq)

        tl =
          update_member(tl, leaver.gsd_id, fn %Member{} = m -> %Member{m | death: {:left, tq}} end)

        {newborn, tl} = spawn_loner(tl, leaver, pos, tq, env)

        effects = [
          {:update_flock_ref, leaver.gsd_id, nil, tq},
          {:update_flock_count, tl.flock_id, length(alive) - 1, tq}
        ]

        {tl, dissolved, fx2} = check_validity(tl, tq, env)
        tl = reroll_after_change(tl, tq, env)
        {tl, [newborn | dissolved], effects ++ fx2}
    end
  end

  defp materialize(:split, %Timeline{} = tl, tq, env) do
    alive = alive_members(tl)
    keep_n = div(length(alive), 2)
    {keep, move} = Enum.split(alive, keep_n)

    if valid_flock?(keep, tq) and valid_flock?(move, tq) do
      origin = end_position(tl)
      {new_flock_id, tl} = draw_with(tl, &Rng.uuid(tl.seed, {:split, &1}))
      dead = Enum.filter(tl.members, &(&1.death != nil))

      moved_ids = MapSet.new(move, & &1.gsd_id)

      tl = %Timeline{tl | members: keep ++ dead}

      {angle0, tl} = draw(tl)

      new_members =
        move
        |> Enum.with_index()
        |> Enum.map(fn {%Member{} = m, i} ->
          %Member{
            m
            | birth_t: tq,
              slot: %{m.slot | index: i, n0: length(move), angle0: 2.0 * :math.pi() * angle0}
          }
        end)

      seed = :erlang.phash2({tl.seed, new_flock_id})
      newborn = new_flock(new_flock_id, new_flock_id, new_members, origin, tq, seed, env)

      effects =
        [
          {:insert_flock, new_flock_id, origin, length(move), tq},
          {:update_flock_count, tl.flock_id, length(keep), tq}
        ] ++
          Enum.map(moved_ids, &{:update_flock_ref, &1, new_flock_id, tq})

      {reroll_after_change(tl, tq, env), [newborn], effects}
    else
      {clear_and_reroll(tl, :split, tq, env), [], []}
    end
  end

  defp materialize(:bond_drop, %Timeline{} = tl, tq, env) do
    couples =
      tl
      |> alive_members()
      |> Enum.flat_map(fn m ->
        partner = Timeline.partner_at(m, tq)
        if partner != nil and m.gsd_id < partner, do: [{m.gsd_id, partner}], else: []
      end)

    case couples do
      [] ->
        {clear_and_reroll(tl, :bond_drop, tq, env), [], []}

      couples ->
        {u, tl} = draw(tl)
        {a, b} = Enum.at(couples, trunc(u * length(couples)))
        tl = drop_bond(tl, a, b, tq)

        effects = [{:update_partner, a, nil, tq}, {:update_partner, b, nil, tq}]
        {reroll_after_change(tl, tq, env), [], effects}
    end
  end

  defp materialize(:bond_form, %Timeline{} = tl, tq, env) do
    singles = tl |> alive_members() |> Enum.filter(&(Timeline.partner_at(&1, tq) == nil))

    case singles do
      [a, b | _] ->
        tl =
          tl
          |> update_member(a.gsd_id, &add_partner_interval(&1, tq, b.gsd_id))
          |> update_member(b.gsd_id, &add_partner_interval(&1, tq, a.gsd_id))

        effects = [
          {:update_partner, a.gsd_id, b.gsd_id, tq},
          {:update_partner, b.gsd_id, a.gsd_id, tq}
        ]

        {reroll_after_change(tl, tq, env), [], effects}

      _ ->
        {clear_and_reroll(tl, :bond_form, tq, env), [], []}
    end
  end

  defp materialize(:departure, %Timeline{members: [m]} = tl, tq, env) do
    pos = end_position(tl)
    {north, east} = Segment.metric_delta(env.center, pos)
    norm = :math.sqrt(north * north + east * east)

    # Sitting (almost) exactly at the center leaves the outward bearing
    # undefined; draw one instead of collapsing the exit leg to a point.
    {north, east, norm, tl} =
      if norm < 1.0 do
        {u, tl} = draw(tl)
        angle = 2.0 * :math.pi() * u
        {:math.cos(angle), :math.sin(angle), 1.0, tl}
      else
        {north, east, norm, tl}
      end

    exit_r = env.tracking_radius_m * 1.08
    target = Rng.offset(env.center, north / norm * exit_r, east / norm * exit_r)

    tl = append_leg(tl, pos, target, :moving_to_new_target, tq)
    leg = List.last(tl.segments)
    death_t = Segment.circle_crossing(leg, env.center, env.tracking_radius_m) || leg.t1

    tl =
      update_member(tl, m.gsd_id, fn %Member{} = mm -> %Member{mm | death: {:lost, death_t}} end)

    tl = %Timeline{tl | tombstone_t: death_t, events: %{}}

    {tl, [], [{:delete_gsd, m.gsd_id, death_t}]}
  end

  defp clear_and_reroll(%Timeline{} = tl, kind, tq, env) do
    roll_event(%Timeline{tl | events: Map.delete(tl.events, kind)}, kind, tq, env)
  end

  defp reroll_after_change(%Timeline{} = tl, tq, env), do: roll_all_events(tl, tq, env)

  defp check_validity(%Timeline{flock_id: nil} = tl, _tq, _env), do: {tl, [], []}

  defp check_validity(%Timeline{} = tl, tq, env) do
    alive = alive_members(tl)

    if valid_flock?(alive, tq) do
      {tl, [], []}
    else
      origin = end_position(tl)

      {newborns, %Timeline{} = tl, effects} =
        Enum.reduce(alive, {[], tl, []}, fn m, {born, %Timeline{} = tl, fx} ->
          pos = member_boundary_position(tl, m, tq)

          tl =
            update_member(tl, m.gsd_id, fn %Member{} = mm -> %Member{mm | death: {:left, tq}} end)

          {loner, tl} = spawn_loner(tl, m, pos, tq, env)
          {[loner | born], tl, [{:update_flock_ref, m.gsd_id, nil, tq} | fx]}
        end)

      _ = origin

      # A dissolved flock's row is deleted (not zeroed): every survivor's
      # flock_id is nil'ed at the same boundary, so nothing references it.
      effects = effects ++ [{:delete_flock, tl.flock_id, tq}]

      {%Timeline{tl | tombstone_t: tq, events: %{}}, newborns, effects}
    end
  end

  defp spawn_loner(%Timeline{} = tl, %Member{} = m, pos, tq, env) do
    loner_member = %Member{m | slot: nil, birth_t: tq, death: nil}
    seed = :erlang.phash2({tl.seed, m.gsd_id, tq})
    {new_loner(loner_member, pos, tq, seed, env), tl}
  end

  defp member_boundary_position(%Timeline{} = tl, %Member{} = m, tq) do
    base = end_position(tl)

    case m.slot do
      nil ->
        base

      slot ->
        {r_ground, _} = Timeline.slot_radii(slot)
        theta = 2.0 * :math.pi() * slot.index / slot.n0 + slot.angle0 + Timeline.omega_slot() * tq
        Rng.offset(base, r_ground * :math.cos(theta), r_ground * :math.sin(theta))
    end
  end

  defp drop_bond(%Timeline{} = tl, a, b, tq) do
    tl
    |> update_member(a, &add_partner_interval(&1, tq, nil))
    |> update_member(b, &add_partner_interval(&1, tq, nil))
  end

  defp add_partner_interval(%Member{partner: intervals} = m, tq, partner_id) do
    %Member{m | partner: intervals ++ [{tq, partner_id}]}
  end

  defp update_member(%Timeline{} = tl, gsd_id, fun) do
    members =
      Enum.map(tl.members, fn
        %Member{gsd_id: ^gsd_id} = m -> fun.(m)
        m -> m
      end)

    %Timeline{tl | members: members}
  end

  ## Counter-threaded draws

  defp draw(%Timeline{} = tl) do
    {Rng.roll(tl.seed, tl.counter), %Timeline{tl | counter: tl.counter + 1}}
  end

  defp draw_with(%Timeline{} = tl, fun) do
    {fun.(tl.counter), %Timeline{tl | counter: tl.counter + 1}}
  end
end
