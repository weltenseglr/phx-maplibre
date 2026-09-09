defmodule GsdTracker.Repo.Migrations.CreateGsdTrackerTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"

    create table(:land_covers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :landuse_type, :string, null: false
      add :source, :string, null: false, default: "osm"
    end

    execute "SELECT AddGeometryColumn('land_covers', 'geometry', 4326, 'MULTIPOLYGON', 2)"
    execute "CREATE INDEX land_covers_geometry_idx ON land_covers USING GIST (geometry)"

    create table(:flocks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :member_count, :integer, null: false, default: 0
    end

    execute "SELECT AddGeometryColumn('flocks', 'center_location', 4326, 'POINT', 2)"
    execute "CREATE INDEX flocks_center_location_idx ON flocks USING GIST (center_location)"

    create table(:gsds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :commissioning_date, :utc_datetime, null: false
      add :decommissioning_date, :utc_datetime
      add :partner_id, :binary_id
      add :flock_id, references(:flocks, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false
      add :speed_kmh, :decimal
    end

    execute "SELECT AddGeometryColumn('gsds', 'current_location', 4326, 'POINT', 2)"
    execute "CREATE INDEX gsds_current_location_idx ON gsds USING GIST (current_location)"

    create table(:gsd_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :timestamp, :utc_datetime_usec, null: false

      add :gsd_id,
          references(:gsds, type: :binary_id, on_delete: :delete_all),
          null: false

      add :flock_id, :binary_id
      add :partner_id, :binary_id
      add :status, :string
      add :movement_vector, :map
      add :speed_kmh, :decimal
    end

    execute "SELECT AddGeometryColumn('gsd_stats', 'location', 4326, 'POINT', 2)"
    execute "CREATE INDEX gsd_stats_location_idx ON gsd_stats USING GIST (location)"
    create unique_index(:gsd_stats, [:gsd_id, :timestamp])
    create index(:gsd_stats, [:timestamp])
  end
end
