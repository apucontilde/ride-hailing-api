# ride-hailing-api

Go + Gin ride-hailing backend with PostGIS spatial queries, pgRouting navigation, and a companion Flutter rider app.

## Stack

- **Go 1.25 + Gin** — HTTP framework, middleware, routing
- **PostgreSQL 16 + PostGIS 3.4 + pgRouting** — geospatial storage, nearest-driver queries, road network routing
- **JWT (HS256) + bcrypt** — auth tokens, password hashing
- **WebSocket (gorilla/websocket)** — real-time driver communication
- **Flutter 3.44** — rider app (separate project at `rider_app/`)

## Architecture

```
cmd/server/main.go → internal/router/router.go
                          ├── middleware (auth, rate-limit, idempotency, debug logging)
                          ├── handler (health, auth, rider, driver, ride, geo, platform)
                          ├── service (auth, fare, navigation, ride, dispatch, rider)
                          ├── repository (user_repo, ride_repo, geo_repo, navigation_repo)
                          ├── websocket (ride offers, ride updates, driver location)
                          └── model (user, ride, geo, misc)

internal/database (Postgres connection + migrations)
```

## Goals

- Build a ride-hailing backend with PostGIS-backed geospatial queries and pgRouting-based navigation.
- Keep rider and driver flows under one auth system with role-based access control.
- Support the core trip lifecycle end to end: request, dispatch, accept, track, complete, and rate.
- Provide real-time rider-driver communication through WebSockets.
- Keep the Flutter rider app (`rider_app/`) aligned with the API surface.

## Running tests

```bash
# All tests (no infrastructure needed)
go test -v -count=1 ./...

# Run with race detector
go test -v -race -count=1 ./...
```

## Running the server

```bash
# Start PostgreSQL + Redis
docker compose up -d

# Start the API server
go run ./cmd/server

# Tests against live DB (skips mock-only tests)
go test -v -count=1 ./...
```

## Guide

```bash
make build      # compile binary
make run        # run server
make test       # run all tests
make seed       # seed test data (requires running DB)
```

## Geographic data (OSM) refresh

