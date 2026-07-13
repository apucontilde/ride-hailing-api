
# Part A — Backend (ride-hailing-api)
## T1. Migration: places table with PostGIS + full-text
Create internal/database/migrations/010_create_places.up.sql:
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE places (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    osm_type   TEXT NOT NULL,
    osm_id     BIGINT NOT NULL,
    name       TEXT NOT NULL,
    category   TEXT NOT NULL DEFAULT 'poi',
    address    TEXT,
    location   GEOGRAPHY(Point, 4326) NOT NULL,
    search_tsv TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple', coalesce(name,'') || ' ' || coalesce(address,''))
    ) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (osm_type, osm_id)
);

CREATE INDEX idx_places_location ON places USING GIST (location);
CREATE INDEX idx_places_search_tsv ON places USING GIN (search_tsv);
CREATE INDEX idx_places_name_trgm ON places USING GIN (name gin_trgm_ops);
Also create internal/database/migrations/010_create_places.down.sql (for consistency with existing convention, even though only .up.sql runs):
DROP TABLE IF EXISTS places;
Notes: gen_random_uuid() comes from pgcrypto (already enabled in 001). Migrations auto-run on startup via migrate.go:22-67. Filename prefix 010 sorts after 009.
T2. OSM POI + address extraction script
Create scripts/export-places.sh (mirror style of scripts/download-osm.sh). It filters data/san-jose.osm.pbf and exports GeoJSON:
#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"
IN="$DATA_DIR/san-jose.osm.pbf"
FILTERED="$DATA_DIR/places-filtered.osm.pbf"
OUT="$DATA_DIR/places.geojson"

# Keep named POIs across common categories + address-carrying features
osmium tags-filter "$IN" \
  nwr/name nwr/amenity nwr/shop nwr/tourism nwr/office nwr/leisure nwr/place nwr/addr:housenumber \
  -o "$FILTERED" --overwrite

# Export to GeoJSON (points from nodes; ways/relations exported as their geometry)
osmium export "$FILTERED" -o "$OUT" --overwrite \
  --add-unique-id=type_id \
  -a type -a id
echo "wrote $OUT"
Add a Makefile target (after line 42 in Makefile) and to .PHONY:
export-places:
	./scripts/export-places.sh
Committed data/places.geojson lets the Go seeder run without OSM tooling on the server.
T3. Config additions
In internal/config/config.go:
- Add fields to Config struct (after DebugLogging, line 33):
	PlacesSeedOnStart bool
	PlacesGeoJSONPath string
	PlacesMaxRadiusM  float64
	PlacesDefaultLimit int
- Add to Load() return (after line 61):
		PlacesSeedOnStart:  getEnv("PLACES_SEED_ON_START", "true") == "true",
		PlacesGeoJSONPath:  getEnv("PLACES_GEOJSON_PATH", "data/places.geojson"),
		PlacesMaxRadiusM:   float64(getInt("PLACES_MAX_RADIUS_M", 50000)),
		PlacesDefaultLimit: getInt("PLACES_DEFAULT_LIMIT", 10),
Document all four in .env.example.
T4. Model
Create internal/model/places.go:
package model

type Place struct {
	ID       string  `db:"id" json:"id"`
	Name     string  `db:"name" json:"name"`
	Category string  `db:"category" json:"category"`
	Address  *string `db:"address" json:"address"`
	Lat      float64 `db:"lat" json:"lat"`
	Lng      float64 `db:"lng" json:"lng"`
}

type NearbyPlaceResult struct {
	Place
	DistanceM float64 `db:"distance_m" json:"distance_m"`
	Rank      float64 `db:"rank" json:"rank"`
}
T5. Repository
Create internal/repository/places_repo.go (mirror geo_repo.go pattern, args passed as lng,lat to match ST_MakePoint):
package repository

