#!/usr/bin/env bash
# import-elevation.sh — backfill road_network_vertices_pgr.elevation_m /
# .elevation_source from the SRTM "skadi" DEM (api_plans/[elevation]_dem_ingest_and_noise_control.md).
#
# RUNBOOK ORDER (load-bearing; AGENTS.md env fact 5):
#   1. make import-osm     — but the importer NEVER writes elevation_m,
#                            so a fresh import has ZERO coverage by construction.
#   2. make import-elevation — this script.
#   3. make run           — RESTART the API: the native graph is cached
#                            in-process and holds the EleM values loaded at boot.
set -euo pipefail

# Same env fallback chain as the Makefile and import-road-network.sh.
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-ridehail}"
DB_PASSWORD="${DB_PASSWORD:-ridehail_pass}"
DB_NAME="${DB_NAME:-ridehailing}"
DB_SSLMODE="${DB_SSLMODE:-disable}"

DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=${DB_SSLMODE}"
DEM_DIR="${DEM_DIR:-data/dem}"
MIN_COVERAGE="${MIN_COVERAGE:-0.98}"
FETCH="${FETCH:-1}"   # 1 = download missing tiles; set FETCH=0 to reuse cache only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

ARGS=(-database-url "$DATABASE_URL" -dem-dir "$DEM_DIR" -min-coverage "$MIN_COVERAGE")
if [ "$FETCH" = "1" ]; then
  ARGS+=(-fetch)
fi

# Any extra flags (e.g. --region) pass straight through to elevtool.
echo "==> elevtool ${ARGS[*]}" "$@"
go run ./cmd/elevtool "${ARGS[@]}" "$@"

# Post-import coverage assertion: the importer never writes elevation_m, so a
# routine re-import must not silently return the feature to flat routing. This
# is the only guard and it is deliberately part of this stage, not a nicety.
COVERAGE=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
  -d "$DB_NAME" -Atq -c \
  "SELECT CASE WHEN count(*)=0 THEN 1.0 ELSE count(elevation_m)::float/count(*) END FROM road_network_vertices_pgr;")

echo "==> coverage after backfill: $(awk -v c="$COVERAGE" 'BEGIN { printf "%.2f%%", c*100 }')"
awk -v c="$COVERAGE" -v gate="$MIN_COVERAGE" 'BEGIN { exit !(c >= gate) }' || {
  echo "ERROR: elevation coverage $COVERAGE is below the gate $MIN_COVERAGE." >&2
  echo "       The import wiped the backfill — re-run: make import-osm && make import-elevation && make run" >&2
  exit 1
}

echo "==> done. RESTART the API (make run) so the cached graph picks up the new elevations."