Places and the road network come from an OSM extract of Costa Rica
([Geofabrik](https://download.geofabrik.de/central-america/costa-rica-latest.osm.pbf)).
Use this runbook to refresh either. All inputs default to `data/san-jose.*`
and fall back to the whole-country `data/costa-rica-latest.osm.pbf`; pass a
path or `OSM_INPUT=<path>` to choose any other extract.

Prerequisites: `docker compose up -d` (DB + Redis) and `osmium`, `osmconvert`,
`osm2pgrouting`, `psql` on PATH.

### 1. Download data

```bash
make download-osm            # whole Costa Rica extract → data/costa-rica-latest.osm.pbf
make download-osm-san-jose   # same, but also clips the San José bbox → data/san-jose.osm.pbf
```

### 2. Rebuild places (POIs + addresses → GeoJSON)

```bash
cp data/places.geojson data/places-backup.geojson          # keep the old set
make export-places OSM_INPUT=data/costa-rica-latest.osm.pbf
# → rewrites data/places.geojson
```

`osmium tags-filter` is a streaming filter (low memory), but `osmium export`
assembles polygon geometries while keeping a node-location index in RAM — on a
memory-tight WSL box the whole-country run can die with `Killed`/OOM.
`export-places.sh` already uses `--index-type=sparse_file_array`, so memory
stays flat; the trouble is usually the WSL2 cap, not the tool.

**If it dies with `Killed` / OOM:**

1. **Give WSL2 more RAM.** This repo's WSL sets `memory=4GB` in
   `C:\Users\Ricardo\.wslconfig` (host has 16 GB). Raise it and add swap, then
   restart WSL (`wsl --shutdown` from PowerShell; running terminals lose state):

   ```ini
   [wsl2]
   memory=12GB
   swap=8GB
   processors=2
   ```

   Confirm with `free -h` in a new WSL window.

2. **Run the export natively in Windows** (bypasses the WSL cap; the same files
   are shared at `C:\Users\Ricardo\repos\ride-hailing-api\data\`). Grab the
   official osmium Windows build
   (`osmium-tool-*-x86_64-pc-windows-msvc.zip` from the osmcode GitHub releases),
   then from PowerShell:

   ```powershell
   osmium tags-filter data\costa-rica-latest.osm.pbf `
     nwr/name nwr/amenity nwr/shop nwr/tourism nwr/office nwr/leisure nwr/place nwr/addr:housenumber `
     -o data\places-filtered.osm.pbf --overwrite
   osmium export data\places-filtered.osm.pbf -o data\places.geojson --overwrite `
     --attributes=type,id --geometry-types=point,polygon --index-type=sparse_file_array
   Remove-Item data\places-filtered.osm.pbf
   ```

3. **Shrink the per-run footprint** (works in both places): batch by region —
   `osmium extract -b <lon,lat,lon,lat>` each area to its own pbf, export each,
   then merge:

   ```bash
   make export-places OSM_INPUT=data/san-jose.osm.pbf              # per region...
   jq -s '{type:"FeatureCollection",features:(map(.features)|add)}' \
     data/places-*.geojson > data/places.geojson                   # ...then combine
   ```

   When all you need is the San José metro, skip the whole-country write-up
   entirely — the default `make export-places` already uses
   `data/san-jose.osm.pbf`.

### 3. Re-import the road network

```bash
# Whole country (~2× San José; the pbf is expanded to a multi-GB XML first —
# expect a long import and keep disk headroom in data/)
make import-osm-force OSM_INPUT=data/costa-rica-latest.osm.pbf

# San José only:
make import-osm-force
```

This truncates and repopulates `road_edges`/`road_vertices` (migration 008)
and `road_network_vertices_pgr`/`road_network_edges_pgr` (migration 011).

### 4. Reload the API-side data

```bash
psql "$DATABASE_URL" -c "TRUNCATE places RESTART IDENTITY CASCADE;"  # seeder skips non-empty tables
make run                                                             # re-seeds places + serves the new graph
```

`SeedPlaces` runs on startup (`PLACES_SEED_ON_START=true` by default) and is
skipped when the `places` table is non-empty — hence the truncate. The road
graph is loaded lazily from PostGIS on the first `/navigation/route` call and
cached in-process, so a restart is required after any network import.

### 5. Verify

```bash
psql "$DATABASE_URL" -Atc "
  SELECT 'places', COUNT(*) FROM places
  UNION ALL SELECT 'edges_008', COUNT(*) FROM road_edges
  UNION ALL SELECT 'edges_011', COUNT(*) FROM road_network_edges_pgr
  UNION ALL SELECT 'vertices',  COUNT(*) FROM road_network_vertices_pgr;"

curl -s -H "Authorization: Bearer <token>" \
  "http://localhost:8080/api/v1/navigation/route?from_lat=9.9281&from_lng=-84.0907&to_lat=10.8055&to_lng=-85.4542"
```

A `200` with a road-following polyline (San José → Liberia) confirms the
country-wide graph; a `500`/straight-line fallback means it didn't load.

## Missing features & future goals

### High priority
- **Payment integration** — payment methods, tips, withdrawals, promos, and payouts are still stubbed
- **Places/geocoding** — autocomplete works; geocode reverse-maps a pin to the nearest place, and place details still return placeholder data
- **Driver/rider extras** — vehicle documents, earnings, ratings, favorites, and preferences are mostly stubbed
- **Safety/workflow persistence** — SOS, feedback, and device registration need durable storage and follow-up flows
- **Social login** — OAuth flows for Google/Apple are not implemented

### Medium priority
- **Admin endpoints** — no admin dashboard or management routes
- **Push notifications** — device token registration is exposed, but there is no delivery pipeline yet
- **Heatmap analytics** — endpoint exists, but it still returns placeholder imagery
- **Richer ride operations** — queueing, rider info, arrival notifications, and destination updates are thin wrappers today

### Low priority
- **Rate limiting with Redis** — current limiters are in-memory and single-instance only
- **CI/CD pipeline** — no GitHub Actions, Docker build, or deployment config
- **Flutter screens** — the companion app still needs production UI flows
- **E2E tests** — no browser or device-level tests for the Flutter app
