defmodule GsdTracker.Timeline.Noise do
  @moduledoc """
  Band-limited lateral weave applied to fly segments.

      n(t) = e(t) · [A₁·sin(ω₁·t + φ₁) + A₂·sin(ω₂·t + φ₂)]   (meters)

  with `A₁ = 8`, `A₂ = 5`, `ω₁ = 2π/90`, `ω₂ = √2·ω₁` (irrational ratio, so
  the weave never repeats) and a smoothstep envelope `e` rising 0→1 over 20 s
  at each end of the segment, so waypoints are hit exactly.

  ## Acceleration bound (why the g-limit is a theorem, not a sample)

  The base leg is straight, so `|n''|` is the entire lateral acceleration:

      |n''| ≤ ΣAᵢωᵢ² + 2·e'ₘₐₓ·ΣAᵢωᵢ + e''ₘₐₓ·ΣAᵢ
            ≤ 0.088  + 0.158          + 0.195         = 0.44 m/s² ≈ 0.045 g

  (`e'ₘₐₓ = 1.5/20`, `e''ₘₐₓ = 6/20²` for a smoothstep over 20 s.) Heading
  deviation rate is `|n''|/v`: ≈ 2.3°/s at the 40 km/h minimum cruise —
  under 12° per 5 s, inside the legacy 15°-per-tick clamp.
  """

  @a1 8.0
  @a2 5.0
  @omega1 2.0 * :math.pi() / 90.0
  @omega2 :math.sqrt(2.0) * 2.0 * :math.pi() / 90.0
  @envelope_s 20.0

  @doc "The wire 7-tuple `[a1, a2, omega1, omega2, phi1, phi2, envelope_s]`."
  def params(phi1, phi2), do: [@a1, @a2, @omega1, @omega2, phi1, phi2, @envelope_s]

  @doc "Analytic upper bound on `|n''|` in m/s² (documented arithmetic above)."
  def accel_bound do
    e1 = 1.5 / @envelope_s
    e2 = 6.0 / (@envelope_s * @envelope_s)

    @a1 * @omega1 * @omega1 + @a2 * @omega2 * @omega2 +
      2.0 * e1 * (@a1 * @omega1 + @a2 * @omega2) +
      e2 * (@a1 + @a2)
  end

  @doc "Lateral displacement in meters at absolute time `t` within `[t0, t1]`."
  def n(t, t0, t1, phi1, phi2) do
    envelope(t, t0, t1) *
      (@a1 * :math.sin(@omega1 * t + phi1) + @a2 * :math.sin(@omega2 * t + phi2))
  end

  @doc "Lateral velocity `n'(t)` in m/s (product rule; used for the wire vector)."
  def n_prime(t, t0, t1, phi1, phi2) do
    e = envelope(t, t0, t1)
    e_p = envelope_prime(t, t0, t1)
    s = @a1 * :math.sin(@omega1 * t + phi1) + @a2 * :math.sin(@omega2 * t + phi2)

    s_p =
      @a1 * @omega1 * :math.cos(@omega1 * t + phi1) +
        @a2 * @omega2 * :math.cos(@omega2 * t + phi2)

    e_p * s + e * s_p
  end

  @doc "Smoothstep envelope: 0 at the segment ends, 1 in the middle."
  def envelope(t, t0, t1) do
    te = min(@envelope_s, (t1 - t0) / 2.0)
    up = smoothstep((t - t0) / te)
    down = smoothstep((t1 - t) / te)
    min(up, down)
  end

  defp envelope_prime(t, t0, t1) do
    te = min(@envelope_s, (t1 - t0) / 2.0)

    cond do
      t - t0 < te -> smoothstep_prime((t - t0) / te) / te
      t1 - t < te -> -smoothstep_prime((t1 - t) / te) / te
      true -> 0.0
    end
  end

  defp smoothstep(u) when u <= 0.0, do: 0.0
  defp smoothstep(u) when u >= 1.0, do: 1.0
  defp smoothstep(u), do: u * u * (3.0 - 2.0 * u)

  defp smoothstep_prime(u) when u <= 0.0 or u >= 1.0, do: 0.0
  defp smoothstep_prime(u), do: 6.0 * u * (1.0 - u)
end
