defmodule GsdTracker.Timeline.NoiseTest do
  use ExUnit.Case, async: true

  alias GsdTracker.Timeline.Noise

  test "the analytic lateral-acceleration bound stays under 0.1 g" do
    assert Noise.accel_bound() <= 0.1 * 9.81
  end

  test "numerically sampled |n''| respects the analytic bound" do
    bound = Noise.accel_bound()
    {t0, t1} = {0.0, 600.0}
    h = 0.05

    for phi1 <- [0.3, 2.1, 4.4], phi2 <- [1.1, 3.7], k <- 0..1_200 do
      t = t0 + k * 0.5

      n2 =
        (Noise.n(t + h, t0, t1, phi1, phi2) - 2 * Noise.n(t, t0, t1, phi1, phi2) +
           Noise.n(t - h, t0, t1, phi1, phi2)) / (h * h)

      assert abs(n2) <= bound * 1.05
    end
  end

  test "noise vanishes at the segment ends so waypoints are hit exactly" do
    assert Noise.n(0.0, 0.0, 300.0, 1.0, 2.0) == 0.0
    assert Noise.n(300.0, 0.0, 300.0, 1.0, 2.0) == 0.0
    assert abs(Noise.n(150.0, 0.0, 300.0, 1.0, 2.0)) <= 13.0
  end

  test "n_prime matches a finite-difference derivative" do
    {t0, t1} = {0.0, 400.0}
    h = 0.001

    for t <- [10.0, 50.0, 200.0, 390.0] do
      numeric = (Noise.n(t + h, t0, t1, 0.7, 1.9) - Noise.n(t - h, t0, t1, 0.7, 1.9)) / (2 * h)
      assert_in_delta Noise.n_prime(t, t0, t1, 0.7, 1.9), numeric, 1.0e-3
    end
  end

  test "the wire params tuple has the documented arity and order" do
    assert [8.0, 5.0, w1, w2, 0.5, 1.5, 20.0] = Noise.params(0.5, 1.5)
    assert_in_delta w2 / w1, :math.sqrt(2.0), 1.0e-9
  end
end
