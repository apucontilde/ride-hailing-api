#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------
# Idempotent, REGION-SCOPED import of OSM road network via
# osm2pgrouting (api_plans/05).
#
# ONE region per run. `--region cr-sj` (the default) is the only
# importable unit: the skip gate, the wipe and the insert all carry the
# region id, so importing a second city never touches the first one's
# rows. Every row written here lands with region_id = <region>.
#
# Populates BOTH schemas, for this region only:
#   - road_edges / road_vertices                  (migration 008, full geom)
#   - road_network_edges_pgr / road_network_*     (migration 011, the tables
#     internal/repository/navigation_repo.go queries for routing)
# The region is self-registered in `routing_regions` (migration 013)
# before the import and its bbox is refreshed from ST_Extent afterwards.
#
# Input: first positional arg, or OSM_INPUT env var. Any .osm XML or
# .osm.pbf readable by osmconvert/osmium works. Defaults to
# data/san-jose.osm.pbf, falling back to data/san-jose.osm then the
# whole-country extract. The extract is NOT clipped here — the clip is
# the download's job (`scripts/download-osm.sh --bbox ...`); this script
# records the region you told it about in the registry.
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
# SIZING RULE (warns, never fails): an extract over ~300 MB, or a region box
# country-sized, is almost always an OOM and an accidental mega-region. Split
# it first and import one chunk per region:
#   osmium fileinfo data/costa-rica-latest.osm.pbf
#   osmium extract -p regions/guanacaste.poly data/costa-rica-latest.osm.pbf \
#     -o data/guanacaste.osm.pbf
#   ./scripts/import-road-network.sh --region cr-gua --bbox "..." \
#     --level state data/guanacaste.osm.pbf
#
# Default input discovery prefers the .pbf, since filtering and conversion
# are leaner off PBF than off a multi-hundred-MB XML.
#
# Flags:
#   --region <id>        Registry region id to import into (default: cr-sj)
#   --datasource <id>    routing_datasources id whose Postgres holds this
#                        region's rows (default: "" = this database, plan 06)
#   --bbox <minLon,minLat,maxLon,maxLat>
#                        Region's admin box, recorded in the registry on
#                        registration and refreshed from ST_Extent after the
#                        import (default: the San José province box)
#   --level <country|state|city>   Registry level (default: state for a new
#                        region; an existing row keeps its own)
#   --name <text>        Human-readable region name (default: the region id)
#   --parent <id>        Parent region id for the registry hierarchy
#   --default            Mark the region as the resolver's default region
#   --force              Re-run osm2pgrouting, wipe and re-copy THIS region
#   --skip-osm2pgrouting Skip osm2pgrouting, re-copy this region from `ways`
#   --no-filter          Skip the osmium nwr/highway pre-filter
# ------------------------------------------------------------------

# data/ is gitignored, so a fresh clone has no such directory. Resolve it
# leniently: --help and flag validation have to work before any import, and
# the default input discovery below already tolerates missing candidates.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../data"
if [ -d "$DATA_DIR" ]; then
  DATA_DIR="$(cd "$DATA_DIR" && pwd)"
fi

FORCE=false
SKIP_OSM=false
NO_FILTER=false
INPUT=""
REGION="cr-sj"
DATASOURCE=""
# The default box is the San José province clip, the same numbers
# scripts/download-osm.sh defaults to. They must stay in sync: the download
# clips the extract, the registry records the box.
REGION_BBOX="-84.50,9.00,-83.50,10.20"
REGION_LEVEL=""
REGION_NAME=""
REGION_PARENT=""
MARK_DEFAULT=false

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/import-road-network.sh [flags] [path/to/input.osm.pbf|.osm]

  (default)  data/san-jose.osm.pbf, else data/san-jose.osm,
             else data/costa-rica-latest.osm.pbf. OSM_INPUT=<path> also works.

Region flags (one region per run):
  --region <id>     Registry region to import (default: cr-sj).
  --datasource <id> routing_datasources id owning this region's rows
                    (default: "" = this database).
  --bbox <minLon,minLat,maxLon,maxLat>
                    Admin box recorded in routing_regions (default: the San
                    José province box); refreshed from ST_Extent after import.
  --level <country|state|city>  Registry level for a NEW region (default: state).
  --name <text>     Region name in the registry (default: the region id).
  --parent <id>     Parent region id in the registry.
  --default         Mark the region as the resolver's default region.

