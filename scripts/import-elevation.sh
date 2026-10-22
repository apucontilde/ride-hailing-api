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
# The ONE elevation coverage gate is config.DefaultElevationMinCoverage (0.99)
# in Go; this shell default mirrors it and MUST stay equal — a value between
# ingest and the runtime ROUTING_ELEV_MIN_COVERAGE gate lets a region pass
# ingest and then silently degrade to flat routing at runtime (api_plans
# bug #24). Override both to the same value together, never just one.
MIN_COVERAGE="${MIN_COVERAGE:-0.99}"
FETCH="${FETCH:-1}"   # 1 = download missing tiles; set FETCH=0 to reuse cache only

# Optional region scope for the post-import assertion below: a REGION env or a
# --region/-region argument (the same form scripts/import-road-network.sh and
# elevtool itself accept — the argument is also forwarded to elevtool untouched).
# With a region, coverage is judged on THAT region's vertices only, so a valley
# backfill is never measured against other regions' vertices.
REGION="${REGION:-}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --region|-region)
      if ((i + 1 >= ${#args[@]})); then
        echo "ERROR: ${args[i]} needs a value" >&2
        exit 2
      fi
      REGION="${args[i+1]}"
      ;;
  esac
done

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
# Scoped to one region when --region/REGION is present (a backfill is judged on
# its own vertices); the unscoped form warns that it mixes every region.
if [ -n "$REGION" ]; then
  COVERAGE=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
    -d "$DB_NAME" -Atq -v region="$REGION" <<'SQL'
SELECT CASE WHEN count(*)=0 THEN 1.0 ELSE count(elevation_m)::float/count(*) END
FROM road_network_vertices_pgr WHERE region_id = :'region';
SQL
)
  echo "==> coverage for region '$REGION' after backfill: $(awk -v c="$COVERAGE" 'BEGIN { printf "%.2f%%", c*100 }')"
else
  COVERAGE=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
    -d "$DB_NAME" -Atq -c \
    "SELECT CASE WHEN count(*)=0 THEN 1.0 ELSE count(elevation_m)::float/count(*) END FROM road_network_vertices_pgr;")
  echo "WARNING: no --region/REGION given; this coverage is GLOBAL and mixes every" >&2
  echo "         region's vertices. Pass --region <id> for a region-scoped assertion." >&2
  echo "==> global coverage after backfill: $(awk -v c="$COVERAGE" 'BEGIN { printf "%.2f%%", c*100 }')"
fi
awk -v c="$COVERAGE" -v gate="$MIN_COVERAGE" 'BEGIN { exit !(c >= gate) }' || {
  echo "ERROR: elevation coverage $COVERAGE (scope: ${REGION:-global}) is below the gate $MIN_COVERAGE." >&2
  echo "       The import wiped the backfill — re-run: make import-osm && make import-elevation && make run" >&2
  exit 1
}

echo "==> done. RESTART the API (make run) so the cached graph picks up the new elevations."