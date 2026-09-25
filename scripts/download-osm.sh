#!/bin/bash
set -euo pipefail

DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"
OSM_URL="https://download.geofabrik.de/central-america/costa-rica-latest.osm.pbf"
COUNTRY_PBF="$DATA_DIR/costa-rica-latest.osm.pbf"
SAN_JOSE_PBF="$DATA_DIR/san-jose.osm.pbf"

# San José province bounding box (minlon,minlat,maxlon,maxlat). This avoids
# needing a separate boundary-polygon file. Swap for a precise .poly and use
# `osmium extract -p san-jose.poly` if you want exact province borders.
SAN_JOSE_BBOX="-84.50,9.00,-83.50,10.20"

# Default: keep the whole-country extract. Pass --san-jose to clip it down
# to the San José bbox instead (produces san-jose.osm.pbf).
EXTRACT_SAN_JOSE=false
for arg in "$@"; do
  case "$arg" in
    --san-jose) EXTRACT_SAN_JOSE=true ;;
    -h|--help)
      echo "Usage: $0 [--san-jose]"
      echo "  (default)  Download the whole Costa Rica OSM extract (costa-rica-latest.osm.pbf)."
      echo "  --san-jose Also clip it to the San José bbox (san-jose.osm.pbf)."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--san-jose]" >&2
      exit 1
      ;;
  esac
done

if [ "$EXTRACT_SAN_JOSE" = true ] && [ -f "$SAN_JOSE_PBF" ]; then
  echo "==> $SAN_JOSE_PBF already exists, skipping download+extract."
  exit 0
fi

if [ "$EXTRACT_SAN_JOSE" = false ] && [ -f "$COUNTRY_PBF" ]; then
  echo "==> $COUNTRY_PBF already exists, skipping download."
  echo "    Delete it if you want a fresh (newer) country extract."
  exit 0
fi

if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
  echo "ERROR: wget or curl is required. Install one of them first."
  exit 1
fi

if [ "$EXTRACT_SAN_JOSE" = true ] && ! command -v osmium &>/dev/null; then
  echo "ERROR: osmium is required for --san-jose. Install it with:"
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

if [ "$EXTRACT_SAN_JOSE" = true ]; then
  echo "==> Extracting San José province (bbox: $SAN_JOSE_BBOX)..."
  osmium extract -b "$SAN_JOSE_BBOX" "$COUNTRY_PBF" -o "$SAN_JOSE_PBF"
  echo "==> Done: $SAN_JOSE_PBF ($(du -h "$SAN_JOSE_PBF" | cut -f1))"
  echo "    Country extract kept at $COUNTRY_PBF ($(du -h "$COUNTRY_PBF" | cut -f1))."
else
  echo "==> Done: $COUNTRY_PBF ($(du -h "$COUNTRY_PBF" | cut -f1))"
fi
