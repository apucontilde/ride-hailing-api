Objective
- Build the complete backend API (Go + Gin) for a ride-hailing service with rider/driver apps, PostGIS geospatial queries, pgRouting navigation, and elevation-aware routing.
Important Details
- Stack: Go 1.21.5 + Gin + PostgreSQL+PostGIS+pgRouting + Redis (via Docker Compose)
- No Docker or PostgreSQL available on the dev machine — all infrastructure runs via docker-compose.yml, not installable locally
- Tests are Phase 0 (integration tests codifying behavior), written in Go _test.go files in tests/
- Rider and driver share auth (JWT access + opaque refresh tokens); role middleware separates endpoints
- State machine for rides: pending → accepted → driver_arrived → in_progress → completed (cancel allowed from pending/accepted/driver_arrived)
- Dispatch finds nearest online drivers, falls back through expanding radii (500 m → 10 km), 30 s acceptance timer
- Routing uses pgRouting (Dijkstra/A*) with elevation-aware asymmetric costs (α=0.05 uphill penalty, β=0.025 downhill reward)
- All payment, promotion, and payout endpoints return {"status":"stub","message":"Payment integration pending"}
Work State
Completed
- Initialized Go module (ride-hailing-api) and project directory structure (cmd/server, internal/{config,database/handler/middleware/model/repository/service/router/websocket}, tests/testutil, scripts)
- Wrote docker-compose.yml (postgis:16-3.4, redis:7) with init-pgrouting.sh
- Wrote 8 migration sets (001-008) creating all tables: users, auth tokens, rider/driver profiles, rides/events/ratings, geo (driver_positions, rider_positions), misc (favorites, promotions, devices, SOS, feedback, idempotency), road_network (edges + vertices with elevation)
- Wrote all Go source files: config, database/postgres+migrate, models (user, ride, geo, misc), middleware (auth, ratelimit, idempotency), repositories (user_repo, ride_repo, geo_repo), services (auth, ride, dispatch, rider), handlers (health, auth, rider, driver, geo, ride, platform), router, cmd/server/main.go
- Wrote integration test helper (tests/testutil/helpers.go) with TestServer, DoRequest, AssertStatus/AssertJSONHas/AssertJSONMissing
- Wrote 6 test files: auth_test.go (7 tests), authorization_test.go (5 tests), ride_lifecycle_test.go (7 tests), geo_test.go (4 tests), routing_test.go (3 tests), dispatch_test.go (3 tests), cross_cutting_test.go (5 tests), elevation_test.go (3 tests) — total 37 tests
- Platform handler covers all stub endpoints: SOS, feedback, device register, promotions, places, estimates, navigation (stub), heatmap, driver queue/rider-info, arrival notification, all payment-method/payout stubs
- Router registered all API endpoints from the spec (rider, driver, geo, rides, navigation, places, estimates, promotions, heatmap, platform)
Active
- Dependencies not yet fetched — go mod tidy still pending (needs network access)
- Compilation has not been run yet
- Elevation-aware routing section (6.9) appended to ride-hailing-spec.md but the Go cost tables (road_edges.cost_elev, reverse_cost_elev) exist in migration 008 only as columns — the elevation cost-population SQL (gradient, α/β formula) needs to be written as a migration or a post-import script
- routes/rides/:id/destination handler is a stub via platformHandler.UpdateDestination; not yet wired into rideService
Blocked
- Cannot run go mod tidy / go build / go test because PostgreSQL+PostGIS are not available locally (no Docker, no psql)
- Test helper NewTestServer skips tests when DB is unreachable, so tests are effectively disabled until infrastructure is provisioned
- Elevation DEM sampling (SRTM/COP-DEM) not integrated — road_vertices.elevation_m and gradient remain NULL without a data import pipeline
Next Move
1. Run go mod tidy to download all Go dependencies (requires network: gin, jwt, crypto, sqlx, lib/pq, uuid)
2. Run go build ./cmd/server to verify compilation
3. Provision PostgreSQL+PostGIS+pgRouting (via docker-compose up -d) and run migrations + seed OSM road data
4. Write the elevation cost‑population SQL migration (009) that samples DEM and computes cost_elev / reverse_cost_elev
5. Run integration tests against the live database
Relevant Files
- C:\Users\Ricardo\ride-hailing-api\cmd\server\main.go: entry point — reads config, connects DB, runs migrations, starts Gin
- C:\Users\Ricardo\ride-hailing-api\internal\router\router.go: all route registrations with middleware chains
- C:\Users\Ricardo\ride-hailing-api\internal\service\dispatch.go: nearest-driver dispatch with sequential offer + 30 s timeout + conflict guard
- C:\Users\Ricardo\ride-hailing-api\internal\service\ride.go: ride state machine with validTransitions map
- C:\Users\Ricardo\ride-hailing-api\internal\handler\geo.go: PostGIS-backed driver/rider position upserts and ST_DWithin nearby query
- C:\Users\Ricardo\ride-hailing-api\internal\handler\ride.go: ride CRUD, cancel, status advance, rate, accept, receipt, tip stub
- C:\Users\Ricardo\ride-hailing-api\internal\handler\platform.go: all stub endpoints (SOS, feedback, payments, promotions, places, etc.)
- C:\Users\Ricardo\ride-hailing-api\internal\database\migrations\008_create_road_network.up.sql: road_edges + road_vertices tables with cost_elev, reverse_cost_elev, gradient columns
- C:\Users\Ricardo\ride-hailing-api\tests\testutil\helpers.go: TestServer, TestResponse, assertion helpers
- C:\Users\Ricardo\ride-hailing-api\tests\auth_test.go: 7 auth integration tests
- C:\Users\Ricardo\ride-hailing-api\tests\ride_lifecycle_test.go: 7 ride lifecycle tests
- C:\Users\Ricardo\ride-hailing-api\tests\dispatch_test.go: 3 dispatch tests (queue, accept, conflict)
- C:\Users\Ricardo\ride-hailing-api\tests\elevation_test.go: 3 elevation tests (cost comparison, non-negative, vehicle type)
- C:\Users\Ricardo\ride-hailing-api\ride-hailing-spec.md: full API spec with Section 6.9 (elevation-aware routing)
- C:\Users\Ricardo\ride-hailing-api\ride-hailing-tasks.md: development task list with 14 phases

