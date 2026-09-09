defmodule GsdTracker.Timeline.World do
  @moduledoc """
  Sample the whole world at one instant.

  `evaluate/2` folds the timeline table ONCE: per timeline it resolves the
  shared `Timeline.eval_context/2` (segment, base position, speed, unit
  vectors, envelope), then evaluates each member against it, accumulating the
  positions list AND all sidebar statistics in the same pass — no second
  aggregation sweep over the fleet. The emitted position and stats shapes are
  the frozen `"gsd_updates"` wire contract.
  """

  alias GsdTracker.Timeline

  @ground_states [:maintenance, :charging, :surveillance, :simulating]
  @flight_states [:target_tracking, :aerial_surveillance, :moving_to_new_target]
  @zero_counts Map.new(@ground_states ++ @flight_states, &{&1, 0})

  @doc """
  Evaluate all timelines at unix-seconds `t`.

  Returns `{positions, stats}` where each position is
  `%{gsd_id, lat, lng, status, flock_id, partner_id, speed_kmh,
  movement_vector, last_update_at}` and stats carries the sidebar aggregates.
  The live population count is `stats.total` (every emitted position is a
  live member).
  """
  def at(t, %DateTime{} = last_update_at) do
    {positions, acc} =
      :ets.foldl(
        fn {_id, tl}, {pos_acc, stats_acc} ->
          ctx = Timeline.eval_context(tl, t)

          Enum.reduce(tl.members, {pos_acc, stats_acc}, fn m, {pa, sa} ->
            case Timeline.member_at(tl, m, t, ctx) do
              nil -> {pa, sa}
              pos -> {[Map.put(pos, :last_update_at, last_update_at) | pa], count(sa, pos)}
            end
          end)
        end,
        {[], new_acc()},
        Timeline.table()
      )

    {positions, finalize(acc)}
  end

  @doc "Aggregate stats over a positions list (the frozen sidebar shape), one pass."
  def stats(positions) do
    positions
    |> Enum.reduce(new_acc(), &count(&2, &1))
    |> finalize()
  end

  @doc "Number of live members across all timelines at `t`."
  def live_count(t) do
    :ets.foldl(
      fn {_id, tl}, acc -> acc + Enum.count(tl.members, &Timeline.alive?(tl, &1, t)) end,
      0,
      Timeline.table()
    )
  end

  ## Single-pass stats accumulator

  defp new_acc do
    %{total: 0, by_status: @zero_counts, flock_sizes: %{}, couple_keys: MapSet.new()}
  end

  defp count(acc, pos) do
    %{
      total: acc.total + 1,
      by_status: Map.update(acc.by_status, pos.status, 1, &(&1 + 1)),
      flock_sizes:
        case pos.flock_id do
          nil -> acc.flock_sizes
          flock_id -> Map.update(acc.flock_sizes, flock_id, 1, &(&1 + 1))
        end,
      # A couple is a pair, not two partnered individuals: unordered unique
      # keys. A dangling bond still counts as one couple.
      couple_keys:
        case pos.partner_id do
          nil ->
            acc.couple_keys

          partner_id ->
            key =
              if pos.gsd_id <= partner_id,
                do: {pos.gsd_id, partner_id},
                else: {partner_id, pos.gsd_id}

            MapSet.put(acc.couple_keys, key)
        end
    }
  end

  defp finalize(acc) do
    sizes = Map.values(acc.flock_sizes)

    %{
      total: acc.total,
      couples: MapSet.size(acc.couple_keys),
      flocks: length(sizes),
      largest_flock: Enum.max(sizes, fn -> 0 end),
      smallest_flock: Enum.min(sizes, fn -> 0 end),
      avg_flock_size: average(sizes),
      by_state: %{
        ground: Map.take(acc.by_status, @ground_states),
        flight: Map.take(acc.by_status, @flight_states)
      }
    }
  end

  defp average([]), do: 0.0
  defp average(sizes), do: Float.round(Enum.sum(sizes) / length(sizes), 2)
end
