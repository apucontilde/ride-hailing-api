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