import (
	"fmt"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

type PlacesRepository interface {
	FindNearbyPlaces(lat, lng, radiusM float64, query string, limit int) ([]model.NearbyPlaceResult, error)
	CountPlaces() (int, error)
	BulkInsert(places []model.PlaceSeed) (int, error)
}

var _ PlacesRepository = (*PlacesRepo)(nil)

type PlacesRepo struct {
	db *sqlx.DB
}

func NewPlacesRepo(db *sqlx.DB) *PlacesRepo { return &PlacesRepo{db: db} }

func (r *PlacesRepo) FindNearbyPlaces(lat, lng, radiusM float64, query string, limit int) ([]model.NearbyPlaceResult, error) {
	var results []model.NearbyPlaceResult
	sql := `
		SELECT id, name, category, address,
		       ST_X(location::GEOMETRY) AS lng,
		       ST_Y(location::GEOMETRY) AS lat,
		       ST_Distance(location, ST_SetSRID(ST_MakePoint($1,$2),4326)::GEOGRAPHY) AS distance_m,
		       CASE WHEN $4 = '' THEN 0
		            ELSE ts_rank(search_tsv, plainto_tsquery('simple', $4)) END AS rank
		FROM places
		WHERE ST_DWithin(location, ST_SetSRID(ST_MakePoint($1,$2),4326)::GEOGRAPHY, $3)
		  AND ($4 = '' OR search_tsv @@ plainto_tsquery('simple', $4))
		ORDER BY rank DESC, distance_m ASC
		LIMIT $5`
	if err := r.db.Select(&results, sql, lng, lat, radiusM, query, limit); err != nil {
		return nil, fmt.Errorf("failed to find nearby places: %w", err)
	}
	return results, nil
}

func (r *PlacesRepo) CountPlaces() (int, error) {
	var n int
	err := r.db.Get(&n, `SELECT COUNT(*) FROM places`)
	return n, err
}
// BulkInsert implemented in T6 (or here) using ON CONFLICT DO NOTHING.
model.PlaceSeed struct (add to model/places.go): OSMType, Name, Category string; OSMID int64; Address *string; Lat, Lng float64.
T6. Startup seeder (Go, idempotent)
Create internal/database/seed_places.go:
- SeedPlaces(db *sqlx.DB, cfg *config.Config) error:
1. If !cfg.PlacesSeedOnStart → return nil.
2. SELECT COUNT(*) FROM places; if > 0 → log "places already seeded" and return nil.
3. Read cfg.PlacesGeoJSONPath with os.ReadFile; if file missing → log warning, return nil (don't crash startup).
4. Parse GeoJSON FeatureCollection with encoding/json (no new deps). For each feature:
- Derive a representative point: Point → use coords; Polygon/LineString/MultiPolygon → compute centroid (average of coordinates) in Go.
- name = properties.name; skip features without a name unless they carry addr:housenumber — for those, set name = addr:street + " " + addr:housenumber and category = "address".
- category = first present of amenity/shop/tourism/office/leisure/place, else poi/address.
- address = compose from addr:street, addr:housenumber, addr:city when present.
- osm_type/osm_id from the type/id props added by --add-unique-id.
5. Bulk insert in batches (e.g., 500 rows) with:
INSERT INTO places (osm_type, osm_id, name, category, address, location)
VALUES ($1,$2,$3,$4,$5, ST_SetSRID(ST_MakePoint($6,$7),4326)::GEOGRAPHY)
ON CONFLICT (osm_type, osm_id) DO NOTHING
6. Log inserted count.
- Wire into cmd/server/main.go after migrations (main.go:22), before router.Setup:
	if err := database.SeedPlaces(db, cfg); err != nil {
		log.Fatalf("failed to seed places: %v", err)
	}
T7. Handler: replace PlacesAutocomplete stub
In internal/handler/platform.go:
- Add dependency to the handler struct (line 11-17):
type PlatformHandler struct {
	navSvc     *service.NavigationService
	placesRepo repository.PlacesRepository
	maxRadiusM float64
	defaultLimit int
}

func NewPlatformHandler(navSvc *service.NavigationService, placesRepo repository.PlacesRepository, maxRadiusM float64, defaultLimit int) *PlatformHandler {
	return &PlatformHandler{navSvc: navSvc, placesRepo: placesRepo, maxRadiusM: maxRadiusM, defaultLimit: defaultLimit}
}
  (add "strconv" and repository imports.)
- Replace PlacesAutocomplete (lines 79-81), mirroring geo.go:97-129:
func (h *PlatformHandler) PlacesAutocomplete(c *gin.Context) {
	lat, err := strconv.ParseFloat(c.Query("lat"), 64)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lat"}})
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lng"}})
		return
	}
	radius := 1000.0
	if r := c.Query("radius"); r != "" {
		radius, _ = strconv.ParseFloat(r, 64)
	}
	if radius > h.maxRadiusM {
		radius = h.maxRadiusM
	}
	query := c.Query("q")
	limit := h.defaultLimit
	if l := c.Query("limit"); l != "" {
		limit, _ = strconv.Atoi(l)
	}
	if limit > 50 {
		limit = 50
	}
	places, err := h.placesRepo.FindNearbyPlaces(lat, lng, radius, query, limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to query places"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"places": places})
}
- Leave PlacesGeocode/PlacesDetails as stubs (out of scope) or optionally implement details via a GetPlaceByID. Note as optional.
T8. Router wiring + tests
In internal/router/router.go:
- Setup (lines 16-24): add repository.NewPlacesRepo(db) to the args passed to SetupWithRepos.
- SetupWithRepos signature (line 26): add placesRepo repository.PlacesRepository.
- Update platformHandler construction (line 54):
	platformHandler := handler.NewPlatformHandler(navService, placesRepo, cfg.PlacesMaxRadiusM, cfg.PlacesDefaultLimit)
- Route already exists (line 159): places.GET("/autocomplete", platformHandler.PlacesAutocomplete) — no change needed.
- Tests: add MockPlacesRepo to tests/testutil/mock_repos.go; update every SetupWithRepos(...) call site (tests) to pass the mock; add a unit/integration test asserting GET /api/v1/places/autocomplete?lat&lng&q returns {"places":[...]} and validation errors for missing lat/lng. Run make test.
Part B — App (rider_app)
T9. Remove Nominatim geocoding logic
In lib/features/home/data/home_provider.dart, delete the entire placeSearchProvider (lines 32-107). It will be replaced in T11. Remove now-unused import 'package:dio/dio.dart'; only if no longer referenced (it is still used by Options in RideCreationNotifier, so keep it).
T10. Drop unused dependency
In pubspec.yaml, remove geocoding: ^3.0.0 (line 42) — confirmed unused. Run flutter pub get.
T11. New backend-backed place search provider with client-side radius escalation
Add to lib/features/home/data/home_provider.dart:
class PlaceSearchArgs {
  final String query;
  final double lat;
  final double lng;
  const PlaceSearchArgs({required this.query, required this.lat, required this.lng});

  @override
  bool operator ==(Object o) =>
      o is PlaceSearchArgs && o.query == query && o.lat == lat && o.lng == lng;
  @override
  int get hashCode => Object.hash(query, lat, lng);
}

const _radiusSteps = [1000.0, 3000.0, 10000.0, 30000.0]; // last = max

final placeSearchProvider =
    FutureProvider.family<List<Place>, PlaceSearchArgs>((ref, args) async {
  if (args.query.trim().isEmpty) return [];
  final apiClient = ref.read(apiClientProvider);
  for (final radius in _radiusSteps) {
    final response = await apiClient.dio.get(
      ApiEndpoints.placesAutocomplete,
      queryParameters: {
        'lat': args.lat,
        'lng': args.lng,
        'radius': radius,
        'q': args.query,
        'limit': 10,
      },
    );
    final list = (response.data['places'] as List<dynamic>? ?? [])
        .map((j) => Place.fromJson(j as Map<String, dynamic>))
        .toList();
    if (list.isNotEmpty) return list;
  }
  return [];
});
This uses the shared Dio instance, so the existing auth interceptor (api_client.dart:26-35) attaches the Bearer token automatically.
T12. Place model — map new fields
lib/features/home/model/place.dart:16-24 already reads id/name/address/lat/lng. Add optional category/distanceM fields for display (nearest-first UI):
  final String? category;
  final double? distanceM;
Update constructor + fromJson to read json['category'] and (json['distance_m'] as num?)?.toDouble().
T13. Pass GPS + hint into the search screen
The search needs the user's current GPS. Update the route to accept extra.
- lib/core/router/app_router.dart (lines 53-56):
      GoRoute(
        path: '/location-search',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return LocationSearchScreen(
            hint: extra?['hint'] as String? ?? 'Search destinations...',
            lat: extra?['lat'] as double?,
            lng: extra?['lng'] as double?,
          );
        },
      ),
- lib/features/home/presentation/location_search_screen.dart:
- Add final double? lat; final double? lng; fields + constructor params (line 8-10).
- In build (line 28), fall back to a sane default when GPS is missing, then watch the new provider:
final lat = widget.lat, lng = widget.lng;
final placesAsync = (lat == null || lng == null)
    ? const AsyncValue.data(<Place>[])
    : ref.watch(placeSearchProvider(
        PlaceSearchArgs(query: _query, lat: lat, lng: lng)));
- When GPS is null, show a message ("Enable location to search nearby").
T14. Pass current position from home screen
In lib/features/home/presentation/home_screen.dart, both _buildLocationField onTap handlers (lines 196-205 pickup, 213-219 destination) call context.push<Place>('/location-search'). Update both to pass GPS + hint:
final origin = _pickupLocation != null
    ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
    : _currentPosition;
final place = await context.push<Place>('/location-search', extra: {
  'hint': 'Pickup location', // or 'Where to?'
  'lat': origin?.latitude,
  'lng': origin?.longitude,
});
Guard: if origin == null, show the existing "Could not determine your location" snackbar and skip navigation (search requires GPS).
T15. Cleanup
- Confirm ApiEndpoints.placesAutocomplete (endpoints.dart:11) is now referenced (it is, via T11).
- Remove leftover print debug lines (they were in the deleted Nominatim block).
- Search the repo for any other references to nominatim / old placeSearchProvider(String) signature and update call sites (only location_search_screen.dart used it).
Verification checklist
Backend
1. make export-places (once, needs osmium) → produces data/places.geojson.
2. make run → observe migration 010 applied + "seeded N places" log.
3. curl "http://localhost:8080/api/v1/places/autocomplete?lat=9.93&lng=-84.08&q=super&radius=2000" -H "Authorization: Bearer <token>" → returns {"places":[...]} nearest-first.
4. make test passes (including new places test + updated SetupWithRepos call sites).
App
5. flutter pub get then flutter analyze (no unused-import/dep warnings).
6. Login → home → tap Pickup/Destination → type a query → results come from our API (verify network hits /api/v1/places/autocomplete, not nominatim), nearest returned, radius escalates when no local match.
7. Selecting a place still drives the estimate + ride-creation flow unchanged.
Suggested execution order
T1 → T2 → T3 → T4 → T5 → T6 → (verify seed) → T7 → T8 → (verify API) → T10 → T12 → T11 → T9 → T13 → T14 → T15 → (verify app).


Part A-bis — Alternative: seed the road network via a Go startup seeder
Why
scripts/import-road-network.sh requires osm2pgrouting + psql + a live DB on whatever machine runs the import, hardcodes a WSL path (import-road-network.sh:26), and builds topology at import time. The places pattern instead preprocesses once, commits a portable data file, and loads it idempotently on startup. Applying that here removes runtime tooling from deploy environments and unifies seeding.
Schema constraints that shape the design (from 008_create_road_network.up.sql)
- road_vertices(id BIGSERIAL PK, geom POINT 4326, cnt, elevation_m).
- road_edges(... source/target BIGINT REFERENCES road_vertices(id), geom LINESTRING 4326, length_m, cost, reverse_cost, name, highway_type, max_speed_kmh, x1..y2, gradient, cost_elev, reverse_cost_elev).
- FK edges→vertices ⇒ vertices must load first, and original ids must be preserved.
- 009_compute_elevation_costs fills gradient/cost_elev/reverse_cost_elev — bake these into the dump (see ordering note).
Two phases
Phase 1 — offline export (one-time / on OSM refresh; dev or CI)
New scripts/export-road-network.sh:
1. Build the processed tables once using the existing pipeline (either call ./scripts/import-road-network.sh against a scratch DB, then let migration 009 run so elevation columns are populated).
2. Dump the two already-processed tables to newline-delimited JSON with geometry as WKT, committed under data/:
#!/bin/bash
set -euo pipefail
DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"
psql_run() { PGPASSWORD="${DB_PASSWORD:-ridehail_pass}" psql -h "${DB_HOST:-localhost}" -p "${DB_PORT:-5432}" \
  -U "${DB_USER:-ridehail}" -d "${DB_NAME:-ridehailing}" -Atc "$1"; }

psql_run "COPY (SELECT row_to_json(v) FROM (
    SELECT id, cnt, elevation_m, ST_AsText(geom) AS geom_wkt FROM road_vertices
  ) v) TO STDOUT" > "$DATA_DIR/road_vertices.ndjson"

