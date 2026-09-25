#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------
# Idempotent import of OSM road network via osm2pgrouting.
#
# Populates BOTH schemas:
#   - road_edges / road_vertices                  (migration 008, full geom)
#   - road_network_edges_pgr / road_network_*     (migration 011, the tables
#     internal/repository/navigation_repo.go queries for routing)
#
# Input: first positional arg, or OSM_INPUT env var. Any .osm XML or
# .osm.pbf readable by osmconvert/osmium works. Defaults to
# data/san-jose.osm.pbf, falling back to data/san-jose.osm then the
# whole-country extract.
#
# osm2pgrouting reads .osm XML only, so a .osm.pbf input is converted with
# osmconvert (or osmium) first — the XML is written next to the .pbf.
#
# ---- Memory -------------------------------------------------------------
# osm2pgrouting loads the whole ways graph into RAM and exposes no disk-backed
# index option, so its peak memory scales with the input XML. Unlike
# scripts/export-places.sh, --index-type=sparse_file_array CANNOT be applied
# here: osmium only accepts it for subcommands that maintain a node-location
# index (export, add-locations-to-ways), not for the ones this script uses
# (tags-filter, cat).
#
# The equivalent fix, applied by default, is to strip the extract down to the
# road network FIRST with `osmium tags-filter`. The filter keeps the tag set
# osm2pgrouting's mapconfig.xml evaluates (highway + the cycleway/tracktype/
# junction keys it only uses when no highway tag exists), so the imported
# graph is identical to an unfiltered import — only the irrelevant bulk is
# dropped. tags-filter also keeps every node referenced by a matched way, so
# the filtered PBF is still self-contained (coordinates intact) while
# osm2pgrouting's in-RAM graph — the OOM source on whole-country imports —
# is bounded. On San José this shrinks the XML ~3x; on a whole-country
# extract it is the difference between an OOM-kill and a successful import.
# Pass --no-filter to feed the full extract through instead (e.g. osmium not
# installed).
#
# Default input discovery prefers the .pbf, since filtering and conversion
# are leaner off PBF than off a multi-hundred-MB XML.
#
# Flags:
#   --force                Re-run osm2pgrouting, truncate and re-copy
#   --skip-osm2pgrouting   Skip osm2pgrouting, copy from existing ways
#   --no-filter            Skip the osmium nwr/highway pre-filter
# ------------------------------------------------------------------

DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"

FORCE=false
SKIP_OSM=false
NO_FILTER=false
INPUT=""
for arg in "$@"; do
  case "$arg" in
    --force)              FORCE=true ;;
    --skip-osm2pgrouting) SKIP_OSM=true ;;
    --no-filter)          NO_FILTER=true ;;
    -h|--help)
      echo "Usage: $0 [--force] [--skip-osm2pgrouting] [--no-filter] [path/to/input.osm.pbf|.osm]"
      echo "  (default)  data/san-jose.osm.pbf, else data/san-jose.osm,"
      echo "             else data/costa-rica-latest.osm.pbf."
      echo "  OSM_INPUT=<path> env var is also accepted."
      echo "  --no-filter  skip the osmium nwr/highway pre-filter (keeps osm2pgrouting memory down)"
      exit 0
      ;;
    -*)
      echo "Unknown flag: $arg" >&2
      echo "Usage: $0 [--force] [--skip-osm2pgrouting] [--no-filter] [path/to/input.osm.pbf|.osm]" >&2
      exit 1
      ;;
    *)
      if [ -n "$INPUT" ]; then
        echo "ERROR: multiple positional args given ('$INPUT' and '$arg')." >&2
        exit 1
      fi
      INPUT="$arg"
      ;;
  esac
done
if [ -z "$INPUT" ]; then
  INPUT="${OSM_INPUT:-}"
fi

# Resolve the input, preferring the .pbf over an already-converted .osm so
# the pre-filter and the XML conversion both run off the leanest file.
if [ -z "$INPUT" ]; then
  for candidate in "$DATA_DIR/san-jose.osm.pbf" "$DATA_DIR/san-jose.osm" \
                   "$DATA_DIR/costa-rica-latest.osm.pbf"; do
    if [ -f "$candidate" ]; then
      INPUT="$candidate"
      break
    fi
  done
fi
if [ -z "$INPUT" ]; then
  echo "ERROR: no OSM input found."
  echo "Usage: $0 [--force] [--skip-osm2pgrouting] [--no-filter] [path/to/input.osm.pbf|.osm]"
  echo "  (or set OSM_INPUT=<path>, or run scripts/download-osm.sh first.)"
  exit 1
