#!/usr/bin/env bash
# Build the portable, full-planet land/water dump used by the GSD demo.
#
# This intentionally downloads neither during tests nor container setup. Run it
# explicitly on a machine with roughly 100 GB for the OSM planet PBF plus
# working space. The PBF cache lives outside the repository; only the generated
# dump is written below priv/data/ (and is ignored by Git).
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLANET_URL="${PLANET_URL:-https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf}"
if [[ -n "${LAND_COVER_CACHE_DIR:-}" ]]; then
  CACHE_DIR="$LAND_COVER_CACHE_DIR"
  REMOVE_CACHE_ON_EXIT=false
else
  CACHE_DIR="$(mktemp -d)"
  REMOVE_CACHE_ON_EXIT=true
fi

PLANET_PBF="$CACHE_DIR/planet-latest.osm.pbf"
PLANET_MD5="$CACHE_DIR/planet-latest.osm.pbf.md5"
FILTERED_PBF="$CACHE_DIR/land-cover-filtered.osm.pbf"
DUMP_OUT="${LAND_COVER_DUMP_OUT:-$APP_ROOT/priv/data/land_covers.dump}"
DB_HOST="${PGHOST:-localhost}"
DB_USER="${PGUSER:-postgres}"
DB_NAME="${PGDATABASE:-gsd_tracker_dev}"
DB_PASS="${PGPASSWORD:-postgres}"

for command in curl md5sum osmium ogr2ogr psql pg_dump; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

mkdir -p "$CACHE_DIR" "$(dirname "$DUMP_OUT")"

cleanup() {
  rm -f "$FILTERED_PBF"

  if [[ "$REMOVE_CACHE_ON_EXIT" == true ]]; then
    rm -rf "$CACHE_DIR"
  fi
}

trap cleanup EXIT

echo "==> Downloading the current OpenStreetMap planet PBF into $CACHE_DIR"
curl --fail --location --retry 3 --output "$PLANET_MD5" "$PLANET_URL.md5"

if ! (cd "$CACHE_DIR" && md5sum --status -c "$(basename "$PLANET_MD5")" 2>/dev/null); then
  curl --fail --location --retry 3 --continue-at - --output "$PLANET_PBF" "$PLANET_URL"
  (cd "$CACHE_DIR" && md5sum -c "$(basename "$PLANET_MD5")")
fi

echo "==> Filtering landuse and natural=water polygons"
osmium tags-filter "$PLANET_PBF" \
  landuse=residential \
  landuse=commercial \
  landuse=industrial \
  landuse=retail \
  natural=water \
  -o "$FILTERED_PBF" --overwrite

echo "==> Loading filtered polygons into PostgreSQL"
PGPASSWORD="$DB_PASS" ogr2ogr -f PostgreSQL \
  "PG:host=$DB_HOST user=$DB_USER password=$DB_PASS dbname=$DB_NAME" \
  "$FILTERED_PBF" \
  multipolygons \
  -nln osm_land_cover_temp \
  -lco GEOMETRY_NAME=geom \
  -lco FID=ogc_fid \
  -lco SPATIAL_INDEX=GIST \
  -overwrite \
  -sql "SELECT landuse, \"natural\" FROM multipolygons WHERE landuse IN ('residential', 'commercial', 'industrial', 'retail') OR \"natural\" = 'water'"

echo "==> Replacing land cover rows"
PGPASSWORD="$DB_PASS" psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" <<'SQL'
TRUNCATE TABLE land_covers;

INSERT INTO land_covers (id, landuse_type, geometry, source)
SELECT
  gen_random_uuid(),
  CASE
    WHEN landuse = 'residential' THEN 'residential'
    WHEN landuse = 'commercial'  THEN 'commercial'
    WHEN landuse = 'industrial'  THEN 'industrial'
    WHEN landuse = 'retail'      THEN 'retail'
    WHEN "natural" = 'water'     THEN 'water'
  END,
  ST_Multi(geom)::geometry(MultiPolygon, 4326),
  'osm'
FROM osm_land_cover_temp;

DROP TABLE osm_land_cover_temp;
SQL

echo "==> Writing portable PostgreSQL dump to $DUMP_OUT"
rm -f "$DUMP_OUT"
PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
  --format=custom --data-only --table=public.land_covers --no-owner --no-privileges \
  --file="$DUMP_OUT"

echo "==> Done: $DUMP_OUT"
