# AGENTS.md — ride-hailing-api

Operating rules for agents working in this repo. Read before changing anything.

## Repo layout

- **Go API** at repo root: `cmd/{server,e2eserver,elevtool,openapi}` (entry `cmd/server`),
  `internal/{config,middleware,handler,repository,service,router,routing,websocket,model,database}`.
- **Flutter monorepo (Melos 8 pub workspace)**: `pubspec.yaml` + three packages — `rider_app/` and
  `driver_app/` (Riverpod + flutter_map 7 + Dio + go_router) and `shared/` (`ride_hailing_shared`)
  with the code both apps use (models, ApiClient, AuthStorage, AppAuthController, WebSocketService,
  AppTheme, Validators, LocationHelper) plus the shared UI core from the `[nav]` chain
  (`AppSidebar`/`AppNav*`, `AppSettings*`, `AppProfile*`, `performAppSignOut`).
- **Core-file re-export convention**: both apps keep their historical import paths
  (`lib/core/api/api_client.dart`, ...) as thin shims that re-export from `shared/` or define the
  app-local provider wiring shared classes to `ApiConfig.baseUrl` (`apiClientProvider`,
  `webSocketServiceProvider`, `authProvider`, `driverProfileProvider`). Do **not** move files out, and
  do not mint a shim for a new symbol: import it straight from the unfiltered barrel
  `package:ride_hailing_shared/ride_hailing_shared.dart` (the barrel still gains one `export` line per
  new shared file).
- **Plans**: three domains — `api_plans/`, `rider_app_plans/`, `driver_app_plans/` — each with one
  **`STATUS.md`** (landed capabilities with `file:line` evidence, known bugs, open-plan index,
  invariants, verification). **Read the domain's `STATUS.md` before implementing or debugging a
  behavior.** Landed plans are condensed in and their files deleted (git history is the archive).
  Number a plan `<NN>_` **only** when its `depends_on` names another *open* plan (stage `NN` of a
  chain); otherwise `[<tag>]_<slug>.md` (independent, including a chain head). Full convention:
  `.opencode/skills/plan-management/SKILL.md`. Domains are owned by `api-planner` / `rider-planner` /
  `driver-planner`; every landing claim is adversarially verified by `antagonistic-reviewer` first.
- **Docs**: `RIDER_API_GUIDE.md`, `RIDER_APP_API_PLAN.md`, `DRIVER_APP_PLAN.md`, `USER_STORIES.md`,
  `data-population-plan.md`, `places_search.md`.

## Quick commands

| Task | Command |
| --- | --- |
| Start API (port 8080, live-reload) | `make run` (= `DEBUG_LOGGING=true go run ./cmd/server`) |
| Whole local stack (Docker + API + both apps) | `scripts/dev-all.sh` |
| Unit tests (no DB needed) | `go test -count=1 ./...` |
| Integration tests (DB-backed) | `make test-integration` |
| Routing benchmarks (routing pkg only) | `make benchmark` |
| Lint (Go) | `make lint` (golangci-lint v2; see fact 2) |
| Docker PostGIS + Redis | `docker compose up -d` |
| Re-seed places | `make seed` |
| Import road network | `make import-osm` (or `make import-osm-force`) |
| Backfill elevation (after `import-osm`) | `make import-elevation` |
| Download/extract SJ OSM | `make download-osm` |
| Flutter bootstrap / analyze / test | `melos bootstrap` / `melos run analyze` / `melos run test` (see fact 1) |

Server config is env-driven (`internal/config/config.go`): `SERVER_PORT` (8080),
`DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME` (`ridehail`/`ridehail_pass`/`ridehailing` @
localhost:5432), `REDIS_HOST/REDIS_PORT` (localhost:6379), `DEBUG_LOGGING`.
Routing/region: `ROUTING_ENGINE` (`native` — the intentional permanent default, see fact 3),
`ROUTING_SNAP_RADIUS_M` (**50000** m default: a pin farther than that from any road is not covered
and gets a 200 `is_estimate`; `0` is the documented always-snap opt-in),
`ROUTING_DEFAULT_REGION` (defaults to the `default_region=TRUE` row),
`ROUTING_MAX_REGIONS_IN_MEMORY` (0 = keep all). Per-datasource pools read `routing_datasources` rows
and take each city DB's password from `DATASOURCE_<ID>_PASSWORD` (id uppercased, `-`→`_`) or
`~/.pgpass` — never the row; `ROUTING_DATASOURCE_SSLMODE`/`ROUTING_DATASOURCE_MAX_CONNS` tune them.
Elevation (`[elevation]`, default **off**): `ROUTING_ELEVATION` (`on`/`off`; anything else fails
closed to off), `ROUTING_ASCENT_WEIGHT` 1.5, `ROUTING_DESCENT_WEIGHT` 0.3, `ROUTING_MAX_GRADE` 0.15,
`ROUTING_ELEV_DEADBAND_M` 3.0, `ROUTING_ELEV_MIN_COVERAGE` 0.99. Numeric defaults are proposals until
the calibration stage lands; inert with `ROUTING_ENGINE=pgrouting` (warned at boot).
Containers: `ride-hailing-db` (`pgrouting/pgrouting:16-3.5-4.0`), `ride-hailing-redis` (`redis:7-alpine`).

