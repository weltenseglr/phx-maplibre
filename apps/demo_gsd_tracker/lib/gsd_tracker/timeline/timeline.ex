defmodule GsdTracker.Timeline do
  @moduledoc """
  A timeline: one immutable, seeded plan per flock, evaluated in closed form.

  The flock owns the trajectory (a contiguous list of `Segment`s); members are
  formation-slot offsets plus per-member lateral noise around it. A loner is
  the degenerate single-member timeline with `flock_id: nil` and no slot.
  Everything an observer — server or browser — needs to know about a unit at
  any time `t` is a pure function of this struct.

  Formation slots rotate slowly (one revolution per 15 minutes) at a radius
  that breathes with the segment's noise envelope: ≤ 8 m on the ground,
  ≤ 45 m in the air — the old cohesion radii hold by construction, with no
  correction passes. Couples occupy adjacent slots and share a noise phase,
  so they visibly fly together.

  Timelines live in the `#{inspect(__MODULE__)}.table()` ETS table owned by
  the Observer; `#{inspect(__MODULE__)}.index()` maps `gsd_id → timeline id`.
  """

  alias GsdTracker.Timeline.{Noise, Segment}

  @table :gsd_timelines
  @index :gsd_member_index

  @omega_slot 2.0 * :math.pi() / 900.0
  @lat_meters 111_320.0

  defmodule Member do
    @moduledoc false
    defstruct [
      :gsd_id,
      # ascending [{t_from, partner_id | nil}]
      :partner,
      :commissioning_date,
      # unix seconds; loners park permanently in :maintenance from here
      :decommission_t,
      # %{index:, n0:, angle0:, radius_scale:} | nil (loners)
      :slot,
      :phi1,
      :phi2,
      :birth_t,
      # nil | {:left, t} | {:lost, t}
      :death
    ]
  end

  defstruct [
    :id,
    :flock_id,
    :seed,
    :counter,
    :birth_t,
    :segments,
    :horizon_t,
    :members,
    # %{event_kind => next_fire_t}
    :events,
    :tombstone_t,
    distance_base_m: 0.0
  ]

  @type t :: %__MODULE__{}

  def table, do: @table
  def index, do: @index
  def omega_slot, do: @omega_slot

  @doc "Formation radii for a slot: `{r_ground_m, r_air_m}`."
  def slot_radii(%{radius_scale: scale}), do: {3.0 + 5.0 * scale, 10.0 + 35.0 * scale}

  @doc "The member's partner id at time `t` (interval-list lookup)."
  def partner_at(%Member{partner: intervals}, t) do
    intervals
    |> Enum.take_while(fn {from, _} -> from <= t end)
    |> List.last()
    |> case do
      {_, partner_id} -> partner_id
      nil -> nil
    end
  end

  @doc "Whether the member exists (born, not dead, timeline not tombstoned) at `t`."
  def alive?(%__MODULE__{} = tl, %Member{} = m, t) do
    born? = tl.birth_t <= t and m.birth_t <= t
    dead? = match?({_, death_t} when death_t <= t, m.death)
    tombstoned? = tl.tombstone_t != nil and tl.tombstone_t <= t
    born? and not dead? and not tombstoned?
  end

  @doc "The segment covering `t`, clamped to the first/last segment outside the plan."
  def segment_at(%__MODULE__{segments: segments}, t), do: segment_at(segments, t)

  def segment_at([first | _] = segments, t) when t < first.t0, do: hd(segments)

  def segment_at(segments, t) do
    Enum.find(segments, List.last(segments), fn seg -> t >= seg.t0 and t < seg.t1 end)
  end

  @doc """
  Flock-invariant evaluation context at `t`: the current segment resolved
  once, plus everything member evaluation shares — base position, speed,
  track/perp units, the airborne envelope, and the local east-meter scale.

  Members of the same timeline only differ by slot rotation, personal noise
  phases, and partner state, so `World` computes this once per timeline and
  hands it to `member_at/4` — the whole-fleet evaluation then does no
  per-member segment lookups, trapezoid evaluations, or unit-vector trig.
  """
  def eval_context(%__MODULE__{} = tl, t) do
    seg = segment_at(tl, t)
    v = Segment.v(seg, t)
    base = Segment.position(seg, t)

    airborne =
      case seg do
        %Segment{kind: :fly, t0: t0, t1: t1} -> Noise.envelope(t, t0, t1)
        _ -> 0.0
      end

    %{
      seg: seg,
      base: base,
      lng_meters: max(@lat_meters * :math.cos(base.lat * :math.pi() / 180.0), 1.0e-6),
      v: v,
      speed_kmh: Float.round(v * 3.6, 4),
      track: Segment.track_unit(seg),
      perp: Segment.perp_unit(seg),
      airborne: airborne
    }
  end

  @doc """
  Evaluate one member at `t`: the wire-position fields, or `nil` when the
  member is not alive at `t`.

  `member_at/3` builds the context itself (fine for single lookups);
  `member_at/4` takes a shared `eval_context/2` for whole-fleet passes.
  """
  def member_at(%__MODULE__{} = tl, %Member{} = m, t) do
    member_at(tl, m, t, eval_context(tl, t))
  end

  def member_at(%__MODULE__{} = tl, %Member{} = m, t, ctx) do
    if alive?(tl, m, t) do
      seg = ctx.seg
      decommissioned? = m.slot == nil and m.decommission_t != nil and t >= m.decommission_t

      {off_n, off_e} = slot_offset(m, ctx, t)
      {noise_n, noise_e, noise_v} = lateral_noise(m, seg, ctx.perp, t)

      v = if decommissioned?, do: 0.0, else: ctx.v
      status = if decommissioned?, do: :maintenance, else: seg.status

      %{
        gsd_id: m.gsd_id,
        lat: ctx.base.lat + (off_n + noise_n) / @lat_meters,
        lng: ctx.base.lng + (off_e + noise_e) / ctx.lng_meters,
        status: status,
        flock_id: tl.flock_id,
        partner_id: partner_at(m, t),
        speed_kmh: if(decommissioned?, do: 0.0, else: ctx.speed_kmh),
        movement_vector: movement_vector(ctx, v, noise_v, decommissioned?)
      }
    end
  end

  defp slot_offset(%Member{slot: nil}, _ctx, _t), do: {0.0, 0.0}

  defp slot_offset(%Member{slot: slot}, ctx, t) do
    {r_ground, r_air} = slot_radii(slot)
    r = r_ground + (r_air - r_ground) * ctx.airborne
    theta = 2.0 * :math.pi() * slot.index / slot.n0 + slot.angle0 + @omega_slot * t
    {r * :math.cos(theta), r * :math.sin(theta)}
  end

  defp lateral_noise(_m, %Segment{kind: :hold}, _perp, _t), do: {0.0, 0.0, 0.0}

  defp lateral_noise(%Member{phi1: phi1, phi2: phi2}, %Segment{kind: :fly} = seg, perp, t) do
    n = Noise.n(t, seg.t0, seg.t1, phi1, phi2)
    n_p = Noise.n_prime(t, seg.t0, seg.t1, phi1, phi2)
    {n * perp.lat, n * perp.lng, n_p}
  end

  defp movement_vector(_ctx, v, _noise_v, true) when v >= 0.0, do: %{lat: 0.0, lng: 0.0}

  defp movement_vector(%{seg: %Segment{kind: :hold}}, _v, _noise_v, _dec),
    do: %{lat: 0.0, lng: 0.0}

  defp movement_vector(ctx, v, noise_v, _decommissioned?) do
    north = v * ctx.track.lat + noise_v * ctx.perp.lat
    east = v * ctx.track.lng + noise_v * ctx.perp.lng
    norm = :math.sqrt(north * north + east * east)

    if norm < 1.0e-6 do
      %{lat: 0.0, lng: 0.0}
    else
      %{lat: north / norm, lng: east / norm}
    end
  end

  @doc "Total distance flown by the flock trajectory up to `t`, meters."
  def total_distance_m(%__MODULE__{} = tl, t) do
    tl.distance_base_m +
      Enum.reduce(tl.segments, 0.0, fn
        %Segment{kind: :fly} = seg, acc when seg.t0 < t -> acc + Segment.d(seg, t)
        _seg, acc -> acc
      end)
  end
end