fi
if [ ! -f "$INPUT" ]; then
  echo "ERROR: OSM input not found at $INPUT"
  exit 1
fi
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"

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
if [ "$SKIP_OSM" = false ] && ! command -v osm2pgrouting &>/dev/null; then
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

# ---- Memory: pre-filter to the road network ----------------------------
# tags-filter keeps every node referenced by a matched way, so the filtered
# PBF is self-contained (coords intact) but drastically smaller — which bounds
# osm2pgrouting's in-RAM graph. Skipped with --no-filter or if osmium is
# missing. Writes roads-filtered.osm.pbf next to the source; reused as long as
# it is newer than the source.
FILTERED_PBF=""
filter_to_roads() {
  local src="$1" dir dst
  dir="$(dirname "$src")"
  dst="$dir/roads-filtered.osm.pbf"
  if [ "$(basename "$src")" = "roads-filtered.osm.pbf" ]; then
    FILTERED_PBF="$src"
    return 0
  fi
  if [ "$FORCE" = false ] && [ -f "$dst" ] && [ "$dst" -nt "$src" ]; then
    echo "==> Reusing existing filtered road extract: $dst"
    FILTERED_PBF="$dst"
    return 0
  fi
  echo "==> Filtering $src to road network (osmium tags-filter)..."
  osmium tags-filter "$src" -o "$dst" --overwrite \
    'nwr/highway' 'nwr/cycleway' 'nwr/tracktype' 'nwr/junction'
  FILTERED_PBF="$dst"
}

# osm2pgrouting only reads .osm XML; convert the .pbf if the XML is missing.
ensure_osm_xml() {
  [ -f "$OSM_FILE" ] && return 0
  if command -v osmconvert &>/dev/null; then
    echo "==> Converting $OSM_PBF -> $OSM_FILE (osmconvert)..."
    osmconvert "$OSM_PBF" -o="$OSM_FILE"
  elif command -v osmium &>/dev/null; then
    echo "==> Converting $OSM_PBF -> $OSM_FILE (osmium)..."
    osmium cat "$OSM_PBF" -o "$OSM_FILE"
  else
    echo "ERROR: need osmconvert or osmium to convert $OSM_PBF to OSM XML."
    exit 1
  fi
}

# ---- Detection: check if already populated -----------------------------
# Gate on the routing tables the API actually queries (migration 011), so a
# fresh 011 seed is created even when the migration-008 tables already exist.
# Decided before the pre-filter so an already-imported DB isn't re-filtered.
# NOTE (api_plans/02): since the pgrouting image swap, migration 011 does NOT
# seed NYC on fresh DBs (the seed is guarded behind extension-absent) and 012
# purges it on reused volumes — this gate no longer trips on the demo seed, so
# a plain `make import-osm` runs the real import on an empty 02+ database.
FULL_RUN=false
if [ "$FORCE" = true ]; then
  FULL_RUN=true
elif [ "$SKIP_OSM" = false ]; then
  EDGE_COUNT=$(psql_run -Atc "SELECT COUNT(*) FROM road_network_edges_pgr;" 2>/dev/null || echo "0")
  if [ "$EDGE_COUNT" -gt 0 ]; then
    echo "==> road_network_edges_pgr already has $EDGE_COUNT rows — skipping osm2pgrouting."
    echo "    Use --force to re-run or --skip-osm2pgrouting to re-copy only."
    exit 0
  fi
  FULL_RUN=true
fi

# Decide on osm2pgrouting for the current run.
if [ "$FULL_RUN" = true ]; then
  if [ "$NO_FILTER" = false ] && command -v osmium &>/dev/null; then
    filter_to_roads "$INPUT"
    INPUT="$FILTERED_PBF"
  fi

  # Resolve the pair osm2pgrouting consumes: OSM_FILE (XML, the actual input)
  # and OSM_PBF (the source to convert from, empty for XML).
  OSM_FILE=""
  OSM_PBF=""
  case "$INPUT" in
    *.pbf)
      OSM_PBF="$INPUT"
      base="${INPUT%.pbf}"
      case "$base" in
        *.osm) OSM_FILE="$base" ;;
        *)     OSM_FILE="$base.osm" ;;
      esac
      ;;
    *.osm) OSM_FILE="$INPUT" ;;
    *)
      echo "ERROR: unsupported input extension: $INPUT (expected .osm or .osm.pbf)" >&2
      exit 1
      ;;
  esac
  echo "==> Input: $OSM_FILE (source: ${OSM_PBF:-XML as-is})"
