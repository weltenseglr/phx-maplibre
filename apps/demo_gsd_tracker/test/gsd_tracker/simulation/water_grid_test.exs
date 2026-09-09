defmodule GsdTracker.Simulation.WaterGridTest do
  use ExUnit.Case, async: false

  alias GsdTracker.Simulation.WaterGrid

  setup do
    WaterGrid.ensure_table()
    WaterGrid.clear()
    :ok
  end

  describe "ensure_table/0" do
    test "is idempotent and returns the named table" do
      assert WaterGrid.table() == WaterGrid.ensure_table()
      assert WaterGrid.table() == WaterGrid.ensure_table()
      refute :ets.whereis(WaterGrid.table()) == :undefined
    end

    test "the table is owned by the long-lived simulation supervisor" do
      owner = :ets.info(WaterGrid.table(), :owner)

      assert owner == Process.whereis(GsdTracker.Timeline.Observer)

      # The cache therefore outlives every caller that merely reads it.
      task = Task.async(fn -> WaterGrid.ensure_table() end)
      assert WaterGrid.table() == Task.await(task)
      assert :ets.info(WaterGrid.table(), :owner) == owner
    end
  end

  describe "cell_key/2" do
    test "snaps coordinates within the same grid cell to one key" do
      assert WaterGrid.cell_key(52.5200123, 13.4050456) ==
               WaterGrid.cell_key(52.5200456, 13.4050123)

      refute WaterGrid.cell_key(52.5200, 13.4050) == WaterGrid.cell_key(52.5300, 13.4050)
    end
  end

  describe "water?/1" do
    test "answers from the cache without touching the database" do
      key = WaterGrid.cell_key(52.5200123, 13.4050456)
      :ets.insert(WaterGrid.table(), {key, true})

      assert WaterGrid.water?(%{lat: 52.5200123, lng: 13.4050456})

      # A different coordinate inside the same cell hits the same cache entry.
      assert WaterGrid.water?(%{lat: 52.5200456, lng: 13.4050123})

      # Still exactly one entry: no second lookup was performed and cached.
      assert [{^key, true}] = :ets.lookup(WaterGrid.table(), key)
      assert :ets.info(WaterGrid.table(), :size) == 1
    end

    test "returns the cached false without re-querying" do
      key = WaterGrid.cell_key(52.4, 13.3)
      :ets.insert(WaterGrid.table(), {key, false})

      refute WaterGrid.water?(%{lat: 52.4, lng: 13.3})
      assert [{^key, false}] = :ets.lookup(WaterGrid.table(), key)
    end

    test "answers 'not water' without caching when the database is unavailable" do
      # No sandbox owner is checked out here, so the lookup query fails. It
      # must not crash the caller and must not poison the grid.
      refute WaterGrid.water?(%{lat: 52.4711, lng: 13.3711})

      assert :ets.info(WaterGrid.table(), :size) == 0
    end

    test "stops caching once the grid is full" do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(GsdTracker.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      # Below the cap a fresh answer is cached.
      refute WaterGrid.water?(%{lat: 52.4712, lng: 13.3712})
      assert :ets.info(WaterGrid.table(), :size) == 1

      fill_grid(WaterGrid.max_size())
      assert :ets.info(WaterGrid.table(), :size) >= WaterGrid.max_size()
      size_when_full = :ets.info(WaterGrid.table(), :size)

      # Above it the answer is still correct, but no longer cached.
      refute WaterGrid.water?(%{lat: 52.4713, lng: 13.3713})
      assert :ets.info(WaterGrid.table(), :size) == size_when_full
    end
  end

  defp fill_grid(count) do
    1..count
    |> Stream.map(&{{&1 / 1_000_000, &1 / 1_000_000}, false})
    |> Stream.chunk_every(10_000)
    |> Enum.each(&:ets.insert(WaterGrid.table(), &1))
  end
end
