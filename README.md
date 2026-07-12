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
                         ├── middleware (auth, rate-limit, idempotency)
                         ├── handler (auth, rider, driver, ride, geo, health, platform)
                         ├── service (auth, ride, dispatch, rider)
                         ├── repository (user_repo, ride_repo, geo_repo) ← interfaces
                         └── model (user, ride, geo, misc)
```

## Achievements

### Session 1 — Backend scaffold (initial build)

- 9 database migration sets (20+ tables: users, rides, geo, road network, etc.)
- 64+ API endpoints across auth, rider, driver, rides, geo, navigation, places, estimates, promotions, platform
- Full ride state machine: `pending → accepted → driver_arrived → in_progress → completed` (cancel from pre-in_progress)
- Dispatch system with expanding-radii search (500 m → 10 km), sequential driver offers, conflict guard
- PostGIS `ST_DWithin` nearest-driver queries, driver/rider position upserts
- JWT-based role middleware (`rider` / `driver`) enforcing endpoint access
- Sliding-window rate limiter (configurable per endpoint)
- Idempotency-key middleware (DB-backed)
- WebSocket hub with user-scoped messaging
- 37 integration tests (originally targeting live PostgreSQL)
- pgRouting road network tables with elevation cost columns (cost_elev, reverse_cost_elev)

### Session 2 — Test isolation + Flutter scaffold (this session)

- Extracted repository interfaces (`UserRepository`, `RideRepository`, `GeoRepository`)
- Wired all services and handlers to interfaces instead of concrete SQL repos
- Built in-memory mock repositories (`MockUserRepo`, `MockRideRepo`, `MockGeoRepo`)
- Rewrote test infrastructure to use mocks — tests no longer require Docker/PostgreSQL
- **36 tests: 32 pass, 2 skip** (elevation tests that genuinely need PostGIS)
- Added nil-guards to `HealthHandler.Readiness` and `Idempotency` middleware
- Extracted `router.SetupWithRepos()` for swappable dependencies
- Scaffolded Flutter rider app at [`rider_app/`](rider_app/) with `http` package and `ApiConfig`

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

## Missing features & future goals

### High priority
- **Fare calculation** — all rides created with zero fares; no distance/time/surge pricing
- **Real-time dispatch** — driver acceptance simulated with `time.Sleep`; no WebSocket push to drivers
- **Navigation/routing** — pgRouting `pgr_dijkstra` not wired; `/navigation/route` returns empty stub
- **Elevation-aware routing** — `sample_elevation()` always returns 0; no DEM integration
- **Payment integration** — tips, promos, payouts, payment methods all return `{"status":"stub"}`
- **Token refresh & logout** — `/auth/refresh` and `/auth/logout` call the login handler

### Medium priority
- **Places/geocoding** — autocomplete, geocode, details all return stubs
- **Driver vehicle & documents** — CRUD endpoints reuse the register handler; no real logic
- **Push notifications** — device token registration stored but never used
- **Promotions engine** — no discount calculation applied to rides
- **SOS workflow** — alert created but not persisted; no resolve/cancel flow
- **Admin endpoints** — no admin dashboard or management routes

### Low priority
- **Social login** — OAuth (Google, Apple) not implemented
- **Email/phone verification** — verification tables exist but no verification flow
- **Rate limiting with Redis** — currently uses in-memory maps; scales to single instance only
- **CI/CD pipeline** — no GitHub Actions, Docker build, or deployment config
- **Flutter screens** — project scaffold exists with no UI screens built yet
- **E2E tests** — no browser or device tests for the Flutter app
