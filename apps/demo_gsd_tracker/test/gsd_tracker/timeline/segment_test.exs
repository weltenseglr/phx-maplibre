defmodule GsdTracker.Timeline.SegmentTest do
  use ExUnit.Case, async: true

  alias GsdTracker.Timeline.{Rng, Segment}

  @center %{lat: 52.52, lng: 13.405}

  defp random_leg(i) do
    to = Rng.disc_point(@center, 40_000.0, Rng.roll(i, :r), Rng.roll(i, :b))
    cruise = Segment.draw_cruise_kmh(i, :cruise)
    Segment.fly(@center, to, :moving_to_new_target, 1_000.0, cruise)
  end

  test "rng basics: rolls are uniform-ish, deterministic, and uuids are stable" do
    assert Rng.roll(1, 2) == Rng.roll(1, 2)
    assert Rng.roll(1, 2) != Rng.roll(1, 3)

    mean = Enum.sum(for i <- 1..2_000, do: Rng.roll(:seed, i)) / 2_000
    assert_in_delta mean, 0.5, 0.05

    uuid = Rng.uuid(:seed, 1)
    assert uuid == Rng.uuid(:seed, 1)
    assert {:ok, _} = Ecto.UUID.dump(uuid)
  end

  test "cruise speed draws are Gaussian around 70, clamped to [40, 145]" do
    samples = for i <- 1..2_000, do: Segment.draw_cruise_kmh(:speed_seed, i)

    assert Enum.all?(samples, &(&1 >= 40.0 and &1 <= 145.0))
    assert_in_delta Enum.sum(samples) / length(samples), 70.0, 2.0

    within_sigma = Enum.count(samples, &(&1 >= 55.0 and &1 <= 85.0)) / length(samples)
    assert within_sigma > 0.6 and within_sigma < 0.78
  end

  test "the fly profile starts and ends at v=0 and covers exactly the leg length" do
    for i <- 1..50 do
      seg = random_leg(i)

      assert Segment.v(seg, seg.t0) == 0.0
      assert Segment.v(seg, seg.t1) == 0.0
      assert_in_delta Segment.d(seg, seg.t1), seg.length_m, seg.length_m * 1.0e-6

      %{lat: lat, lng: lng} = Segment.position(seg, seg.t1)
      assert_in_delta lat, seg.to.lat, 1.0e-9
      assert_in_delta lng, seg.to.lng, 1.0e-9
    end
  end

  test "speed stays in the envelope with peak acceleration exactly a_max" do
    for i <- 1..30 do
      seg = random_leg(i)
      duration = seg.t1 - seg.t0
      steps = trunc(duration / 0.5)

      speeds = for k <- 0..steps, do: Segment.v(seg, seg.t0 + k * 0.5)
      assert Enum.all?(speeds, &(&1 >= 0.0 and &1 <= 145.0 / 3.6 + 1.0e-9))

      # The cosine ramp's peak acceleration is a_max by construction.
      assert_in_delta seg.v_peak * :math.pi() / (2.0 * seg.ramp_s), Segment.a_max(), 1.0e-9

      # Sampled acceleration never exceeds it.
      speeds
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert abs(b - a) / 0.5 <= Segment.a_max() * 1.01 end)
    end
  end

  test "cruise is reached from standstill in seconds" do
    far = Rng.offset(@center, 50_000.0, 0.0)

    # Tr = π·v/(2·a_max): peak acceleration pinned at a_max means the typical
    # cruise (70 km/h) takes ≈ 7.6 s and even the 145 km/h ceiling ≈ 15.8 s.
    for v_kmh <- [40.0, 70.0, 100.0, 145.0] do
      seg = Segment.fly(@center, far, :target_tracking, 0.0, v_kmh)
      assert_in_delta seg.ramp_s, :math.pi() * (v_kmh / 3.6) / (2.0 * Segment.a_max()), 1.0e-9
      assert seg.ramp_s <= 16.0
    end

    typical = Segment.fly(@center, far, :target_tracking, 0.0, 70.0)
    assert typical.ramp_s <= 8.0
  end

  test "short legs degrade to a pure ramp with reduced peak" do
    near = Rng.offset(@center, 120.0, 50.0)
    seg = Segment.fly(@center, near, :target_tracking, 0.0, 145.0)

    assert seg.v_peak < 145.0 / 3.6
    assert_in_delta seg.t1 - seg.t0, 2 * seg.ramp_s, 1.0e-6
    assert_in_delta Segment.d(seg, seg.t1), seg.length_m, 0.01
  end

  test "circle_crossing finds the exit time on an outbound leg" do
    target = Rng.offset(@center, 90_000.0, 0.0)
    seg = Segment.fly(@center, target, :moving_to_new_target, 0.0, 100.0)

    t_star = Segment.circle_crossing(seg, @center, 75_000.0)
    assert is_float(t_star)

    pos = Segment.position(seg, t_star)
    assert_in_delta Segment.distance_m(pos, @center), 75_000.0, 5.0

    assert Segment.circle_crossing(seg, @center, 200_000.0) == nil
  end
end
