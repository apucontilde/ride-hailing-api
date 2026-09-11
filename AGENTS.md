# AGENTS.md — ride-hailing-api

Operating rules for agents working in this repo. Read before changing anything.

## Repo layout

- **Go API** at repo root: `cmd/server` (entry), `internal/{config,middleware,handler,repository,service,router,routing,websocket,model,database}`.
- **Flutter monorepo (Melos 8 pub workspace)** at repo root: `pubspec.yaml` (workspace) + three packages — `rider_app/` (Riverpod + flutter_map 7 + Dio + go_router), `driver_app/` (same stack), and `shared/` (`ride_hailing_shared`) holding code shared by both apps (AuthUser/Ride models, ApiClient, AuthStorage, AppAuthController, WebSocketService, AppTheme, Validators, LocationHelper).
- **Core-file re-export convention**: both apps keep their historical import paths (`lib/core/api/api_client.dart`, `lib/core/auth/auth_provider.dart`, `lib/features/auth/model/auth_user.dart`, ...) as thin shims. The shims either re-export from `shared/` (`export 'package:ride_hailing_shared/ride_hailing_shared.dart' show <Symbol>;`) or define the app-local provider that wires shared classes to `ApiConfig.baseUrl` (`apiClientProvider`, `webSocketServiceProvider`, `authProvider`, `driverProfileProvider`). Do **not** move files out of the apps; keep the shims.
- **Plans**: `rider_app_plans/NNN_name.md` and `driver_app_plans/NNN_name.md` (numbered, newest last). Read the relevant plan before implementing or debugging a behavior.
- **Docs**: `RIDER_API_GUIDE.md`, `RIDER_APP_API_PLAN.md`, `DRIVER_APP_PLAN.md`, `USER_STORIES.md`, `data-population-plan.md`.

## Quick commands

| Task | Command |
| --- | --- |
| Start API (port 8080, live-reload) | `make run` (= `DEBUG_LOGGING=true go run ./cmd/server`) |
| Unit tests (no DB needed) | `go test -count=1 ./...` |
| Integration tests | `make test-integration` |
| Docker PostGIS + Redis | `docker compose up -d` |
| Re-seed places | `make seed` |
| Import road network | `make import-osm` (or `make import-osm-force`) |
| Download/extract SJ OSM | `make download-osm` |
| Flutter bootstrap (workspace) | `make flutter-bootstrap` |
| Analyze all Dart packages | `make flutter-analyze` |
| Test all Dart packages | `make flutter-test` |

Server config is env-driven (`internal/config/config.go`): `SERVER_PORT` (default 8080),
`DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME` (defaults `ridehail`/`ridehail_pass`/`ridehailing`
on localhost:5432), `REDIS_HOST/REDIS_PORT` (localhost:6379), `DEBUG_LOGGING`.
Containers: `ride-hailing-db` (postgis/postgis:16-3.4-alpine), `ride-hailing-redis`.

## Environment facts agents MUST know

1. **Flutter/Dart CLI is BROKEN in this WSL harness.** Every `flutter`/`dart` command fails with
   `/mnt/i/flutter/bin/internal/shared.sh: line 5: $'\r': command not found` (CRLF line endings
   in the SDK shell scripts). Do **not** run `flutter analyze`, `dart format`, `flutter test`,
   etc., and do **not** try to fix the SDK. For Dart changes rely on careful manual review,
   matching existing style, and cross-checking against the plan docs.
1b. **Run Flutter/Melos through the Windows interop.** Flutter lives at `I:\flutter`; Dart at
   `I:\flutter\bin\dart.bat`. Working equivalents: `export FLUTTER_ROOT='I:\flutter'; cmd.exe /c "I:\flutter\bin\flutter.bat <args>" | tr -d '\r'`, or `make flutter-analyze` / `make flutter-test`
   (these run Melos 8, activated globally at `C:\Users\Ricardo\AppData\Local\Pub\Cache\bin\melos.bat`,
   which invokes `flutter test`/`flutter analyze` per package under `cmd.exe`). Merge the tree by
   keep `pubspec.lock` at repo root only; per-app lockfiles are managed by Melos bootstrap.
2. **`golangci-lint` is NOT installed** — `make lint` will fail. Use `gofmt -w <files>` and
   `go vet ./...` instead. (Some pre-existing files are not gofmt-clean; only format the files
   you touch.)
3. **pgRouting is NOT available** in the DB image (`CREATE EXTENSION pgrouting` errors: control
   file missing). Routing is implemented in Go (`internal/routing`, A* over an in-memory graph).
   Do not write SQL that calls `pgr_dijkstra` expecting the real extension — the
   `road_network_*_pgr` tables are plain vertex/edge tables and the stub in migration 011 is
   unused by the code.
4. **Migrations** (`internal/database/migrate.go`): the runner embeds and executes only
   `migrations/*.up.sql` (alphabetically sorted; version = numeric prefix before the first `_`).
   `.down.sql` files are documentation only — never executed. Running the server applies
   pending migrations on startup.
5. **Road graph is cached in-process.** After `make import-osm` (or any change to
   `road_network_*_pgr`), restart the API or the route endpoint keeps serving the old graph.
6. **`scripts/init-pgrouting.sh`** tries `CREATE EXTENSION pgrouting`, which fails on the Alpine
   image; a fresh `docker compose up -d` volume may abort first-boot init. The routing feature
   does not need pgRouting, but use the plan/import flow (below), and if recreating the DB,
   reconcile that script first.
7. **Tests use mocks, not the live DB.** The `tests/` package boots a server via
   `testutil.NewTestServerE()` which passes mock repos (`MockNavigationRepo` returns a 5000 m /
   454 s route) and `db=nil`. `go test ./...` should pass without Docker/DB up. In noisy gin
   logs, filter with `grep -E "^(--- FAIL|ok|FAIL)"`.

## Routing endpoint contract

`GET /api/v1/navigation/route` — Bearer auth required (`router.go` `/api/v1/navigation` group).
Query params `from_lat`, `from_lng`, `to_lat`, `to_lng` are **mandatory and validated**
(missing/non-numeric → HTTP 422). Success (HTTP 200):

```json
{
  "polyline": [{"lat": 9.9333, "lng": -84.0833}, "...road-following points..."],
  "total_distance_m": 2094,
  "total_duration_s": 190
}
```

Polyline endpoints are pinned to the exact pickup/dropoff coords. Distance = A* edge costs
(edge `cost` = road length in meters); duration = distance / 11 m/s. No route → 500 (the app
falls back to a straight line).

## Conventions

- Go: `gofmt` formatted; small focused packages; table-driven unit tests next to the code
  (e.g. `internal/routing/routing_test.go`). `make test` must stay green.
- Dart: keep the re-export-shim structure in both apps intact (never move app files into
  `shared/`; only ever ADD code there). Shared package owns the pure core (models, client,
  storage, auth controller, ws service, theme, validators). Shared classes are parametrized
  (`ApiClient(baseUrl:)`, `WebSocketService(baseUrl:, wsPath:)`, `AppAuthController` takes
  endpoints + subclass hooks) so each app wires its own `ApiConfig`. `melos run analyze` and
  `melos run test` must stay green (via the Makefile targets above).
- Commits: short conventional messages (`feat:` / `fix:` / `docs:`), matching repo history.
- When behavior changes, update the numbered plan doc in `rider_app_plans/` or `driver_app_plans/`
  that owns it.