Import flags:
  --force                Wipe and re-import THIS region.
  --skip-osm2pgrouting   Re-copy this region from the existing `ways` tables.
  --no-filter            Skip the osmium nwr/highway pre-filter.
  -h, --help             This text.
USAGE
}

# Registry/operator ids are validated before they are ever used in SQL: the
# per-region statements bind them as psql variables, but a per-region index
# NAME and the datasource lookup embed them, so keep the charset tight.
valid_id() {
  case "$2" in
    *[!A-Za-z0-9_-]*|"") echo "ERROR: $1 must be non-empty and match [A-Za-z0-9_-]+ (got '$2')" >&2; return 1 ;;
    *) return 0 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force)              FORCE=true; shift ;;
    --skip-osm2pgrouting) SKIP_OSM=true; shift ;;
    --no-filter)          NO_FILTER=true; shift ;;
    --region)             [ $# -ge 2 ] || die "--region needs a value"; REGION="$2"; shift 2 ;;
    --datasource)         [ $# -ge 2 ] || die "--datasource needs a value"; DATASOURCE="$2"; shift 2 ;;
    --bbox)               [ $# -ge 2 ] || die "--bbox needs a value"; REGION_BBOX="$2"; shift 2 ;;
    --level)              [ $# -ge 2 ] || die "--level needs a value"; REGION_LEVEL="$2"; shift 2 ;;
    --name)               [ $# -ge 2 ] || die "--name needs a value"; REGION_NAME="$2"; shift 2 ;;
    --parent)             [ $# -ge 2 ] || die "--parent needs a value"; REGION_PARENT="$2"; shift 2 ;;
    --default)            MARK_DEFAULT=true; shift ;;
    -h|--help)            usage; exit 0 ;;
    -*)                   die "Unknown flag: $1 (run with --help for usage)" ;;
    *)
      if [ -n "$INPUT" ]; then
        die "multiple positional args given ('$INPUT' and '$1')."
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

valid_id "--region" "$REGION" || exit 1
if [ -n "$DATASOURCE" ]; then
  valid_id "--datasource" "$DATASOURCE" || exit 1
fi
if [ -n "$REGION_PARENT" ]; then
  valid_id "--parent" "$REGION_PARENT" || exit 1
fi
# Mirrors the routing_regions CHECK so an operator typo fails with a readable
# message instead of a 23514 from the registry upsert.
if [ -n "$REGION_LEVEL" ] && [ "$REGION_LEVEL" != country ] \
   && [ "$REGION_LEVEL" != state ] && [ "$REGION_LEVEL" != city ]; then
  die "--level must be country, state or city (got '$REGION_LEVEL')"
