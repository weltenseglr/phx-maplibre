defmodule GsdTracker.Timeline.WorldTest do
  use ExUnit.Case, async: true

  alias GsdTracker.Timeline.World

  defp position(id, overrides \\ []) do
    Map.merge(
      %{
        gsd_id: id,
        lat: 52.52,
        lng: 13.405,
        status: :surveillance,
        flock_id: nil,
        partner_id: nil,
        speed_kmh: 0.0,
        movement_vector: %{lat: 0.0, lng: 0.0}
      },
      Map.new(overrides)
    )
  end

  test "stats carries the exact frozen sidebar shape" do
    stats = World.stats([position("a")])

    assert %{
             total: 1,
             couples: 0,
             flocks: 0,
             largest_flock: 0,
             smallest_flock: 0,
             avg_flock_size: avg_flock_size,
             by_state: %{
               ground: %{maintenance: _, charging: _, surveillance: _, simulating: _},
               flight: %{target_tracking: _, aerial_surveillance: _, moving_to_new_target: _}
             }
           } = stats

    assert map_size(stats) == 7
    assert avg_flock_size == 0.0
    assert map_size(stats.by_state.ground) == 4
    assert map_size(stats.by_state.flight) == 3
  end

  test "a couple is one pair, counted once regardless of direction" do
    positions = [
      position("a", partner_id: "b"),
      position("b", partner_id: "a"),
      # a dangling bond still counts as one couple
      position("c", partner_id: "ghost"),
      position("d")
    ]

    assert World.stats(positions).couples == 2
  end

  test "flock aggregates ignore loners and average over flocks only" do
    positions =
      Enum.map(1..4, &position("f#{&1}", flock_id: "F1")) ++
        Enum.map(1..6, &position("g#{&1}", flock_id: "F2")) ++
        [position("loner")]

    stats = World.stats(positions)

    assert stats.total == 11
    assert stats.flocks == 2
    assert stats.largest_flock == 6
    assert stats.smallest_flock == 4
    assert stats.avg_flock_size == 5.0
  end

  test "by_state buckets every status correctly" do
    positions = [
      position("a", status: :charging),
      position("b", status: :charging),
      position("c", status: :target_tracking),
      position("d", status: :moving_to_new_target)
    ]

    stats = World.stats(positions)

    assert stats.by_state.ground.charging == 2
    assert stats.by_state.ground.surveillance == 0
    assert stats.by_state.flight.target_tracking == 1
    assert stats.by_state.flight.moving_to_new_target == 1
    assert stats.by_state.flight.aerial_surveillance == 0
  end

  test "empty world produces zeroed stats" do
    stats = World.stats([])

    assert stats.total == 0
    assert stats.couples == 0
    assert stats.flocks == 0
    assert stats.avg_flock_size == 0.0
  end
end
