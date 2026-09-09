#!/usr/bin/env bash
# Production Compose runs migrations and restores the full static land/water
# dataset before this long-lived application container starts.
set -euo pipefail

until pg_isready -h "${PGHOST:-postgres}" -U "${PGUSER:-postgres}" -q; do
  echo "waiting for postgres..."
  sleep 2
done

exec mix phx.server
