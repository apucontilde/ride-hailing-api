#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../data"
if [ -d "$DATA_DIR" ]; then
  DATA_DIR="$(cd "$DATA_DIR" && pwd)"
fi
OSM_URL="https://download.geofabrik.de/central-america/costa-rica-latest.osm.pbf"
COUNTRY_PBF="$DATA_DIR/costa-rica-latest.osm.pbf"

# San José province bounding box (minlon,minlat,maxlon,maxlat). This avoids
# needing a separate boundary-polygon file. Swap for a precise .poly and use
# `osmium extract -p san-jose.poly` if you want exact province borders.
SAN_JOSE_BBOX="-84.50,9.00,-83.50,10.20"
# It must stay in sync with --region cr-sj's default --bbox in
# scripts/import-road-network.sh: this is the box the extract is clipped to and
# the box the registry records.
SAN_JOSE_PBF="$DATA_DIR/san-jose.osm.pbf"

usage() {
  echo "Usage: $0 [--san-jose | --region <id> --bbox <minLon,minLat,maxLon,maxLat>]"
  echo ""
  echo "  (default)          Download the whole Costa Rica OSM extract"
  echo "                     (costa-rica-latest.osm.pbf) and stop."
  echo "  --san-jose         Clip the extract to the San José province box"
  echo "                     (san-jose.osm.pbf)."
  echo "  --region <id>      Region id the clip belongs to. With --bbox it names"
  echo "                     the clip and the output file (<id>.osm.pbf); the id"
  echo "                     is what you hand to import-road-network.sh --region."
  echo "  --bbox <box>       minLon,minLat,maxLon,maxLat to clip to. Implies"
  echo "                     --extract and replaces the San José default."
  echo "  -h, --help         This text."
}

# Default: keep the whole-country extract. Pass --san-jose to clip it down
# to the San José bbox instead (produces san-jose.osm.pbf).
EXTRACT=false
REGION=""
BBOX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --san-jose)
      EXTRACT=true
      REGION="${REGION:-cr-sj}"
      BBOX="${BBOX:-$SAN_JOSE_BBOX}"
      shift
      ;;
    --region)
      [ $# -ge 2 ] || { echo "ERROR: --region needs a value" >&2; exit 1; }
      REGION="$2"
      # A --region with no --bbox is a labeling request: the extract is only
      # clipped when a box is given. Keeps `--region cr` (country-wide) usable.
      shift 2
      ;;
    --bbox)
      [ $# -ge 2 ] || { echo "ERROR: --bbox needs a value" >&2; exit 1; }
      BBOX="$2"
      EXTRACT=true
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -n "$BBOX" ] && ! [[ "$BBOX" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
  echo "ERROR: --bbox must be minLon,minLat,maxLon,maxLat (got '$BBOX')" >&2
  exit 1
fi
if [ -n "$REGION" ]; then
  case "$REGION" in
    *[!A-Za-z0-9_-]*|"") echo "ERROR: --region must match [A-Za-z0-9_-]+ (got '$REGION')" >&2; exit 1 ;;
  esac
fi
if [ -n "$BBOX" ] && [ -z "$REGION" ]; then
  # A clip without a region id produces an unnamed file the importer can't
  # address, so insist on the id that will own it.
  echo "ERROR: --bbox needs --region <id> (the clip is named after the region)" >&2
  exit 1
fi

# --san-jose keeps its historical filename; every other region gets <id>.osm.pbf
# so two regions' extracts can sit in data/ side by side.
CLIP_PBF="$SAN_JOSE_PBF"
if [ -n "$REGION" ] && [ "$REGION" != "cr-sj" ]; then
  CLIP_PBF="$DATA_DIR/$REGION.osm.pbf"
fi

if [ "$EXTRACT" = false ] && [ -f "$COUNTRY_PBF" ]; then
  echo "==> $COUNTRY_PBF already exists, skipping download."
  echo "    Delete it if you want a fresh (newer) country extract."
  exit 0
fi
if [ "$EXTRACT" = true ] && [ -f "$CLIP_PBF" ]; then
  echo "==> $CLIP_PBF already exists, skipping download+extract."
  echo "    Delete it to re-clip, or add --bbox to pick a different box."
  exit 0
fi

if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
  echo "ERROR: wget or curl is required. Install one of them first."
  exit 1
fi

if [ "$EXTRACT" = true ] && ! command -v osmium &>/dev/null; then
  echo "ERROR: osmium is required to clip an extract. Install it with:"
  echo "  apt install osmium-tool   # Debian/Ubuntu"
  echo "  brew install osmium-tool   # macOS"
  echo "  pip install osmium         # pip"
  exit 1
fi

if [ ! -f "$COUNTRY_PBF" ]; then
  echo "==> Downloading Costa Rica OSM extract..."
  if command -v wget &>/dev/null; then
    wget -c "$OSM_URL" -O "$COUNTRY_PBF"
  else
    curl -L -C - -o "$COUNTRY_PBF" "$OSM_URL"
  fi
else
  echo "==> Reusing existing $COUNTRY_PBF."
fi

if [ "$EXTRACT" = true ]; then
  echo "==> Extracting region '${REGION:-san-jose}' (bbox: $BBOX)..."
  osmium extract -b "$BBOX" "$COUNTRY_PBF" -o "$CLIP_PBF"
  echo "==> Done: $CLIP_PBF ($(du -h "$CLIP_PBF" | cut -f1))"
  echo "    Country extract kept at $COUNTRY_PBF ($(du -h "$COUNTRY_PBF" | cut -f1))."
  if [ -n "$REGION" ]; then
    echo "    Import it with:"
    echo "      ./scripts/import-road-network.sh --region $REGION --bbox $BBOX $CLIP_PBF"
  fi
else
  echo "==> Done: $COUNTRY_PBF ($(du -h "$COUNTRY_PBF" | cut -f1))"
fi
