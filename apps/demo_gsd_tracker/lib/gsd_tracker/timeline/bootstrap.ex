defmodule GsdTracker.Timeline.Bootstrap do
  @moduledoc """
  Seed a fresh fleet: wipe the population tables, create flock/GSD rows, and
  build the corresponding timelines.

  A boot seeds from scratch (TRUNCATE is constant-time regardless of history).
  Structure mirrors the tick-era bootstrap: ~85 % of units paired into
  couples, couples chunked into flocks of 3–10 members, the remainder loners;
  every flock (and every loner) gets one water-rejected spawn point on the
  30 km disc — the flock origin IS the trajectory origin, members ride
  formation offsets around it.
  """

  alias GsdTracker.Repo
  alias GsdTracker.Timeline.{Plan, Rng}

  @spawn_water_attempts 6

  @doc """
  Run the bootstrap. Returns `%{timelines: [Timeline.t()], total:, flocks:,
  loners:}`. `opts`: `:gsd_count`, `:world_seed`, `:now` (DateTime), plus
  anything `Plan.env/1` accepts.
  """
  def run(opts \\ []) do
    gsd_count =
      Keyword.get(opts, :gsd_count, Application.get_env(:demo_gsd_tracker, :gsd_count, 10_000))

    world_seed =
      Keyword.get(
        opts,
        :world_seed,
        Application.get_env(:demo_gsd_tracker, :world_seed) || :erlang.phash2(make_ref())
      )

    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    now_s = DateTime.to_unix(now)
    env = Plan.env(Keyword.get(opts, :env, []))

    Repo.query!("TRUNCATE gsd_stats, gsds, flocks")

    groups = build_groups(gsd_count, world_seed)
    flock_groups = Enum.filter(groups, &match?({:flock, _}, &1))

    flock_records = create_flock_rows(flock_groups, world_seed, env)
    seeds = number_seeds(groups, flock_records, world_seed)
    create_gsd_rows(seeds, now)
    persist_partner_bonds(seeds)

    timelines = build_timelines(seeds, flock_records, world_seed, now, now_s, env)

    loners = Enum.count(timelines, &is_nil(&1.flock_id))

    %{
      timelines: timelines,
      total: length(seeds),
      flocks: length(flock_records),
      loners: loners
    }
  end

  @doc "One water-rejected, area-uniform spawn point on the configured disc."
  def spawn_location(seed, counter, env),
    do: spawn_location(seed, counter, env, @spawn_water_attempts)

  defp spawn_location(seed, counter, env, attempts_left) do
    candidate =
      Rng.disc_point(
        env.center,
        env.spawn_radius_m,
        Rng.roll(seed, {counter, :r}),
        Rng.roll(seed, {counter, :theta})
      )

    if attempts_left > 1 and env.water_fun.(candidate) do
      spawn_location(seed, {counter, :retry}, env, attempts_left - 1)
    else
      # TODO: Water must be a hard no-go. On retry exhaustion, choose a known
      # land fallback instead of accepting this candidate when it is water.
      candidate
    end
  end

  # --- group structure: [{:flock, member_count} | {:loner, partner? boolean}] ---

  defp build_groups(gsd_count, world_seed) do
    couple_count = gsd_count |> Kernel.*(0.85) |> trunc() |> then(&(&1 - rem(&1, 2)))
    pair_count = div(couple_count, 2)

    {flocks, used_pairs} = chunk_flocks(pair_count, world_seed, 0, [], 0)
    leftover_pairs = pair_count - used_pairs
    singles = gsd_count - couple_count

    Enum.map(flocks, &{:flock, &1}) ++
      List.duplicate({:loner_pair}, leftover_pairs) ++
      List.duplicate({:loner}, singles)
  end

  # Chunk pairs into flocks of 3..10 MEMBERS (whole couples, so 4..10 even);
  # stop when fewer than two pairs remain.
  defp chunk_flocks(pairs_left, seed, i, acc, used) when pairs_left >= 2 do
    max_pairs = min(5, pairs_left)
    take = 2 + trunc(Rng.roll(seed, {:flock_size, i}) * max(max_pairs - 1, 1))
    take = min(take, pairs_left)
    chunk_flocks(pairs_left - take, seed, i + 1, [take * 2 | acc], used + take)
  end

  defp chunk_flocks(_pairs_left, _seed, _i, acc, used), do: {Enum.reverse(acc), used}

  # --- DB rows ---

  # Ids are generated deterministically from the world seed, so a pinned seed
  # yields a byte-identical world including its identifiers, and no positional
  # zip against database return order is ever needed.
  defp create_flock_rows(flock_groups, world_seed, env) do
    flocks =
      flock_groups
      |> Enum.with_index()
      |> Enum.map(fn {{:flock, member_count}, i} ->
        %{
          id: Rng.uuid(world_seed, {:flock, i}),
          member_count: member_count,
          origin: spawn_location(world_seed, {:flock_origin, i}, env)
        }
      end)

    insert_flocks(flocks)
    flocks
  end

  @doc "Insert flock rows (`%{id:, member_count:, origin: %{lat:, lng:}}`)."
  def insert_flocks(flocks) do
    rows =
      Enum.map(flocks, fn flock ->
        %{
          id: Ecto.UUID.dump!(flock.id),
          member_count: flock.member_count,
          center_location: %Geo.Point{
            coordinates: {flock.origin.lng, flock.origin.lat},
            srid: 4326
          }
        }
      end)

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all("flocks", &1))
  end

  # Expand groups into per-unit seed maps carrying flock/pair structure.
  defp number_seeds(groups, flock_records, world_seed) do
    {flock_groups, loner_groups} = Enum.split_with(groups, &match?({:flock, _}, &1))

    flock_seeds =
      flock_groups
      |> Enum.zip(flock_records)
      |> Enum.flat_map(fn {{:flock, member_count}, flock} ->
        Enum.map(0..(member_count - 1), fn i ->
          %{flock: flock, slot_index: i, pair_slot: div(i, 2), pair_side: rem(i, 2)}
        end)
      end)

    loner_seeds =
      loner_groups
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:loner_pair}, i} ->
          [
            %{flock: nil, loner_ref: {:pair, i, 0}},
            %{flock: nil, loner_ref: {:pair, i, 1}}
          ]

        {{:loner}, i} ->
          [%{flock: nil, loner_ref: {:single, i}}]
      end)

    Enum.with_index(flock_seeds ++ loner_seeds, fn seed, index ->
      seed
      |> Map.put(:index, index)
      |> Map.put(:gsd_id, Rng.uuid(world_seed, {:gsd, index}))
    end)
  end

  defp create_gsd_rows(seeds, now) do
    rows =
      Enum.map(seeds, fn seed ->
        origin = seed[:origin] || (seed.flock && seed.flock.origin) || %{lat: 52.52, lng: 13.405}

        gsd_row(seed.gsd_id, seed.flock && seed.flock.id, origin, now)
      end)

    insert_gsds(rows)
  end

  @doc "A gsds insert_all row (shared with the Observer's replenishment)."
  def gsd_row(gsd_id, flock_id, origin, %DateTime{} = now) do
    %{
      id: Ecto.UUID.dump!(gsd_id),
      commissioning_date: DateTime.to_naive(now),
      flock_id: flock_id && Ecto.UUID.dump!(flock_id),
      status: "surveillance",
      speed_kmh: Decimal.new(0),
      current_location: %Geo.Point{coordinates: {origin.lng, origin.lat}, srid: 4326}
    }
  end

  @doc "Insert prepared gsds rows in chunks."
  def insert_gsds(rows) do
    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all("gsds", &1))
  end

  # Partners: adjacent slots within a flock (couples were chunked in whole),
  # and the two halves of a loner pair.
  defp partner_pairs(seeds) do
    flock_pairs =
      seeds
      |> Enum.filter(& &1.flock)
      |> Enum.group_by(&{&1.flock.id, &1.pair_slot})
      |> Enum.flat_map(fn
        {_key, [a, b]} -> [{a.gsd_id, b.gsd_id}]
        {_key, _} -> []
      end)

    loner_pairs =
      seeds
      |> Enum.filter(&match?({:pair, _, _}, &1[:loner_ref]))
      |> Enum.group_by(fn %{loner_ref: {:pair, i, _}} -> i end)
      |> Enum.flat_map(fn
        {_i, [a, b]} -> [{a.gsd_id, b.gsd_id}]
        {_i, _} -> []
      end)

    flock_pairs ++ loner_pairs
  end

  defp persist_partner_bonds(seeds) do
    pairs =
      seeds
      |> partner_pairs()
      |> Enum.flat_map(fn {a, b} -> [{a, b}, {b, a}] end)

    pairs
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      {ids, partner_ids} =
        chunk
        |> Enum.map(fn {id, partner} -> {Ecto.UUID.dump!(id), Ecto.UUID.dump!(partner)} end)
        |> Enum.unzip()

      Repo.query!(
        """
        UPDATE gsds AS g
        SET partner_id = v.partner_id
        FROM (SELECT unnest($1::uuid[]) AS id, unnest($2::uuid[]) AS partner_id) AS v
        WHERE g.id = v.id
        """,
        [ids, partner_ids]
      )
    end)
  end

  # --- timelines ---

  defp build_timelines(seeds, _flock_records, world_seed, now, now_s, env) do
    partner_of =
      seeds |> partner_pairs() |> Enum.flat_map(fn {a, b} -> [{a, b}, {b, a}] end) |> Map.new()

    flock_timelines =
      seeds
      |> Enum.filter(& &1.flock)
      |> Enum.group_by(& &1.flock.id)
      |> Enum.map(fn {flock_id, members_seeds} ->
        flock = hd(members_seeds).flock
        n0 = length(members_seeds)
        angle0 = 2.0 * :math.pi() * Rng.roll(world_seed, {:angle0, flock_id})

        members =
          Enum.map(members_seeds, fn seed ->
            partner = partner_of[seed.gsd_id]

            Plan.member(seed.gsd_id,
              birth_t: now_s,
              partner_id: partner,
              commissioning_date: now,
              noise_seed: couple_noise_seed(world_seed, seed.gsd_id, partner),
              slot: %{
                index: seed.slot_index,
                n0: n0,
                angle0: angle0,
                radius_scale: Rng.roll(world_seed, {:radius, seed.gsd_id})
              }
            )
          end)

        Plan.new_flock(
          flock_id,
          flock_id,
          members,
          flock.origin,
          now_s,
          :erlang.phash2({world_seed, flock_id}),
          env
        )
      end)

    loner_timelines =
      seeds
      |> Enum.reject(& &1.flock)
      |> Enum.map(fn seed ->
        origin = spawn_location(world_seed, {:loner_origin, seed.index}, env)
        partner = partner_of[seed.gsd_id]

        member =
          Plan.member(seed.gsd_id,
            birth_t: now_s,
            partner_id: partner,
            commissioning_date: now,
            noise_seed: couple_noise_seed(world_seed, seed.gsd_id, partner)
          )

        Plan.new_loner(member, origin, now_s, :erlang.phash2({world_seed, seed.gsd_id}), env)
      end)

    flock_timelines ++ loner_timelines
  end

  defp couple_noise_seed(world_seed, gsd_id, nil), do: :erlang.phash2({world_seed, gsd_id})

  defp couple_noise_seed(world_seed, gsd_id, partner_id) do
    :erlang.phash2({world_seed, min(gsd_id, partner_id), max(gsd_id, partner_id)})
  end
end
