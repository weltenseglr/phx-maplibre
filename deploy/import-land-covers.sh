#!/usr/bin/env sh
# Restore the full, static OSM land/water dataset after the application schema
# exists. The checksum stored as the table comment makes the import idempotent.
set -eu

: "${LAND_COVER_DUMP_PATH:=/seed/land_covers.dump}"
: "${PGHOST:=postgres}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=gsd_tracker_prod}"
: "${PGPASSWORD:=postgres}"

if [ ! -r "$LAND_COVER_DUMP_PATH" ]; then
  echo "full land-cover dump is required but is not readable: $LAND_COVER_DUMP_PATH" >&2
  exit 1
fi

checksum="$(sha256sum "$LAND_COVER_DUMP_PATH" | awk '{print $1}')"
# Bump this whenever import semantics change so a previous incomplete import
# cannot be mistaken for the current dataset.
marker="phx-maplibre:land-covers:v2:$checksum"
existing="$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -Atqc \
  "SELECT COALESCE(obj_description('public.land_covers'::regclass), '')")"

if [ "$existing" = "$marker" ]; then
  echo "full land-cover dataset is already current"
  exit 0
fi

echo "importing full land-cover dataset ($checksum)"
PGPASSWORD="$PGPASSWORD" psql -v ON_ERROR_STOP=1 -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
  -c 'TRUNCATE TABLE public.land_covers'
PGPASSWORD="$PGPASSWORD" pg_restore -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
  --data-only --no-owner --no-privileges --exit-on-error \
  "$LAND_COVER_DUMP_PATH"
PGPASSWORD="$PGPASSWORD" psql -v ON_ERROR_STOP=1 \
  -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
  -c "COMMENT ON TABLE public.land_covers IS '$marker'"

echo "full land-cover dataset imported"
