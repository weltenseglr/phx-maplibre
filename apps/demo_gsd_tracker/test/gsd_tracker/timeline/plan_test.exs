defmodule GsdTracker.Timeline.PlanTest do
  use ExUnit.Case, async: true

  alias GsdTracker.Timeline
  alias GsdTracker.Timeline.{Plan, Segment}

  @center %{lat: 52.52, lng: 13.405}
  # 10:00 UTC at lng 13.405 → solar hour 10, daytime.
  @day_t DateTime.to_unix(~U[2026-09-09 10:00:00Z])
  # 23:00 UTC → solar hour 23, night.
  @night_t DateTime.to_unix(~U[2026-09-09 23:00:00Z])

  @quiet_rates %{
    leave: 1.0e-12,
    split: 1.0e-12,
    bond_drop_mean_s: 1.0e12,
    bond_form_mean_s: 1.0e12,
    departure_mean_s: 1.0e12
  }

  defp env(overrides \\ []) do
    Plan.env(
      Keyword.merge(
        [
          center: @center,
          spawn_radius_m: 30_000.0,
          tracking_radius_m: 75_000.0,
          dwell_scale: 1.0,
          water_fun: fn _pos -> false end,
          rates: @quiet_rates
        ],
        overrides
      )
    )
  end

  defp commissioned, do: ~U[2026-01-01 00:00:00Z]

  defp member(id, opts) do
    Plan.member(
      id,
      Keyword.merge(
        [birth_t: @day_t, commissioning_date: commissioned(), partner_id: nil],
        opts
      )
    )
  end

  defp slot(index, n0), do: %{index: index, n0: n0, angle0: 0.0, radius_scale: 0.5}

  defp flock(ids, opts) do
    n0 = length(ids)

    members =
      ids
      |> Enum.with_index()
      |> Enum.map(fn {{id, partner}, i} -> member(id, partner_id: partner, slot: slot(i, n0)) end)

    Plan.new_flock(
      "flock-1",
      "flock-1",
      members,
      @center,
      Keyword.get(opts, :birth_t, @day_t),
      Keyword.get(opts, :seed, 42),
      env(Keyword.get(opts, :env, []))
    )
  end

  defp loner(id, opts \\ []) do
    Plan.new_loner(
      member(id, Keyword.take(opts, [:partner_id])),
      @center,
      Keyword.get(opts, :birth_t, @day_t),
      Keyword.get(opts, :seed, 7),
      env(Keyword.get(opts, :env, []))
    )
  end

  test "extension is a prefix-stable deterministic unfold" do
    tl = loner("u-1")
    e = env()

    {[step1], []} = Plan.extend(tl, @day_t + 3_600, e)
    {[via_step], []} = Plan.extend(step1, @day_t + 14_400, e)
    {[direct], []} = Plan.extend(tl, @day_t + 14_400, e)

    assert via_step.segments == direct.segments
    assert via_step.counter == direct.counter
    assert via_step.events == direct.events
  end

  test "identical seeds unfold into identical plans" do
    {[a], []} = Plan.extend(loner("u-1", seed: 99), @day_t + 86_400, env())
    {[b], []} = Plan.extend(loner("u-1", seed: 99), @day_t + 86_400, env())
    assert a.segments == b.segments
  end

  test "hold durations respect the per-status dwell windows" do
    {[tl], []} = Plan.extend(loner("u-dwell"), @day_t + 6 * 3_600, env())

    for %Segment{kind: :hold} = seg <- tl.segments do
      windows =
        if seg.status in Plan.grounded_statuses() and not Plan.night?(@center.lng, seg.t0),
          do: Plan.day_grounded_dwell_windows(),
          else: Plan.dwell_windows()

      {min_s, max_s} = Map.fetch!(windows, seg.status)
      duration = seg.t1 - seg.t0
      # The final parked-maintenance hold of a decommissioned unit is exempt;
      # none applies here (commissioning is recent).
      assert duration >= min_s - 1.0e-6
      assert duration <= max_s + 1.0e-6
    end
  end

  test "night is mostly grounded and day mostly active — statistically" do
    day_statuses =
      for seed <- 1..800, do: hd(loner("d#{seed}", seed: seed).segments).status

    night_statuses =
      for seed <- 1..800, do: hd(loner("n#{seed}", seed: seed, birth_t: @night_t).segments).status

    day_grounded = Enum.count(day_statuses, &(&1 in Plan.grounded_statuses())) / 800
    night_active = Enum.count(night_statuses, &(&1 in Plan.active_statuses())) / 800

    # ~10 % grounded by day, ~3 % active at night (800 fixed seeds each, so
    # these shares are deterministic — the bands allow for the sample noise
    # of this particular seed set).
    assert day_grounded >= 0.05 and day_grounded <= 0.15
    assert night_active >= 0.005 and night_active <= 0.06
  end

  test "the status-pool draw is the documented deterministic function of the seed" do
    for seed <- [1, 2, 3, 42, 99, 1234] do
      # The pool draw is the timeline's very first counter roll.
      u_pool = GsdTracker.Timeline.Rng.roll(seed, 0)

      day_status = hd(loner("sd#{seed}", seed: seed).segments).status

      expected_day_pool =
        if u_pool < Plan.day_grounded_fraction(),
          do: Plan.grounded_statuses(),
          else: Plan.active_statuses()

      assert day_status in expected_day_pool

      night_status = hd(loner("sn#{seed}", seed: seed, birth_t: @night_t).segments).status

      expected_night_pool =
        if u_pool < Plan.night_active_fraction(),
          do: Plan.active_statuses(),
          else: Plan.grounded_statuses()

      assert night_status in expected_night_pool
    end
  end

  test "every fly waypoint stays inside the tracking radius" do
    {[tl], []} = Plan.extend(loner("u-disc", seed: 3), @day_t + 2 * 86_400, env())

    for %Segment{kind: :fly} = seg <- tl.segments do
      assert Segment.distance_m(seg.to, @center) <= 75_000.0 + 1.0
    end
  end

  test "a doomed flock dissolves into loners and stays valid until then" do
    tl = flock([{"a", "b"}, {"b", "a"}, {"c", nil}], env: [rates: %{@quiet_rates | leave: 0.05}])

    {[head | newborns], effects} =
      # A due event is materialized at a status boundary. Daytime charging can
      # now span up to three hours, so a one-day horizon keeps this lifecycle
      # test independent of the initial status draw.
      Plan.extend(tl, @day_t + 86_400, env(rates: %{@quiet_rates | leave: 0.05}))

    assert head.tombstone_t != nil
    assert length(newborns) >= 1
    assert Enum.all?(newborns, &(&1.flock_id == nil))
    assert Enum.any?(effects, &match?({:update_flock_ref, _, nil, _}, &1))
    # Members leaving before the dissolution shrink the persisted count; the
    # dissolution itself deletes the row once every reference is nil'ed.
    assert Enum.any?(effects, &match?({:update_flock_count, "flock-1", _, _}, &1))
    assert Enum.any?(effects, &match?({:delete_flock, "flock-1", _}, &1))

    # Everyone who ever lived is accounted for: dead in the flock, alive as loners.
    newborn_ids = newborns |> Enum.flat_map(& &1.members) |> Enum.map(& &1.gsd_id) |> Enum.sort()

    dead_ids =
      head.members |> Enum.filter(&(&1.death != nil)) |> Enum.map(& &1.gsd_id) |> Enum.sort()

    assert newborn_ids == dead_ids
  end

  test "splits produce two valid flocks and the row-insert side effect" do
    ids = for i <- 1..8, do: {"m#{i}", if(rem(i, 2) == 1, do: "m#{i + 1}", else: "m#{i - 1}")}
    rates = %{@quiet_rates | split: 0.05}
    tl = flock(ids, env: [rates: rates])

    {[head | newborns], effects} = Plan.extend(tl, @day_t + 7_200, env(rates: rates))

    split_flocks = Enum.filter(newborns, &(&1.flock_id != nil))
    assert split_flocks != []

    for newborn <- split_flocks do
      alive = Enum.reject(newborn.members, &(&1.death != nil))
      assert Plan.valid_flock?(alive, newborn.birth_t)

      # The row insert carries the new flock's actual half size.
      newborn_id = newborn.flock_id

      assert {:insert_flock, ^newborn_id, _origin, member_count, _t} =
               Enum.find(effects, &match?({:insert_flock, ^newborn_id, _, _, _}, &1))

      assert member_count == length(alive)
    end

    # The old flock's persisted count shrinks in the same boundary batch.
    assert Enum.any?(effects, &match?({:update_flock_count, "flock-1", _, _}, &1))

    alive_head = Enum.reject(head.members, &(&1.death != nil))
    assert head.tombstone_t != nil or Plan.valid_flock?(alive_head, head.horizon_t)
  end

  test "a departing loner is tombstoned exactly at the tracking radius" do
    rates = %{@quiet_rates | departure_mean_s: 30.0}
    tl = loner("u-gone", env: [rates: rates])

    {[tl], effects} = Plan.extend(tl, @day_t + 4 * 3_600, env(rates: rates))

    assert tl.tombstone_t != nil

    assert [{:delete_gsd, "u-gone", death_t}] =
             Enum.filter(effects, &match?({:delete_gsd, _, _}, &1))

    [m] = tl.members
    assert {:lost, ^death_t} = m.death

    exit_seg = Enum.find(tl.segments, fn seg -> seg.t0 <= death_t and death_t <= seg.t1 end)
    pos = Segment.position(exit_seg, death_t)

    # Measure in the tangent frame anchored at the leg origin — the same
    # frame circle_crossing solves in and position/2 evaluates in — so the
    # only error left is the d(t) bisection, far below 50 m.
    {cn, ce} = Segment.metric_delta(exit_seg.from, @center)
    {pn, pe} = Segment.metric_delta(exit_seg.from, pos)
    radius = :math.sqrt((pn - cn) * (pn - cn) + (pe - ce) * (pe - ce))
    assert_in_delta radius, 75_000.0, 50.0
  end

  test "a decommissioned loner parks in permanent maintenance" do
    old = ~U[2020-01-01 00:00:00Z]
    m = Plan.member("u-old", birth_t: @day_t, commissioning_date: old, partner_id: nil)
    assert m.decommission_t < @day_t

    tl = Plan.new_loner(m, @center, @day_t, 5, env())
    {[tl], []} = Plan.extend(tl, @day_t + 86_400, env())

    # The initial status block may span several segments; everything planned
    # after it is a permanent maintenance hold.
    parked =
      Enum.drop_while(tl.segments, &(!(&1.kind == :hold and &1.status == :maintenance)))

    assert parked != []
    assert Enum.all?(parked, &(&1.kind == :hold and &1.status == :maintenance))
    assert List.last(parked).t1 >= @day_t + 86_400

    [mm] = tl.members
    pos = Timeline.member_at(tl, mm, @day_t + 43_200)
    assert pos.status == :maintenance
    assert pos.speed_kmh == 0.0
  end

  test "bond drops sever both sides and emit partner updates" do
    rates = %{@quiet_rates | bond_drop_mean_s: 60.0}
    ids = [{"a", "b"}, {"b", "a"}, {"c", "d"}, {"d", "c"}]
    tl = flock(ids, env: [rates: rates])

    {[tl | _], effects} = Plan.extend(tl, @day_t + 7_200, env(rates: rates))

    dropped = Enum.filter(effects, &match?({:update_partner, _, nil, _}, &1))
    assert length(dropped) >= 2

    {:update_partner, a, nil, tq} = hd(dropped)
    dropped_member = Enum.find(tl.members, &(&1.gsd_id == a))
    assert Timeline.partner_at(dropped_member, tq + 1) == nil
  end
end
