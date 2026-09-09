defmodule GsdTracker.TimelineTest do
  use ExUnit.Case, async: true

  alias GsdTracker.Timeline
  alias GsdTracker.Timeline.{Plan, Segment}

  @center %{lat: 52.52, lng: 13.405}
  @day_t DateTime.to_unix(~U[2026-09-09 10:00:00Z])

  @quiet_rates %{
    leave: 1.0e-12,
    split: 1.0e-12,
    bond_drop_mean_s: 1.0e12,
    bond_form_mean_s: 1.0e12,
    departure_mean_s: 1.0e12
  }

  defp env do
    Plan.env(
      center: @center,
      tracking_radius_m: 75_000.0,
      water_fun: fn _pos -> false end,
      rates: @quiet_rates
    )
  end

  defp flock_timeline(seed \\ 11) do
    members =
      [{"a", "b"}, {"b", "a"}, {"c", nil}, {"d", nil}]
      |> Enum.with_index()
      |> Enum.map(fn {{id, partner}, i} ->
        Plan.member(id,
          birth_t: @day_t,
          partner_id: partner,
          commissioning_date: ~U[2026-01-01 00:00:00Z],
          slot: %{index: i, n0: 4, angle0: 0.3, radius_scale: 0.5}
        )
      end)

    {[tl], _} =
      Plan.new_flock("f-1", "f-1", members, @center, @day_t, seed, env())
      |> Plan.extend(@day_t + 8 * 3_600, env())

    tl
  end

  test "member_at emits the full wire position shape" do
    tl = flock_timeline()
    [m | _] = tl.members

    pos = Timeline.member_at(tl, m, @day_t + 600)

    assert %{
             gsd_id: "a",
             lat: _lat,
             lng: _lng,
             status: status,
             flock_id: "f-1",
             partner_id: "b",
             speed_kmh: _speed,
             movement_vector: %{lat: _, lng: _}
           } = pos

    assert is_atom(status)
  end

  test "positions are continuous across every segment boundary" do
    tl = flock_timeline()
    [m | _] = tl.members

    for seg <- Enum.drop(tl.segments, 1) do
      before_pos = Timeline.member_at(tl, m, seg.t0 - 0.5)
      after_pos = Timeline.member_at(tl, m, seg.t0 + 0.5)

      moved =
        Segment.distance_m(
          %{lat: before_pos.lat, lng: before_pos.lng},
          %{lat: after_pos.lat, lng: after_pos.lng}
        )

      # v = 0 at boundaries; only slot rotation moves the point (< 1 m/s).
      assert moved < 5.0
    end
  end

  test "members stay within their formation radius of the flock base" do
    tl = flock_timeline()

    for m <- tl.members, k <- 0..40 do
      t = @day_t + k * 600
      seg = Timeline.segment_at(tl, t)
      base = Segment.position(seg, t)
      pos = Timeline.member_at(tl, m, t)

      distance = Segment.distance_m(base, %{lat: pos.lat, lng: pos.lng})
      # slot radius ≤ 45 m plus noise amplitude ≤ 13 m
      assert distance <= 60.0
    end
  end

  test "evaluation is idempotent" do
    tl = flock_timeline()
    [m | _] = tl.members
    t = @day_t + 3_600

    assert Timeline.member_at(tl, m, t) == Timeline.member_at(tl, m, t)
  end

  test "total distance is monotone in time" do
    tl = flock_timeline()

    distances = for k <- 0..16, do: Timeline.total_distance_m(tl, @day_t + k * 1_800)

    assert distances == Enum.sort(distances)
    assert List.last(distances) >= 0.0
  end
end