fi

run_osm2pgrouting() {
  ensure_osm_xml

  echo "==> Dropping existing osm2pgrouting output tables..."
  psql_run <<EOSQL
    DROP TABLE IF EXISTS ways CASCADE;
    DROP TABLE IF EXISTS ways_vertices_pgr CASCADE;
    DROP TABLE IF EXISTS configuration   CASCADE;
    DROP TABLE IF EXISTS osm_node CASCADE;
    DROP TABLE IF EXISTS osm_way CASCADE;
    DROP TABLE IF EXISTS osm_way_nodes CASCADE;
    DROP TABLE IF EXISTS osm_way_tags CASCADE;
EOSQL

  # osm2pgrouting prints nothing between "parsing data" and completion, which
  # can be 30+ minutes on a country-wide XML. Poll the DB every PROGRESS_INTERVAL
  # seconds and report table row/sizes so it's possible to tell "working" from
  # "stuck" (growing sizes = inserts flowing; flat sizes = still parsing XML).
  PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"
  osm2pgrouting \
    -f "$OSM_FILE" \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -d "$DB_NAME" \
    -U "$DB_USER" \
    -W "$DB_PASSWORD" \
    --clean &
  OSM_PID=$!
  STARTED=$SECONDS
  (
    while kill -0 "$OSM_PID" 2>/dev/null; do
      sleep "$PROGRESS_INTERVAL"
      rows=$(psql_run -Atc "
        SELECT COALESCE(string_agg(
                 relname || '=' || n_live_tup::text || ' rows / '
                 || pg_size_pretty(pg_total_relation_size(relid)), ', '),
               '(no tables yet — still parsing XML)')
        FROM pg_stat_user_tables
        WHERE relname IN ('osm_node', 'osm_way', 'osm_way_nodes', 'ways', 'ways_vertices_pgr');
      " 2>&1 | tail -n 1)
      echo "    [progress $((SECONDS - STARTED))s] $rows"
    done
  ) &
  MON_PID=$!

  set +e
  wait "$OSM_PID"
  STATUS=$?
  set -e
  kill "$MON_PID" 2>/dev/null || true
  wait "$MON_PID" 2>/dev/null || true

  if [ "$STATUS" -ne 0 ]; then
    echo "ERROR: osm2pgrouting failed (exit $STATUS). Common causes on large files:"
    echo "  - out of memory (osm2pgrouting holds the ways graph in RAM;"
    echo "    run without --no-filter so the input is pre-filtered to roads)"
    echo "  - disk full (the source XML is multi-GB)"
    exit "$STATUS"
  fi
}

copy_data() {
  echo "==> Copying data into road_edges / road_vertices (migration 008)..."
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
      c.tag_value,
      COALESCE(w.maxspeed_forward, c.maxspeed, 0),
      w.x1, w.y1, w.x2, w.y2
    FROM ways w
    LEFT JOIN configuration c ON w.tag_id = c.tag_id
    WHERE w.source IS NOT NULL AND w.target IS NOT NULL
    ON CONFLICT DO NOTHING;

    INSERT INTO road_vertices (id, geom, cnt)
    SELECT wvp.id, wvp.the_geom, wvp.cnt
    FROM ways_vertices_pgr wvp
    ON CONFLICT (id) DO NOTHING;
EOSQL

  echo "==> Copying data into road_network_vertices_pgr / road_network_edges_pgr (migration 011)..."
  psql_run <<EOSQL
    TRUNCATE road_network_vertices_pgr, road_network_edges_pgr RESTART IDENTITY CASCADE;

    INSERT INTO road_network_vertices_pgr (id, the_geom, lat, lng)
    SELECT id, the_geom, ST_Y(the_geom), ST_X(the_geom)
    FROM ways_vertices_pgr
    ON CONFLICT (id) DO NOTHING;

    -- Edge cost is the road length in meters (ways.length_m), so the
    -- accumulated routing cost == route distance in meters.
    INSERT INTO road_network_edges_pgr (id, source, target, cost)
    SELECT gid, source, target, length_m
    FROM ways
    WHERE source IS NOT NULL
      AND target IS NOT NULL
      AND length_m IS NOT NULL
      AND length_m > 0
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

else
  run_osm2pgrouting
  copy_data
  drop_raw_tables
fi

echo "==> Done. Road network imported."
