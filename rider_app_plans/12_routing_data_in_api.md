# Plan: Real Road-Network Routing in the API

Companion to plan 11 (`11_render_server_route_polyline.md`). 11 made the app *consume*
`/api/v1/navigation/route`; this plan makes the API actually **return San José route points**
so the app's polyline renders on-screen and follows roads.

## Problem

The rider app sends a San José pickup/dropoff and gets back a polyline that renders
**off-screen** (or nothing visible at all). Two compounding causes:

1. **Routing data is a demo stub.** Migration `011_create_routing.up.sql` seeds exactly
   two vertices in **NYC** (`40.7128,-74.006` / `40.758,-73.9855`) + one edge, and its
   comment states: *"demo stub (no real pgRouting graph in the dev DB)"*. The San José OSM
   road network was never imported (the import path chokes on `.osm.pbf`).
2. **No routing engine.** `pgrouting` is **not** in `pg_available_extensions` on the
   `postgis/postgis:16-3.4-alpine` DB (verified). The stub `pgr_dijkstra` function in
   migration 011 only ever returns the **two nearest vertices** — never a graph path.
   Result: for SJ coordinates it returns the NYC nodes, ~5,000 km from the SJ-centered map.

## Current State

- `internal/repository/navigation_repo.go:32` — `GetShortestPath` queries
  `road_network_vertices_pgr`/`road_network_edges_pgr` via `pgr_dijkstra`; nearest start/end
  found with KNN (`the_geom <->`); returns ordered node lat/lng list.
- `internal/service/navigation.go:24` — `GetRoute`: polyline = node list; distance = last
  `AggCost`; duration = dist / 11 m/s; errors "no route found" on empty.
- `internal/handler/platform.go:402` — `NavigationRoute` parses `from_lat/from_lng/to_lat/to_lng`
  with `fmt.Sscanf`, **silently ignores parse errors** (bad/missing → coordinates stay 0.0),
  returns 500 on routing failure.
- `internal/router/router.go:177` — `GET /api/v1/navigation/route` behind `authMw`.
- `scripts/import-road-network.sh` — imports OSM into **migration-008** tables
  (`road_vertices`/`road_edges`, which have full LINESTRING geom) but needs an **`.osm` XML
  file**; the repo has `data/san-jose.osm.pbf`. `osm2pgrouting 2.3.8` fails on the PBF
  ("not well-formed (invalid token)"). Tools available on this host: `osmium`, `osmconvert`.
- Integration tests use `MockNavigationRepo` (hardcoded 5000 m / 454 s), so they never touch
  the real DB engine — `TestNavigationRouteReturnsEdgeSequence` passes `from=`/`to=`
  ("lat,lng") params and still expects 200.
- The app (plan 11) already sends `from_lat/from_lng/to_lat/to_lng` and parses
  `{polyline:[{lat,lng}...], total_distance_m, total_duration_s}`.

## Solution

Three parts: **(1)** import the real SJ road network, **(2)** replace the stub routing with a
real shortest-path engine in the API, **(3)** validate inputs / polish the handler and tests.

### Part 1 — Import the San José road network

1. Convert the PBF so `osm2pgrouting` can read it:
   `osmium cat data/san-jose.osm.pbf -o data/san-jose.osm` (or
   `osmconvert data/san-jose.osm.pbf -o=data/san-jose.osm`). ~36 MB PBF → XML a few hundred MB.
2. Rework `scripts/import-road-network.sh`:
   - Auto-convert `.osm.pbf` → `.osm` when the XML is missing (keep `download-osm.sh` output
     unchanged; only this script consumes the XML).
   - Keep the existing copy into migration-008 `road_vertices`/`road_edges` (feeds migration 009
     elevation costs and preserves full edge geometry).
   - **Add** a copy into the migration-011 tables the API actually queries:
     - `road_network_vertices_pgr(id, the_geom, lat, lng)` ← `ways_vertices_pgr`
       (`id`, `the_geom`, `ST_Y(the_geom)`, `ST_X(the_geom)`).
     - `road_network_edges_pgr(id, source, target, cost)` ← `ways`
       (only rows with `source/target` not null).
   - `TRUNCATE road_network_vertices_pgr, road_network_edges_pgr` before copying (idempotent),
     honor existing `--force` / `--skip-osm2pgrouting` flags.
3. Add a Makefile target `import-osm-force` (default `make import-osm` stays idempotent).

**Expected outcome:** `SELECT count(*) FROM road_network_vertices_pgr;` returns thousands of
San José nodes (not 2), and edges reference them.

### Part 2 — Real shortest-path in the API (Go, A*)

pgRouting is absent from the image, so implement the engine in Go — self-contained,
unit-testable, no container changes. If pgRouting becomes available later, swap this for
SQL `pgr_dijkstra` (see Alternatives).

