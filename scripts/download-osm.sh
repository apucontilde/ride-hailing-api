#!/bin/bash
set -euo pipefail

DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"
OSM_URL="https://download.geofabrik.de/central-america/costa-rica-latest.osm.pbf"
RAW_PBF="$DATA_DIR/costa-rica-latest.osm.pbf"
OUTPUT_PBF="$DATA_DIR/san-jose.osm.pbf"

# San José province bounding box (minlon,minlat,maxlon,maxlat). This avoids
# needing a separate boundary-polygon file. Swap for a precise .poly and use
# `osmium extract -p san-jose.poly` if you want exact province borders.
SAN_JOSE_BBOX="-84.50,9.00,-83.50,10.20"

if [ -f "$OUTPUT_PBF" ]; then
  echo "==> $OUTPUT_PBF already exists, skipping download+extract."
  exit 0
fi

if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
  echo "ERROR: wget or curl is required. Install one of them first."
  exit 1
fi

if ! command -v osmium &>/dev/null; then
  echo "ERROR: osmium is required. Install it with:"
  echo "  apt install osmium-tool   # Debian/Ubuntu"
  echo "  brew install osmium-tool   # macOS"
  echo "  pip install osmium         # pip"
  exit 1
fi

echo "==> Downloading Costa Rica OSM extract..."
if command -v wget &>/dev/null; then
  wget -c "$OSM_URL" -O "$RAW_PBF"
else
  curl -C - -o "$RAW_PBF" "$OSM_URL"
fi

echo "==> Extracting San José province (bbox: $SAN_JOSE_BBOX)..."
osmium extract -b "$SAN_JOSE_BBOX" "$RAW_PBF" -o "$OUTPUT_PBF"

echo "==> Cleaning up full extract..."
rm -f "$RAW_PBF"

echo "==> Done: $OUTPUT_PBF ($(du -h "$OUTPUT_PBF" | cut -f1))"