## Environment facts agents MUST know

1. **Flutter/Dart CLI must be the Linux FVM SDK** at `~/fvm/default` (Flutter 3.47.3 / Dart 3.13.3)
   **plus native Melos 8** at `~/.pub-cache/bin/melos`; run `export PATH=~/fvm/default/bin:$PATH` then
   `melos bootstrap` / `melos run analyze` / `melos run test` (covers all three packages). The
   Windows-mounted SDK (`/mnt/i/flutter`, `I:\flutter`) has CRLF shell scripts (`$'\r': command not
   found`) — never use it. `make flutter-*` is **broken** from this tree (shells out to Windows
   `melos.bat` via `cmd.exe`, which cannot `cd` the UNC path). The Windows SDK is only for a GUI target
   (`flutter run -d windows` / `-d chrome`), which needs the UNC path mapped first:
   `cmd.exe /c "pushd \\wsl.localhost\Ubuntu-22.04\home\ricardo\repos\ride-hailing-api && <cmd>"`.
   Keep `pubspec.lock` at repo root only.
2. **`golangci-lint` IS available** — v2.14.0 at `~/go/bin/golangci-lint`, so `make lint` works.
   `.golangci.yml` is **schema version 2** (`linters.default: none` + `linters.enable`,
   `govet.enable: [shadow]`, `gofmt` under `formatters`); validate edits with
   `golangci-lint config verify`. Keep the tree lint-clean. `make lint` caps output at
   `max-same-issues: 3` / `max-issues-per-linter: 50` — add `--max-same-issues 0
   --max-issues-per-linter 0` when auditing. `go test -race ./tests/` has **pre-existing** races in
   `testutil.MockRideRepo`, so `TestNoOfferWhenDriverSocketIsDown` and
   `TestNoOfferWhenDriverNeverPushedLocation` fail under `-race`; `make test` does not use `-race`.
3. **pgRouting IS available** (api_plans `[routing]`): DB image `pgrouting/pgrouting:16-3.5-4.0`
   (PostGIS 3.5.2 + pgRouting 4.0.1); migration 012 converges old volumes. Routing still runs on the
   Go engine by default (`internal/routing`, A* over an in-memory graph). **`native` is the
   intentional PERMANENT default — this is decided, not pending a gate** (bug #1 closed;
   `api_plans/STATUS.md` → `[routing]` decisions holds the numbers). Re-measured 2026-09-29 on
   the shared 400×400 lattice workset: `hop` native **1,375 ns/op** vs pgRouting
   **224,359,399 ns/op** (~163,000× faster); `corner` native 244 ms vs pgRouting 264 ms — i.e.
   pgRouting is not even faster on the long path. The `pgr_dijkstra` path **is** wired
   (`internal/repository/pgrouting_repo.go`; factory at `internal/router/router.go:32`) and is
   opt-in with `ROUTING_ENGINE=pgrouting` for parity/validation work and as the fallback target
   when the extension is absent; its 8-col output shape matters when tuning. The old
   `postgis/postgis:16-3.4-alpine` image has NO pgRouting — what migration 012 fixes.
4. **Migrations** (`internal/database/migrate.go`): only `migrations/*.up.sql` are embedded and
   executed (alphabetical; version = numeric prefix before the first `_`); `.down.sql` is
   documentation only. Startup applies pending migrations.
5. **Road graph is cached in-process.** After `make import-osm` (or any change to
   `road_network_*_pgr`) restart the API or the route endpoint serves the old graph. Same after any
   elevation backfill: the graph holds `EleM` values loaded at boot, and `make import-osm` never
   writes `elevation_m`, so a re-import yields zero elevation coverage by construction.