1. `internal/repository/navigation_repo.go`:
   - Keep `GetShortestPath` signature (callers/mocks depend on it) but change its implementation
     entirely: load the in-memory graph (below) and run A*. Add helper `NearestNode(lat, lng)`
     via KNN for snapping both endpoints.
   - Add `GetGraph()` → loads `nodes` (id,lat,lng) and `edges` (source,target,cost) with two
     indexed queries; cache in memory (loaded once; reload if empty seed was detected).
2. New `internal/service/router/` (package keeps `service` cohesive, isolated to test):
   - `Graph` built from the repo data: adjacency list keyed by node id.
   - `Route(fromLat, fromLng, toLat, toLng)` — A* with straight-line (haversine) heuristic:
     - snap `from`/`to` → nearest nodes;
     - same node → single-point path;
     - no path within a 2× euclidean distance bound → error "no route found";
     - returns ordered node IDs + cumulative cost.
   - Concurrency-safe (read-only graph, immutable after build).
3. `internal/service/navigation.go` `GetRoute`:
   - polyline = `[pickup point] + node sequence + [dropoff point]` so the drawn line connects
     to the two pins;
   - `DistanceMeters` = final cumulative cost; `DurationSecs` = distance / 11 m/s (unchanged
     approximation; per-road-class speeds are a separate enhancement);
   - empty path → error (handler maps to 400/500).
4. Unit tests: `internal/service/router/router_test.go` — tiny hand-built graph (2–6 nodes):
   - direct neighbor path order + cost;
   - multi-hop path (A→B→C) with correct order;
   - unreachable target errors;
   - same start/end returns single point.

### Part 3 — Handler validation + tests

1. `internal/handler/platform.go:402` — validate all four params (`from_lat`, `from_lng`,
   `to_lat`, `to_lng`); missing/non-numeric → **422** `{"error": ...}` instead of silent `0.0`.
   Keep the response shape identical (`{polyline, total_distance_m, total_duration_s}`).
2. `tests/routing_test.go` `TestNavigationRouteReturnsEdgeSequence`:
   - use canonical `from_lat/from_lng/to_lat/to_lng` params;
   - assert 422 when a coordinate is missing;
   - keep 200 + both fields assertions (mock nav repo still supplies 5000 m / 454 s — engine
     swap is invisible to tests).
3. Keep `mock_navigation_repo.go` untouched.

## Verification

1. **Data:** `PGPASSWORD=ridehail_pass psql -h localhost -U ridehail -d ridehailing -Atc "SELECT count(*) FROM road_network_vertices_pgr; SELECT count(*) FROM road_network_edges_pgr;"` → 1,000s of rows / 1,000s of edges (no longer 2/1).
2. **API** (after `make run`):
   - register+login a rider, then
   - `GET /api/v1/navigation/route?from_lat=9.9331&from_lng=-84.0796&to_lat=9.9400&to_lng=-84.0600` with `Authorization: Bearer <token>` → 200, `polyline` ≥ 2 points **inside San José bbox**, `total_distance_m > 0`, `total_duration_s > 0`.
   - missing `to_lng` → 422.
3. **App:** run rider_app on the SJ default region, set pickup+dropoff → blue polyline follows
   roads between the pins; loading (grey) and error (straight) fallbacks from plan 11 still work.
4. **Tests:** `make test` and `make test-integration` green.

## Alternatives considered

- **Install pgRouting in the Alpine container** (`apk add postgresql16-pgrouting`,
  rebuild/restart, add to `docker-compose.yml`): real `pgr_dijkstra`, least custom Go code.
  Rejected for now: package availability in the postgis Alpine repo is unverified, requires a
  container rebuild + recipe changes, and adds ops drift. Preferred as a follow-up swap once
  verified — the repository boundary already isolates it.
- **OSRM / Valhalla as a sidecar service:** best real-world scaling, real-time, but overkill
  for the dev sandbox and adds a service to operate.
- **Client-side estimate (previous discussion):** instant, offline, but not a genuine road
  route — keep it as the app's *error fallback* only, never the source of truth.

## Files to modify (summary)

- `scripts/import-road-network.sh` — PBF→OSM auto-convert + copy into 011 tables (`--force` aware)
- `Makefile` — optional `import-osm-force` target
- `internal/repository/navigation_repo.go` — `GetShortestPath` reimplementation + `GetGraph`/`NearestNode`
- `internal/service/router/` (new) — graph + A* + unit tests
- `internal/service/navigation.go` — pin endpoints in polyline, wire new engine
- `internal/handler/platform.go:402` — strict param validation (422)
- `tests/routing_test.go` — canonical params + 422 assertion
- (optional, follow-up) migration `012_*.up.sql` — drop stub `pgr_dijkstra`, add `the_geom`
  LINESTRING to `road_network_edges_pgr` for along-edge polyline interpolation