psql_run "COPY (SELECT row_to_json(e) FROM (
    SELECT id, source, target, length_m, cost, reverse_cost, name, highway_type,
           max_speed_kmh, x1, y1, x2, y2, gradient, cost_elev, reverse_cost_elev,
           ST_AsText(geom) AS geom_wkt FROM road_edges
  ) e) TO STDOUT" > "$DATA_DIR/road_edges.ndjson"

gzip -f "$DATA_DIR/road_vertices.ndjson" "$DATA_DIR/road_edges.ndjson"
echo "wrote road_vertices.ndjson.gz and road_edges.ndjson.gz"
Ship data/road_vertices.ndjson.gz and data/road_edges.ndjson.gz (gzip because the edge table is large; consider Git LFS).
Phase 2 — startup seeder (Go, idempotent; mirrors T6)
New internal/database/seed_road_network.go — SeedRoadNetwork(db *sqlx.DB, cfg *config.Config) error:
1. If !cfg.RoadSeedOnStart → return nil.
2. SELECT COUNT(*) FROM road_edges; if > 0 → log "road network already seeded", return nil (same guard as import-road-network.sh:62,142).
3. Open the gz files (os.Open + gzip.NewReader + bufio.Scanner); if missing → log warning, return nil (don't crash).
4. Insert vertices first (FK) with explicit ids, batched (use pq.CopyIn or ~1000-row multi-VALUES):
INSERT INTO road_vertices (id, geom, cnt, elevation_m)
VALUES ($1, ST_GeomFromText($2,4326), $3, $4)
ON CONFLICT (id) DO NOTHING
5. Then insert edges with explicit ids + source/target:
INSERT INTO road_edges (id, source, target, geom, length_m, cost, reverse_cost,
    name, highway_type, max_speed_kmh, x1, y1, x2, y2, gradient, cost_elev, reverse_cost_elev)
VALUES ($1,$2,$3, ST_GeomFromText($4,4326), $5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
ON CONFLICT (id) DO NOTHING
6. Resync sequences after explicit-id inserts (both are BIGSERIAL):
SELECT setval(pg_get_serial_sequence('road_vertices','id'), (SELECT COALESCE(MAX(id),1) FROM road_vertices));
SELECT setval(pg_get_serial_sequence('road_edges','id'),    (SELECT COALESCE(MAX(id),1) FROM road_edges));
7. Log inserted counts. Wrap the whole thing in one transaction.
Models (internal/model/road.go) — two structs with json tags matching the dump (id, cnt, elevation_m, geom_wkt and the full edge row incl. geom_wkt).
Wiring & config
- cmd/server/main.go: call after SeedPlaces (which is after migrations):
	if err := database.SeedRoadNetwork(db, cfg); err != nil {
		log.Fatalf("failed to seed road network: %v", err)
	}
- internal/config/config.go: add RoadSeedOnStart bool, RoadVerticesPath string (default data/road_vertices.ndjson.gz), RoadEdgesPath string (default data/road_edges.ndjson.gz); document in .env.example.
- Makefile: add export-road-network target (+ .PHONY); keep import-osm or mark it deprecated in favor of the seeder.

Use the Go seeder as the default path for parity with places and dependency-free deploys, but keep import-road-network.sh as the offline generator that export-road-network.sh consumes. Given the edge dump size, gzip is essential and Git LFS is worth considering.
Verification
1. Offline: make import-osm (or run the script) → migration 009 populated → make export-road-network → gz files appear in data/.
2. Fresh DB + make run → logs: migrations, "seeded N places", "seeded V vertices / E edges", sequence resync.
3. SELECT COUNT(*) FROM road_edges; matches the source; GET /api/v1/navigation/route?... returns a real polyline (routing works against seeded topology).
4. Restart → seeder logs "already seeded" and skips (idempotent).
Two decisions worth your call before this is executed:
- Big-file strategy: gzip in data/ (simple) vs Git LFS (cleaner history) vs a release-artifact download step in the seeder?
- Keep or retire import-road-network.sh: keep it purely as the offline generator, or fully replace it?