#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Extract named POIs + address points from the San José OSM extract
# into a GeoJSON file consumed by the Go startup seeder (SeedPlaces).
#
# Requires: osmium-tool
#   apt install osmium-tool   # Debian/Ubuntu
#   brew install osmium-tool  # macOS
# ------------------------------------------------------------------

DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"
IN="$DATA_DIR/san-jose.osm.pbf"
FILTERED="$DATA_DIR/places-filtered.osm.pbf"
OUT="$DATA_DIR/places.geojson"

if [ ! -f "$IN" ]; then
  echo "ERROR: OSM extract not found at $IN"
  echo "Run scripts/download-osm.sh first."
  exit 1
fi

if ! command -v osmium &>/dev/null; then
  echo "ERROR: osmium is required. Install it with:"
  echo "  apt install osmium-tool   # Debian/Ubuntu"
  echo "  brew install osmium-tool  # macOS"
  exit 1
fi

echo "==> Filtering named POIs + address features..."
osmium tags-filter "$IN" \
  nwr/name nwr/amenity nwr/shop nwr/tourism nwr/office nwr/leisure nwr/place nwr/addr:housenumber \
  -o "$FILTERED" --overwrite

echo "==> Exporting to GeoJSON..."
# --attributes (comma-separated list, specified ONCE) adds the OSM object type
# and id as @type / @id properties, which the Go seeder uses for idempotent
# upserts (unique (osm_type, osm_id)).
# --geometry-types=point,polygon keeps POI nodes as points and building/area
# POIs as polygons (their centroid is computed by the seeder), while dropping
# linestrings so a closed way is not emitted twice (as line + area).
osmium export "$FILTERED" -o "$OUT" --overwrite \
  --attributes=type,id \
  --geometry-types=point,polygon

echo "==> Cleaning up intermediate file..."
rm -f "$FILTERED"

echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
