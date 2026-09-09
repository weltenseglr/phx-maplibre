defmodule GsdTracker.Timeline.Segment do
  @moduledoc """
  The two timeline primitives: `hold` and `fly`.

  A hold is a stationary interval. A fly is a straight leg flown with a
  cosine-ramp trapezoid speed profile: speed ramps `0 → v_peak` over `ramp_s`
  as `v(t) = v_peak/2 · (1 − cos(πt/Tr))`, cruises, and ramps back down, so
  every fly begins and ends at speed 0 and segments are fully independent —
  position and speed are C⁰ across every boundary by construction.

  `a_max = 4.0 m/s²` matches real pigeon acceleration, so cruise is reached
  in seconds: the ramp's peak acceleration is exactly `a_max` by construction
  of the cosine profile (`v_peak · π / (2 · Tr) = a_max`, i.e.
  `Tr = π · v_peak / (2 · a_max)`) — 0 → 70 km/h in ≈ 7.6 s, and even the
  145 km/h ceiling in ≈ 15.8 s.

  Times are unix seconds (floats). Positions are `%{lat: _, lng: _}` degrees;
  leg math runs in the local equirectangular metric (1° lat = 111 320 m),
  which the whole app already assumes at ≤ 75 km scales.
  """

  alias GsdTracker.Timeline.Rng

  @a_max 4.0
  @lat_meters 111_320.0
  @min_speed_kmh 40.0
  @max_speed_kmh 145.0
  @cruise_speed_kmh 70.0
  @cruise_speed_sd_kmh 15.0

  defstruct [:kind, :t0, :t1, :status, :at, :from, :to, :length_m, :v_peak, :ramp_s]

  @type t :: %__MODULE__{}

  @doc "Maximum in-flight acceleration, m/s²."
  def a_max, do: @a_max

  @doc "A stationary interval at `at` with the given status."
  def hold(at, status, t0, t1) when t1 > t0 do
    %__MODULE__{kind: :hold, t0: t0, t1: t1, status: status, at: at}
  end

  @doc """
  A straight leg from `from` to `to` starting at `t0`.

  `v_peak_kmh` is the requested cruise speed (clamped to the legal envelope);
  short legs reduce the peak so the trapezoid degenerates gracefully into a
  pure ramp-up/ramp-down. `t1` falls out of the profile.
  """
  def fly(from, to, status, t0, v_peak_kmh) do
    length_m = max(distance_m(from, to), 1.0)
    v_req = clamp(v_peak_kmh, @min_speed_kmh, @max_speed_kmh) / 3.6

    ramp_t = :math.pi() * v_req / (2.0 * @a_max)
    ramp_d = v_req * ramp_t / 2.0

    {v_peak, ramp_s, duration} =
      if 2.0 * ramp_d <= length_m do
        {v_req, ramp_t, length_m / v_req + ramp_t}
      else
        v_short = :math.sqrt(2.0 * @a_max * length_m / :math.pi())
        {v_short, :math.pi() * v_short / (2.0 * @a_max), :math.pi() * v_short / @a_max}
      end

    %__MODULE__{
      kind: :fly,
      t0: t0,
      t1: t0 + duration,
      status: status,
      from: from,
      to: to,
      length_m: length_m,
      v_peak: v_peak,
      ramp_s: ramp_s
    }
  end

  @doc "Draw a cruise speed: `clamp(N(70, 15²), 40, 145)` km/h."
  def draw_cruise_kmh(seed, counter) do
    clamp(
      @cruise_speed_kmh +
        @cruise_speed_sd_kmh *
          Rng.gauss(Rng.roll(seed, {counter, :g1}), Rng.roll(seed, {counter, :g2})),
      @min_speed_kmh,
      @max_speed_kmh
    )
  end

  @doc "Arc length travelled at `t` (absolute), clamped to `[0, length_m]`."
  def d(%__MODULE__{kind: :hold}, _t), do: 0.0

  def d(%__MODULE__{kind: :fly} = seg, t) do
    tau = clamp(t - seg.t0, 0.0, seg.t1 - seg.t0)
    duration = seg.t1 - seg.t0
    ramp = seg.ramp_s

    cond do
      tau <= ramp -> ramp_distance(seg, tau)
      tau >= duration - ramp -> seg.length_m - ramp_distance(seg, duration - tau)
      true -> ramp_distance(seg, ramp) + seg.v_peak * (tau - ramp)
    end
  end

  defp ramp_distance(seg, tau) do
    seg.v_peak / 2.0 * (tau - seg.ramp_s / :math.pi() * :math.sin(:math.pi() * tau / seg.ramp_s))
  end

  @doc "Speed in m/s at `t` (absolute); 0 on holds and outside the segment."
  def v(%__MODULE__{kind: :hold}, _t), do: 0.0

  def v(%__MODULE__{kind: :fly} = seg, t) do
    tau = t - seg.t0
    duration = seg.t1 - seg.t0

    cond do
      tau <= 0.0 or tau >= duration -> 0.0
      tau <= seg.ramp_s -> seg.v_peak / 2.0 * (1.0 - :math.cos(:math.pi() * tau / seg.ramp_s))
      tau >= duration - seg.ramp_s -> v(seg, seg.t0 + (duration - tau))
      true -> seg.v_peak
    end
  end

  @doc "Base position at `t` (before noise/offsets), `%{lat:, lng:}`."
  def position(%__MODULE__{kind: :hold, at: at}, _t), do: at

  def position(%__MODULE__{kind: :fly} = seg, t) do
    frac = d(seg, t) / seg.length_m
    {north, east} = metric_delta(seg.from, seg.to)
    Rng.offset(seg.from, north * frac, east * frac)
  end

  @doc "Unit direction of a fly leg in metric space `%{lat:, lng:}`; zero map for holds."
  def track_unit(%__MODULE__{kind: :hold}), do: %{lat: 0.0, lng: 0.0}

  def track_unit(%__MODULE__{kind: :fly} = seg) do
    {north, east} = metric_delta(seg.from, seg.to)
    norm = max(:math.sqrt(north * north + east * east), 1.0e-9)
    %{lat: north / norm, lng: east / norm}
  end

  @doc "Unit normal (left of track) of a fly leg in metric space."
  def perp_unit(%__MODULE__{} = seg) do
    %{lat: n, lng: e} = track_unit(seg)
    %{lat: -e, lng: n}
  end

  @doc """
  Time at which a fly leg crosses distance `radius_m` from `center`, or `nil`.

  Position is linear in arc length, so the crossing is a quadratic in `s`;
  `t` is recovered by inverting `d(t)` (linear in the cruise phase, bisection
  through the ramps).

  Both vectors are expressed in the single tangent frame anchored at
  `seg.from` — the same frame `position/2` evaluates in — so the crossing is
  exact in the model's own metric (mixing frames anchored at different
  latitudes skews east distances by up to ~1 % at 75 km).
  """
  def circle_crossing(%__MODULE__{kind: :fly} = seg, center, radius_m) do
    {cn, ce} = metric_delta(seg.from, center)
    {pn, pe} = {-cn, -ce}
    {dn, de} = metric_delta(seg.from, seg.to)
    len = seg.length_m
    {un, ue} = {dn / len, de / len}

    a = 1.0
    b = 2.0 * (pn * un + pe * ue)
    c = pn * pn + pe * pe - radius_m * radius_m
    disc = b * b - 4.0 * a * c

    if disc < 0.0 do
      nil
    else
      sqrt_disc = :math.sqrt(disc)

      [(-b - sqrt_disc) / 2.0, (-b + sqrt_disc) / 2.0]
      |> Enum.filter(&(&1 >= 0.0 and &1 <= len))
      |> case do
        [] -> nil
        [s | _] -> time_at_distance(seg, s)
      end
    end
  end

  def circle_crossing(_segment, _center, _radius), do: nil

  @doc "Invert `d(t) = s` by bisection over the segment."
  def time_at_distance(%__MODULE__{kind: :fly} = seg, s) do
    bisect(seg, s, seg.t0, seg.t1, 40)
  end

  defp bisect(_seg, _s, lo, hi, 0), do: (lo + hi) / 2.0

  defp bisect(seg, s, lo, hi, n) do
    mid = (lo + hi) / 2.0
    if d(seg, mid) < s, do: bisect(seg, s, mid, hi, n - 1), else: bisect(seg, s, lo, mid, n - 1)
  end

  @doc "Equirectangular distance in meters."
  def distance_m(%{lat: lat1} = a, b) do
    {north, east} = metric_delta(a, b)
    _ = lat1
    :math.sqrt(north * north + east * east)
  end

  @doc "Metric `{north_m, east_m}` from `a` to `b`."
  def metric_delta(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    north = (lat2 - lat1) * @lat_meters
    east = (lng2 - lng1) * @lat_meters * :math.cos(lat1 * :math.pi() / 180.0)
    {north, east}
  end

  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)
end
