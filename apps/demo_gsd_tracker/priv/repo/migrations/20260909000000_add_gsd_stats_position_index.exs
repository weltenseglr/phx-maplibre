defmodule GsdTracker.Repo.Migrations.AddGsdStatsPositionIndex do
  use Ecto.Migration

  # `GsdTracker.Tracking.latest_positions/0` runs
  #
  #     SELECT DISTINCT ON (gsd_id) ... FROM gsd_stats ORDER BY gsd_id, timestamp DESC
  #
  # which needs an index whose order matches (gsd_id ASC, timestamp DESC). The
  # unique (gsd_id, timestamp) index cannot serve it — a btree can only be read
  # forwards or backwards as a whole, never with mixed directions per column —
  # so every LiveView mount fell back to a full scan plus sort of gsd_stats.
  def change do
    execute(
      "CREATE INDEX gsd_stats_gsd_id_timestamp_desc_idx ON gsd_stats (gsd_id, timestamp DESC)",
      "DROP INDEX gsd_stats_gsd_id_timestamp_desc_idx"
    )
  end
end
