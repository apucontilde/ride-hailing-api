#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------
# Idempotent import of OSM road network via osm2pgrouting
# into road_edges / road_vertices (migration 008 schema).
#
# Flags:
#   --force                Re-run osm2pgrouting, truncate and re-copy
#   --skip-osm2pgrouting   Skip osm2pgrouting, copy from existing ways
# ------------------------------------------------------------------

FORCE=false
SKIP_OSM=false
for arg in "$@"; do
  case "$arg" in
    --force)              FORCE=true ;;
    --skip-osm2pgrouting) SKIP_OSM=true ;;
    *)
      echo "Usage: $0 [--force] [--skip-osm2pgrouting]"
      exit 1
      ;;
  esac
done

OSM_FILE="/mnt/c/Users/Ricardo/repos/ride-hailing-api/data/san-jose.osm"

# Database connection — fall back to env or defaults
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-ridehailing}"
DB_USER="${DB_USER:-ridehail}"
DB_PASSWORD="${DB_PASSWORD:-ridehail_pass}"

psql_run() {
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "$@"
}

# ---- Prerequisite checks -----------------------------------------------
if [ "$SKIP_OSM" = false ]; then
  if [ ! -f "$OSM_FILE" ]; then
    echo "ERROR: OSM file not found at $OSM_FILE"
    echo "Run scripts/download-osm.sh first."
    exit 1
  fi

  if ! command -v osm2pgrouting &>/dev/null; then
    echo "ERROR: osm2pgrouting is required but not found."
    echo ""
    echo "Install it from: https://github.com/pgRouting/osm2pgrouting"
    echo ""
    echo "  Debian/Ubuntu:  apt install osm2pgrouting"
    echo "  macOS:          brew install osm2pgrouting"
    echo "  Build from source:"
    echo "    git clone https://github.com/pgRouting/osm2pgrouting.git"
    echo "    cd osm2pgrouting && cmake . && make && sudo make install"
    exit 1
  fi
fi

# ---- Detection: check if already populated -----------------------------
EDGE_COUNT=$(psql_run -Atc "SELECT COUNT(*) FROM road_edges;" 2>/dev/null || echo "0")

run_osm2pgrouting() {
  echo "==> Dropping existing osm2pgrouting output tables..."
  psql_run <<EOSQL
    DROP TABLE IF EXISTS ways CASCADE;
    DROP TABLE IF EXISTS ways_vertices_pgr CASCADE;
    DROP TABLE IF EXISTS configuration   CASCADE;
EOSQL

  echo "==> Running osm2pgrouting..."
  osm2pgrouting \
    -f "$OSM_FILE" \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -d "$DB_NAME" \
    -U "$DB_USER" \
    -W "$DB_PASSWORD" \
    --clean
}

copy_data() {
  echo "==> Copying data into road_edges..."
  psql_run <<EOSQL
    INSERT INTO road_edges (
      source, target, geom, length_m, cost, reverse_cost,
      name, highway_type, max_speed_kmh, x1, y1, x2, y2
    )
    SELECT
      w.source,
      w.target,
      w.the_geom,
      COALESCE(NULLIF(w.length_m, 0), w.length, 0),
      w.cost,
      w.reverse_cost,
      w.name,
      c.name,
      COALESCE(w.maxspeed_forward, c.maxspeed, 0),
      w.x1, w.y1, w.x2, w.y2
    FROM ways w
    LEFT JOIN configuration c ON w.class_id = c.class_id
    WHERE w.source IS NOT NULL AND w.target IS NOT NULL
    ON CONFLICT DO NOTHING;

    INSERT INTO road_vertices (id, geom, cnt)
    SELECT wvp.id, wvp.the_geom, wvp.cnt
    FROM ways_vertices_pgr wvp
    ON CONFLICT (id) DO NOTHING;
EOSQL
}

drop_raw_tables() {
  psql_run <<EOSQL
    DROP TABLE IF EXISTS ways CASCADE;
    DROP TABLE IF EXISTS ways_vertices_pgr CASCADE;
    DROP TABLE IF EXISTS configuration   CASCADE;
EOSQL
}

# ---- Decision logic ----------------------------------------------------

if [ "$FORCE" = true ]; then
  echo "==> --force: truncating existing data..."
  psql_run -c "TRUNCATE road_edges, road_vertices RESTART IDENTITY CASCADE;"
  run_osm2pgrouting
  copy_data
  drop_raw_tables

elif [ "$SKIP_OSM" = true ]; then
  echo "==> --skip-osm2pgrouting: checking for existing ways tables..."
  WAYS_EXISTS=$(psql_run -Atc "
    SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'ways');
  ")
  if [ "$WAYS_EXISTS" != "t" ]; then
    echo "ERROR: ways tables don't exist. Run without --skip-osm2pgrouting first."
    exit 1
  fi
  copy_data
  drop_raw_tables

elif [ "$EDGE_COUNT" -gt 0 ]; then
  echo "==> road_edges already has $EDGE_COUNT rows — skipping osm2pgrouting."
  echo "    Use --force to re-run or --skip-osm2pgrouting to re-copy only."
  exit 0

else
  run_osm2pgrouting
  copy_data
  drop_raw_tables
fi

echo "==> Done. Road network imported."
