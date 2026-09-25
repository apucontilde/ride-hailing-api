#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Extract named POIs + address points from an OSM extract into a GeoJSON
# file consumed by the Go startup seeder (SeedPlaces).
#
# Input: first positional arg, or OSM_INPUT env var. Any OSM format
# readable by osmium (.osm.pbf, .osm.xml, ...) works. Defaults to
# data/san-jose.osm.pbf, falling back to the whole-country extract.
#
# Requires: osmium-tool
#   apt install osmium-tool   # Debian/Ubuntu
#   brew install osmium-tool  # macOS
#
# --index-type=sparse_file_array keeps the node-location index on disk instead
# of in RAM (osmium export defaults to the in-memory flex_mem index). On a
# memory-tight WSL2 the whole-country export otherwise gets OOM-killed.
# ------------------------------------------------------------------

DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"
IN="${1:-${OSM_INPUT:-}}"
FILTERED="$DATA_DIR/places-filtered.osm.pbf"
OUT="$DATA_DIR/places.geojson"

if [ -z "$IN" ]; then
  if [ -f "$DATA_DIR/san-jose.osm.pbf" ]; then
    IN="$DATA_DIR/san-jose.osm.pbf"
  elif [ -f "$DATA_DIR/costa-rica-latest.osm.pbf" ]; then
    IN="$DATA_DIR/costa-rica-latest.osm.pbf"
  else
    echo "ERROR: no OSM input found."
    echo "Usage: $0 [path/to/input.osm.pbf]  (or set OSM_INPUT=<path>)"
    echo "Or run scripts/download-osm.sh first."
    exit 1
  fi
fi
if [ ! -f "$IN" ]; then
  echo "ERROR: OSM extract not found at $IN"
  exit 1
fi
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
echo "==> Input: $IN"

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
  --geometry-types=point,polygon \
  --index-type=sparse_file_array

echo "==> Cleaning up intermediate file..."
rm -f "$FILTERED"

echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