fi
if ! [[ "$REGION_BBOX" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
  die "--bbox must be minLon,minLat,maxLon,maxLat (got '$REGION_BBOX')"
fi
IFS=, read -r BBOX_LON_MIN BBOX_LAT_MIN BBOX_LON_MAX BBOX_LAT_MAX <<< "$REGION_BBOX"

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
  die "no OSM input found. Run scripts/download-osm.sh first, or pass a path / set OSM_INPUT."
fi
if [ ! -f "$INPUT" ]; then
  die "OSM input not found at $INPUT"
fi
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"

# Database connection — fall back to env or defaults. The LOCAL database always
# holds the region registry; the region's ROWS live in the local database too,
# unless --datasource names another one (plan 06).
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-ridehailing}"
DB_USER="${DB_USER:-ridehail}"
DB_PASSWORD="${DB_PASSWORD:-ridehail_pass}"

DATA_HOST="$DB_HOST"
DATA_PORT="$DB_PORT"
DATA_DB="$DB_NAME"
DATA_USER="$DB_USER"
DATA_PASSWORD="$DB_PASSWORD"

# ON_ERROR_STOP: a multi-statement heredoc must abort on the first error instead
# of ploughing on (a half-copied region is worse than a failed import).
psql_local() {
  PGPASSWORD="$DB_PASSWORD" psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" "$@"
}
psql_data() {
  PGPASSWORD="$DATA_PASSWORD" psql -v ON_ERROR_STOP=1 -h "$DATA_HOST" -p "$DATA_PORT" \
    -U "$DATA_USER" -d "$DATA_DB" "$@"
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

# ---- Region schema preflight -------------------------------------------
# Region scoping is not optional: without migration 013 there is no registry
# to write and no region_id column to scope the import to. Fail loudly rather
# than re-creating rows nobody can resolve.
REGION_SCHEMA_OK=$(psql_local -Atq <<'SQL' || echo 0
SELECT count(*) FROM (VALUES ('road_network_edges_pgr'), ('road_network_vertices_pgr'),
                             ('road_edges'), ('road_vertices')) AS t(name)
WHERE EXISTS (SELECT 1 FROM information_schema.columns c
              WHERE c.table_name = t.name AND c.column_name = 'region_id');
SQL
)
if [ "$REGION_SCHEMA_OK" != "4" ]; then
  die "the routing tables have no region_id column. Apply the migrations (013_region_schema) and retry."
fi
if [ "$(psql_local -Atq -c "SELECT to_regclass('public.routing_regions') IS NOT NULL;" || echo f)" != "t" ]; then
  die "routing_regions does not exist. Apply the migrations (013_region_schema) and retry."
fi

# ---- Datasource (optional, plan 06) -------------------------------------
# A datasource's row is provisioned by ops; the password is NEVER stored in
# routing_datasources, so it comes from ROUTING_DATASOURCE_PASSWORD or pgpass.
if [ -n "$DATASOURCE" ]; then
  DS_ROW=$(psql_local -Atq -F'|' -v datasource="$DATASOURCE" <<'SQL' || true
SELECT host, port, dbname, db_user FROM routing_datasources WHERE datasource_id = :'datasource';
SQL
)
  if [ -z "$DS_ROW" ]; then
    die "datasource '$DATASOURCE' is not provisioned in routing_datasources (add the row first)."
  fi
  IFS='|' read -r DATA_HOST DATA_PORT DATA_DB DATA_USER <<< "$DS_ROW"
  DATA_PASSWORD="${ROUTING_DATASOURCE_PASSWORD:-$DB_PASSWORD}"
  echo "==> Region '$REGION' targets datasource '$DATASOURCE' ($DATA_USER@$DATA_HOST:$DATA_PORT/$DATA_DB)."
  echo "    The registry upsert below still goes to the LOCAL database."
fi

# ---- Sizing note (warns, never fails) ------------------------------------
INPUT_BYTES=$(wc -c < "$INPUT")
if [ "$INPUT_BYTES" -gt 314572800 ]; then
  echo "==> WARNING: $(basename "$INPUT") is $((INPUT_BYTES / 1048576)) MB. osm2pgrouting holds the"
  echo "    whole ways graph in RAM. Prefer a per-region extract:"
  echo "      osmium fileinfo $INPUT"
  echo "      osmium extract -p regions/$REGION.poly $INPUT -o data/$REGION.osm.pbf"
  echo "    then re-run with --region <id> --bbox <box> <that file>."
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

# ---- Detection: is THIS region already populated? -----------------------
# Gate on the routing tables the API actually queries (migration 011) and on
# the region, so importing cr-lc never trips on cr-sj's data. Decided before
# the pre-filter so an already-imported region isn't re-filtered.
# NOTE (api_plans/02): since the pgrouting image swap, migration 011 does NOT
# seed NYC on fresh DBs (the seed is guarded behind extension-absent) and 012
# purges it on reused volumes — this gate no longer trips on the demo seed, so
# a plain `make import-osm` runs the real import on an empty 02+ database.
FULL_RUN=false
if [ "$FORCE" = true ]; then
  FULL_RUN=true
elif [ "$SKIP_OSM" = false ]; then
  EDGE_COUNT=$(psql_data -Atq -v region="$REGION" <<'SQL' 2>/dev/null || echo 0
SELECT count(*) FROM road_network_edges_pgr WHERE region_id = :'region';
SQL
)
  EDGE_COUNT=$(echo "$EDGE_COUNT" | tr -dc '0-9')
  EDGE_COUNT=${EDGE_COUNT:-0}
  if [ "$EDGE_COUNT" -gt 0 ]; then
    echo "==> region '$REGION' already has $EDGE_COUNT road_network_edges_pgr rows — skipping import."
    echo "    Use --force to re-run or --skip-osm2pgrouting to re-copy only."
    exit 0
  fi
  FULL_RUN=true
fi

# ---- Registry: self-register the region before the data lands -----------
# The operator's --bbox is authoritative for the pre-import row (it is what the
# download clipped to); the post-import refresh replaces it with the real
# extent of the imported network. Omitted --level/--name/--parent keep whatever
# the row already has, so re-importing a seeded region (cr-sj: state, San José,
# parent cr) never degrades it to the bare id. --default is sticky: the
# resolver only needs at most one TRUE row, and ops can flip it with
#   UPDATE routing_regions SET default_region = FALSE WHERE region_id = '...';
register_region() {
  echo "==> Registering region '$REGION' (bbox $REGION_BBOX${DATASOURCE:+, datasource $DATASOURCE})..."
  psql_local -q -v region="$REGION" -v level="$REGION_LEVEL" -v name="$REGION_NAME" \
    -v parent="$REGION_PARENT" -v is_default="$MARK_DEFAULT" -v datasource="$DATASOURCE" \
    -v lon_min="$BBOX_LON_MIN" -v lat_min="$BBOX_LAT_MIN" \
    -v lon_max="$BBOX_LON_MAX" -v lat_max="$BBOX_LAT_MAX" <<'SQL'
INSERT INTO routing_regions (
  region_id, level, name, parent_region,
  bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max,
  default_region, datasource
)
VALUES (
  :'region',
  COALESCE(NULLIF(:'level', ''), 'state'),
  COALESCE(NULLIF(:'name', ''), :'region'),
  NULLIF(:'parent', ''),
  :'lon_min'::double precision, :'lat_min'::double precision,
  :'lon_max'::double precision, :'lat_max'::double precision,
  :'is_default'::boolean,
  NULLIF(:'datasource', '')
)
ON CONFLICT (region_id) DO UPDATE SET
  level          = COALESCE(NULLIF(:'level', ''), routing_regions.level),
  name           = COALESCE(NULLIF(:'name', ''), routing_regions.name),
  parent_region  = COALESCE(NULLIF(:'parent', ''), routing_regions.parent_region),
  bbox_lon_min   = EXCLUDED.bbox_lon_min,
  bbox_lat_min   = EXCLUDED.bbox_lat_min,
  bbox_lon_max   = EXCLUDED.bbox_lon_max,
  bbox_lat_max   = EXCLUDED.bbox_lat_max,
  default_region = routing_regions.default_region OR EXCLUDED.default_region,
  datasource     = COALESCE(EXCLUDED.datasource, routing_regions.datasource);
SQL
}

# ---- Region-scoped wipe -------------------------------------------------
# The old global TRUNCATE ... RESTART IDENTITY CASCADE is gone: a second region
# must not erase the first. Delete order matters on the 008 tables, whose FKs
# are (region_id, source)/(region_id, target) -> road_vertices (plan 04):
# road_edges rows MUST go before road_vertices rows of the same region.
wipe_region_pgr() {
  echo "==> Deleting existing pgr rows for region '$REGION'..."
  psql_data -q -v region="$REGION" <<'SQL'
DELETE FROM road_network_edges_pgr    WHERE region_id = :'region';
DELETE FROM road_network_vertices_pgr WHERE region_id = :'region';
SQL
}

wipe_region_008() {
  echo "==> Deleting existing 008 rows for region '$REGION' (edges before vertices)..."
  psql_data -q -v region="$REGION" <<'SQL'
DELETE FROM road_edges    WHERE region_id = :'region';
DELETE FROM road_vertices WHERE region_id = :'region';
SQL
}

# ---- Per-region indexes -------------------------------------------------
# plan 04 shipped ONE partial GIST scoped to cr-sj
# (rn_vertices_gist_region ... WHERE region_id = 'cr-sj'), so a second region
# would have had no spatial index at all and the region-scoped KNN snap would
# degrade to a sequential scan. Every region the importer registers gets the
# same partial GIST.
# The composite btrees are NOT regionalized: plan 04 created
# rn_edges_src_region / rn_edges_tgt_region on (region_id, source) and
# (region_id, target) as full-table indexes, and the PKs are already
# (region_id, id) — they serve every region, so emitting per-region copies
# would only bloat the write path. Index names are built from the sanitized
# region id (letters/digits/underscore, truncated to 32 chars) — the same
# charset ValidRegionID enforces on the Go side.
create_region_indexes() {
  local suffix
  suffix=$(printf '%s' "$REGION" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_' | cut -c1-32)
  psql_data -q -v region="$REGION" -v idx="$suffix" <<'SQL'
CREATE INDEX IF NOT EXISTS rn_vertices_gist_:idx
  ON road_network_vertices_pgr USING gist (the_geom)
  WHERE region_id = :'region';
SQL
}

# ---- Registry bbox refresh ---------------------------------------------
# Replaces the operator's --bbox with the true extent of THIS region's
# vertices. The extent is read on the data connection (the rows may live in
# another datasource) and written to the local registry.
refresh_region_bbox() {
  local extent minx miny maxx maxy
  extent=$(psql_data -Atq -F',' -v region="$REGION" <<'SQL' || true
SELECT COALESCE(ST_XMin(box)::text, ''), COALESCE(ST_YMin(box)::text, ''),
       COALESCE(ST_XMax(box)::text, ''), COALESCE(ST_YMax(box)::text, '')
FROM (SELECT ST_Extent(the_geom) AS box
      FROM road_network_vertices_pgr WHERE region_id = :'region') AS e;
SQL
)
  IFS=, read -r minx miny maxx maxy <<< "$extent"
  if [ -z "${minx:-}" ]; then
    echo "==> WARNING: region '$REGION' has no vertices; keeping the declared bbox $REGION_BBOX."
    return 0
  fi
  psql_local -q -v region="$REGION" -v lon_min="$minx" -v lat_min="$miny" \
    -v lon_max="$maxx" -v lat_max="$maxy" <<'SQL'
UPDATE routing_regions SET
  bbox_lon_min = :'lon_min'::double precision,
  bbox_lat_min = :'lat_min'::double precision,
  bbox_lon_max = :'lon_max'::double precision,
  bbox_lat_max = :'lat_max'::double precision
WHERE region_id = :'region';
SQL
  echo "==> Region '$REGION' bbox refreshed from ST_Extent: $minx,$miny,$maxx,$maxy"
}

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
  psql_data -q <<'SQL'
    DROP TABLE IF EXISTS ways CASCADE;
    DROP TABLE IF EXISTS ways_vertices_pgr CASCADE;
    DROP TABLE IF EXISTS configuration   CASCADE;
    DROP TABLE IF EXISTS osm_node CASCADE;
    DROP TABLE IF EXISTS osm_way CASCADE;
    DROP TABLE IF EXISTS osm_way_nodes CASCADE;
    DROP TABLE IF EXISTS osm_way_tags CASCADE;
SQL

  # osm2pgrouting prints nothing between "parsing data" and completion, which
  # can be 30+ minutes on a country-wide XML. Poll the DB every PROGRESS_INTERVAL
  # seconds and report table row/sizes so it's possible to tell "working" from
  # "stuck" (growing sizes = inserts flowing; flat sizes = still parsing XML).
  PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"
  osm2pgrouting \
    -f "$OSM_FILE" \
    -h "$DATA_HOST" \
    -p "$DATA_PORT" \
    -d "$DATA_DB" \
    -U "$DATA_USER" \
    -W "$DATA_PASSWORD" \
    --clean &
  OSM_PID=$!
  STARTED=$SECONDS
  (
    while kill -0 "$OSM_PID" 2>/dev/null; do
      sleep "$PROGRESS_INTERVAL"
      rows=$(psql_data -Atq 2>&1 <<'SQL' | tail -n 1
        SELECT COALESCE(string_agg(
                 relname || '=' || n_live_tup::text || ' rows / '
                 || pg_size_pretty(pg_total_relation_size(relid)), ', '),
               '(no tables yet — still parsing XML)')
        FROM pg_stat_user_tables
        WHERE relname IN ('osm_node', 'osm_way', 'osm_way_nodes', 'ways', 'ways_vertices_pgr');
SQL
)
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
  # Order matters on the 008 tables: plan 04 made road_edges FK
  # (region_id, source|target) -> road_vertices(region_id, id) and those FKs are
  # IMMEDIATE (not DEFERRABLE), so every edge row must already find its two
  # endpoints. Vertices first, edges second — the reverse order (what this
  # script did before plan 04) dies on the first edge with 23503.
  echo "==> Copying data into road_vertices / road_edges (migration 008) for region '$REGION'..."
  psql_data -q -v region="$REGION" <<'SQL'
    INSERT INTO road_vertices (region_id, id, geom, cnt)
    SELECT :'region', wvp.id, wvp.the_geom, wvp.cnt
    FROM ways_vertices_pgr wvp
    ON CONFLICT (region_id, id) DO NOTHING;
SQL
  psql_data -q -v region="$REGION" <<'SQL'
    INSERT INTO road_edges (
      region_id, source, target, geom, length_m, cost, reverse_cost,
      name, highway_type, max_speed_kmh, x1, y1, x2, y2
    )
    SELECT
      :'region',
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
    ON CONFLICT (region_id, id) DO NOTHING;
SQL

  echo "==> Copying data into road_network_vertices_pgr / road_network_edges_pgr (migration 011)..."
  # Region-scoped replacement for the old global TRUNCATE: only this region's
  # rows go, so a co-resident region survives the import.
  wipe_region_pgr
  psql_data -q -v region="$REGION" <<'SQL'
    INSERT INTO road_network_vertices_pgr (region_id, id, the_geom, lat, lng)
    SELECT :'region', id, the_geom, ST_Y(the_geom), ST_X(the_geom)
    FROM ways_vertices_pgr
    ON CONFLICT (region_id, id) DO NOTHING;

    -- Edge cost is the road length in meters (ways.length_m), so the
    -- accumulated routing cost == route distance in meters.
    INSERT INTO road_network_edges_pgr (region_id, id, source, target, cost)
    SELECT :'region', gid, source, target, length_m
    FROM ways
    WHERE source IS NOT NULL
      AND target IS NOT NULL
      AND length_m IS NOT NULL
      AND length_m > 0
    ON CONFLICT (region_id, id) DO NOTHING;
SQL
}

drop_raw_tables() {
  psql_data -q <<'SQL'
    DROP TABLE IF EXISTS ways CASCADE;
    DROP TABLE IF EXISTS ways_vertices_pgr CASCADE;
    DROP TABLE IF EXISTS configuration   CASCADE;
SQL
}

# ---- Decision logic ----------------------------------------------------

# Register BEFORE any wipe or import so a crashed import still leaves a
# discoverable (empty) row in routing_regions: with the row present the API
# resolves the region, sees zero coverage and returns honest straight-line
# estimates instead of silently falling back to legacy no-region routing.
register_region

if [ "$FORCE" = true ]; then
  # --force re-imports THIS region only; other regions are untouched.
  wipe_region_008
  run_osm2pgrouting
  copy_data
  drop_raw_tables

elif [ "$SKIP_OSM" = true ]; then
  echo "==> --skip-osm2pgrouting: checking for existing ways tables..."
  WAYS_EXISTS=$(psql_data -Atq <<'SQL'
    SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'ways');
SQL
)
  if [ "$WAYS_EXISTS" != "t" ]; then
    die "ways tables don't exist. Run without --skip-osm2pgrouting first."
  fi
  copy_data
  drop_raw_tables

else
  run_osm2pgrouting
  copy_data
  drop_raw_tables
fi

# The per-region GIST index, the true bbox and the row counts are settled
# only once the rows are in.
create_region_indexes
refresh_region_bbox

REGION_ROWS=$(psql_data -Atq -v region="$REGION" <<'SQL' || true
SELECT (SELECT count(*) FROM road_network_vertices_pgr WHERE region_id = :'region')::text
       || ' vertices, '
       || (SELECT count(*) FROM road_network_edges_pgr WHERE region_id = :'region')::text
       || ' edges';
SQL
)
echo "==> Done. Road network imported for region '$REGION'${DATASOURCE:+ (datasource $DATASOURCE)}."
echo "    In region: ${REGION_ROWS:-unknown}."
echo "    NOTE: the API caches road graphs in process, so restart it to route on"
echo "    the freshly imported region."