6. **`scripts/init-pgrouting.sh`** is idempotent and control-file-guarded (numeric PG version dir,
   skips unpackaged extensions, PostGIS before pgRouting). Re-run:
   `docker exec -i ride-hailing-db sh -s < scripts/init-pgrouting.sh` (it's a shell script, not
   `psql -f`). Runs only on first boot of an empty volume; reused volumes converge via migration 012.
7. **Tests use mocks, not the live DB.** `tests/` boots via `testutil.NewTestServerE()` with mock
   repos (`MockNavigationRepo` returns 5000 m / 454 s) and `db=nil`, so `go test ./...` passes without
   Docker. Filter gin noise with `grep -E "^(--- FAIL|ok|FAIL)"`.
8. **HTTP error contract** (api_plans `[errors]`): handlers answer
   `{"error":{"code":...,"message":...}}` via `internal/handler/respond.go`
   (`fail`/`respondRepo`/`bindJSON`). Repo errors → 404 `NOT_FOUND` / 409 `CONFLICT` / 500 `INTERNAL`;
   validation → 422 `VALIDATION_ERROR` with human field names; malformed bodies → 400 `BAD_REQUEST`.
   `message` is public (Flutter renders it verbatim) — never put `err.Error()` there; attach it as the
   cause. See `RIDER_API_GUIDE.md` `## Errors`.

## Routing endpoint contract

`GET /api/v1/navigation/route` — Bearer auth required. `from_lat`, `from_lng`, `to_lat`, `to_lng`
are **mandatory and validated** (missing/non-numeric → 422). Success (200):

```json
{"polyline":[{"lat":9.9333,"lng":-84.0833},"...road-following..."],"total_distance_m":2094,"total_duration_s":190}
```

Polyline endpoints are pinned to the pickup/dropoff coords. Distance = A* edge costs (edge `cost` =
road length in meters); duration = distance / 11 m/s. No route → 500.

⚠️ The rider fallback is **not** 500-only:
`rider_app/lib/features/home/presentation/home_screen.dart:157` is `error: (_, _) => Polyline(...)` — it
draws a pickup→dropoff straight line on **every** error status and discards the exception. A
misclassified 4xx silently renders a confident, road-less route. Never classify an outage as 4xx;
answer 5xx, or 200 with `is_estimate: true`.

Since `[routing]` stages 05–06, routing is **region-scoped** and **multi-city**: both pins must snap to
the SAME `routing_regions` row (snap-first over candidates ordered by bbox-center distance, defaulting
to `ROUTING_DEFAULT_REGION` or the `default_region=TRUE` row). Pins outside every region → 200 with
`"is_estimate": true`, the straight haversine polyline, and its `total_distance_m`/`total_duration_s`
(= /11) (coverage gated by `ROUTING_SNAP_RADIUS_M`; default 50000 m, so a pin >50 km from any road
answers an estimate; `0` restores always-snap, where any pin resolves into the nearest imported
region). Cross-region trips are also estimates (intercity deferred). Each region
may name a `datasource` (own Postgres); one pool per datasource and one lazily built, evictable native
graph per region, so a down datasource degrades only its own regions — never a 500 for other cities.
Same-DB regions (`datasource` NULL) behave as stage 05.

## Conventions

- Go: `gofmt`; small focused packages; table-driven tests next to the code (e.g.
  `internal/routing/routing_test.go`). `make test` AND `make lint` must stay green. Do not `//nolint`
  or weaken `.golangci.yml`; handle the error (propagate, or log when best-effort/audit-only).
- Dart: keep the re-export-shim structure intact (never move app files into `shared/`; only ADD).
  Shared owns the pure core plus the `[nav]` sidebar/settings/profile UI; `shared/test/` has widget
  suites and `shared/pubspec.yaml` sets `uses-material-design: true`. Shared classes are parametrized
  (`ApiClient(baseUrl:)`, `WebSocketService(baseUrl:, wsPath:)`, `AppAuthController` takes endpoints +
  subclass hooks); each app wires its own `ApiConfig`. `melos run analyze` / `melos run test` must stay
  green.
- Commits: short conventional messages (`feat:`/`fix:`/`docs:`). When behavior changes, update the
  domain's `STATUS.md` (condense the landed plan, record any new known bug) via the
  `plan-management` skill and the domain planner agent.