###     DB Preparation Steps (from a clean state)                                                                                                                       
                                                                                                                                                                        
     1. Start PostgreSQL (with PostGIS)                                                                                                                                 
        docker compose up -d                                                                                                                                            
        This starts postgis/postgis:16-3.4-alpine on port 5432. The init-pgrouting.sh script installs PostGIS, pgrouting, and other extensions.
                                                                                                                                                                        
     2. Run database migrations                                                                                                                                         
        go run ./cmd/server
        Migrations run automatically on startup (001 through 009). Alternatively, the server can be stopped after migrations complete.                                  
                                                                                                                                                                        
     3. (Optional) Seed test data                                                                                                                                       
        make seed                                                                                                                                                       
        Runs scripts/seed.sql — inserts 6 users (2 riders, 3 drivers, 1 admin), their profiles, vehicles, documents, positions, a completed ride with events/ratings,   
         promotions, SOS alerts, and device tokens. Some tests (e.g., TestGeoNearbyDriversExcludesOffline) use the seeded driver online@test.com.                       
                                                                                                                                                                        
     4. (Optional) Download OSM data for San José                                                                                                                       
        make download-osm                                                                                                                                               
        Uses scripts/download-osm.sh — downloads the Costa Rica OSM extract via wget/curl, then clips to San José province using osmium. Requires osmium-tool.          
                                                                                                                                                                        
     5. (Optional) Import road network for routing tests                                                                                                                
        make import-osm                                                                                                                                                 
        Uses scripts/import-road-network.sh — runs osm2pgrouting to populate road_edges and road_vertices tables, which are needed by elevation/routing tests.          
        Requires osm2pgrouting.                                                                                                                                         
                                                                                                                                                                        
     Note: Steps 3-5 are only needed for the subset of tests that depend on seed data or road network data. The core auth/dispatch/ride lifecycle tests work with       
     just steps 1-2.  