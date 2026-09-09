defmodule GsdTracker.Simulation.WaterGrid do
  @moduledoc """
  Memoized "is this point water?" lookups for the simulation.

  Every simulated move may need to know whether a candidate position falls
  on water, and a solo GSD tick can retry a move several times. Asking
  PostGIS on every attempt is wasteful: land cover is static, so the answer
  for a given spot never changes while the app runs.

  Coordinates are therefore snapped to a small grid cell (4 decimal places,
  roughly a 10m x 10m cell in Berlin) and the boolean answer for that cell
  is cached in a public, read-concurrency ETS table. The first lookup for a
  cell runs the PostGIS query; every later lookup for the same cell is an
  ETS read.

  Database errors are never allowed to crash a tick: raises *and* exits (a
  `Repo.query` call exits when the connection pool is down) are logged at
  debug level and reported as "not water" without being cached, so a
  transient failure doesn't poison the grid.

  The table is created by `GsdTracker.Timeline.Observer` in its `init/1`,
  so the long-lived supervisor process owns it and it survives every
  short-lived caller. `ensure_table/0` stays as a lazy fallback for tests and
  for callers that run before the supervisor is up — but then the cache lives
  and dies with whichever process won the race, which is exactly what the
  supervisor ownership avoids in the running system.

  Cached cells are bounded (see `max_size/0`): once the table is full, new
  answers are still returned but no longer cached, so a long-running
  simulation cannot grow the table without limit.
  """

  require Logger

  alias GsdTracker.Repo

  @table :gsd_tracker_water_grid
  @precision 4
  @max_size 200_000

  @water_sql "SELECT EXISTS (SELECT 1 FROM land_covers WHERE landuse_type = 'water' AND ST_Intersects(geometry, ST_MakePoint($1, $2)))"

  @doc "Name of the ETS table backing the cache."
  def table, do: @table

  @doc "Largest number of cells kept in the cache."
  def max_size, do: @max_size

  @doc """
  Create the cache table if it doesn't exist yet.

  Safe to call from any process and from many processes at once: losing the
  race to create the table is not an error.
  """
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _tid -> @table
    end
  end

  @doc """
  Whether the given location sits on water, answered from the grid cache.
  """
  def water?(%{lat: lat, lng: lng}) do
    ensure_table()
    key = cell_key(lat, lng)

    case cached(key) do
      [{^key, water?}] -> water?
      _ -> query_and_cache(key)
    end
  end

  @doc "Grid cell a coordinate pair belongs to."
  def cell_key(lat, lng) do
    {Float.round(lat * 1.0, @precision), Float.round(lng * 1.0, @precision)}
  end

  @doc "Drop every cached cell. Intended for tests."
  def clear do
    ensure_table()

    try do
      :ets.delete_all_objects(@table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    # Another process created the table between `whereis` and `new`.
    ArgumentError -> @table
  end

  defp cached(key) do
    :ets.lookup(@table, key)
  rescue
    # The table's owner died between `ensure_table` and the read.
    ArgumentError -> []
  end

  defp query_and_cache({cell_lat, cell_lng} = key) do
    case run_query(cell_lng, cell_lat) do
      {:ok, %{rows: [[water?]]}} when is_boolean(water?) ->
        put(key, water?)
        water?

      {:ok, _result} ->
        false

      {:error, error} ->
        Logger.debug("WaterGrid lookup failed for #{inspect(key)}: #{inspect(error)}")
        false
    end
  end

  # `Repo.query/3` raises on some failures and *exits* when the connection
  # pool is unavailable; neither may take a simulation tick down.
  defp run_query(lng, lat) do
    Repo.query(@water_sql, [lng, lat], log: false)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp put(key, water?) do
    # `:ets.info/2` answers `:undefined` for a missing table, and an atom is
    # never smaller than an integer in term order, so the insert is skipped.
    if :ets.info(@table, :size) < @max_size do
      :ets.insert(@table, {key, water?})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
