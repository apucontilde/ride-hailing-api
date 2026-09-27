# AGENTS.md — ride-hailing-api

Operating rules for agents working in this repo. Read before changing anything.

## Repo layout

- **Go API** at repo root: `cmd/server` (entry), `internal/{config,middleware,handler,repository,service,router,routing,websocket,model,database}`.
- **Flutter monorepo (Melos 8 pub workspace)** at repo root: `pubspec.yaml` (workspace) + three packages — `rider_app/` (Riverpod + flutter_map 7 + Dio + go_router), `driver_app/` (same stack), and `shared/` (`ride_hailing_shared`) holding code shared by both apps (AuthUser/Ride models, ApiClient, AuthStorage, AppAuthController, WebSocketService, AppTheme, Validators, LocationHelper, and the shared UI core introduced by the `[nav]` chain — `AppSidebar`/`AppSidebarHeader`/`AppSidebarFooter`/`AppSidebarToggleButton`, `AppNavItem`/`AppNavDestination`/`AppNavSection`/`AppNavLinkCard`, `AppSettingsScreen`/`AppSettingsSection`/`AppSettingsRow`, `AppProfileHeader`/`AppProfileForm`, `performAppSignOut`).
- **Core-file re-export convention**: both apps keep their historical import paths (`lib/core/api/api_client.dart`, `lib/core/auth/auth_provider.dart`, `lib/features/auth/model/auth_user.dart`, ...) as thin shims. The shims either re-export from `shared/` (`export 'package:ride_hailing_shared/ride_hailing_shared.dart' show <Symbol>;`) or define the app-local provider that wires shared classes to `ApiConfig.baseUrl` (`apiClientProvider`, `webSocketServiceProvider`, `authProvider`, `driverProfileProvider`). Do **not** move files out of the apps; keep the shims. Shims are for **historical** paths only — a *new* shared symbol is imported straight from `package:ride_hailing_shared/ride_hailing_shared.dart` (the barrel is unfiltered, so no *app-side* shim or export edit is needed — but the barrel itself still grows one `export` line per new shared file, see `rider_app_plans/[nav]_shared_sidebar_core.md`); do not mint a shim for a new symbol.
- **Plans**: three domains — `api_plans/`, `rider_app_plans/`, `driver_app_plans/`. Each has a single **`STATUS.md`** (the current-state file: landed capabilities with `file:line` evidence, known bugs, open-plan index, invariants, verification). **Read the domain's `STATUS.md` before implementing or debugging a behavior.** Landed plans are condensed into it and their files deleted; git history is the archive. Open plan files are tagged, with a number prefix **only** for a stage whose `depends_on` names another *open* plan: `[<tag>]_<slug>.md` (independent — this includes a chain's **head**, whose `depends_on` is empty, and a plan that depends only on already-landed capability) or `<NN>_[<tag>]_<slug>.md` (stage `NN` of a chain). So a chain reads head → `01_` → `02_` → …, e.g. the errors chain is `api_plans/[errors]_error_taxonomy_in_repositories.md` (head) → `api_plans/01_[errors]_repository_errors_to_http.md` → `api_plans/02_[errors]_validation_and_client_contract.md`. Full convention: `.opencode/skills/plan-management/SKILL.md`. Domains are owned by the `api-planner` / `rider-planner` / `driver-planner` agents; every landing claim is adversarially verified by `antagonistic-reviewer` before it is recorded.
- **Docs**: `RIDER_API_GUIDE.md`, `RIDER_APP_API_PLAN.md`, `DRIVER_APP_PLAN.md`, `USER_STORIES.md`, `data-population-plan.md`.

## Quick commands

| Task | Command |
| --- | --- |
| Start API (port 8080, live-reload) | `make run` (= `DEBUG_LOGGING=true go run ./cmd/server`) |
| Unit tests (no DB needed) | `go test -count=1 ./...` |
| Integration tests | `make test-integration` |
| Routing benchmarks (routing pkg only) | `make benchmark` |
| Lint (Go) | `make lint` (golangci-lint v2; see fact 2) |
| Docker PostGIS + Redis | `docker compose up -d` |
| Re-seed places | `make seed` |
| Import road network | `make import-osm` (or `make import-osm-force`) |
| Download/extract SJ OSM | `make download-osm` |
| Flutter bootstrap (workspace) | `melos bootstrap` (see fact 1) |
| Analyze all Dart packages | `melos run analyze` (see fact 1) |
| Test all Dart packages | `melos run test` (see fact 1) |

Server config is env-driven (`internal/config/config.go`): `SERVER_PORT` (default 8080),
`DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME` (defaults `ridehail`/`ridehail_pass`/`ridehailing`
on localhost:5432), `REDIS_HOST/REDIS_PORT` (localhost:6379), `DEBUG_LOGGING`.
Routing/region env: `ROUTING_ENGINE` (`native` default), `ROUTING_SNAP_RADIUS_M` (0 = always
snap; set >0 to get no-coverage estimates), `ROUTING_DEFAULT_REGION` (defaults to the
`default_region=TRUE` registry row), `ROUTING_MAX_REGIONS_IN_MEMORY` (0 = keep every city's
native graph). Per-datasource pools (api_plans `[routing]`, see `api_plans/STATUS.md`) read `routing_datasources` rows from the
local DB and take each city DB's password from `DATASOURCE_<ID>_PASSWORD` (id uppercased,
`-`→`_`) or `~/.pgpass` — never from the row; `ROUTING_DATASOURCE_SSLMODE` /
`ROUTING_DATASOURCE_MAX_CONNS` tune those pools.
Containers: `ride-hailing-db` (postgis/postgis:16-3.4-alpine), `ride-hailing-redis`.

## Environment facts agents MUST know

1. **Flutter/Dart CLI is BROKEN in this WSL harness — but a working Linux toolchain exists.** Any
   `flutter`/`dart` invocation that resolves to the Windows-mounted SDK fails with
   `/mnt/i/flutter/bin/internal/shared.sh: line 5: $'\r': command not found` (CRLF endings); do
   **not** use or try to fix that SDK. The working toolchain is the **Linux FVM SDK** at
   `~/fvm/default` (Flutter 3.47.3 / Dart 3.13.3) **plus native Melos 8** at
   `~/.pub-cache/bin/melos`. Verify Dart changes with:
   `export PATH=~/fvm/default/bin:$PATH` then `melos bootstrap` / `melos run analyze` /
   `melos run test` (a single command analyses/tests all three workspace packages). (This SDK is
   newer than `I:\flutter`, so it enables one stricter lint, `unawaited_return_in_try_block` —
   a false positive it raised on `rider_app/lib/core/auth/auth_provider.dart` was fixed, so the
   tree is clean under it.)
1b. **The `make` Flutter targets (`make flutter-analyze` / `make flutter-test`) are broken from
   this WSL tree** — they shell out to the Windows `melos.bat` through `cmd.exe`, and `cmd.exe`
   cannot `cd` into the UNC path (`\\wsl.localhost\...`), so Melos runs in `C:\Windows` and
   reports "not within a Melos workspace". Use native `melos run ...` (fact 1) instead. The
   Windows SDK (`I:\flutter`) is only needed to launch a GUI target — `flutter run -d windows`
   / `-d chrome`, or `flutter devices` — and for that you must map the UNC path to a drive
   letter first:
   `cmd.exe /c "pushd \\wsl.localhost\Ubuntu-22.04\home\ricardo\repos\ride-hailing-api && <cmd>"`.
   Flutter lives at `I:\flutter`; Dart at `I:\flutter\bin\dart.bat`. Keep `pubspec.lock` at repo
   root only; per-app lockfiles are managed by Melos bootstrap.
2. **`golangci-lint` IS available** — v2.14.0 at `~/go/bin/golangci-lint`, so `make lint`
   works. (It is on PATH only because `~/.bashrc` sets `GOPATH=$(go env GOPATH)`; if you ever
   see "command not found", re-source `~/.bashrc` or call the binary by full path.)
   `.golangci.yml` is **schema version 2** — `linters.default: none` + `linters.enable`,
   `govet.enable: [shadow]` (v1's `check-shadowing` no longer exists), and `gofmt` lives under
   the separate `formatters` block. Validate edits with `golangci-lint config verify`.
   The tree **is** lint-clean (0 issues as of this writing) — keep it that way: run
   `make lint` after touching Go code. Beware that `golangci-lint run` caps output at
   `max-same-issues: 3` / `max-issues-per-linter: 50` by default, so a "3 issues" report can
   really be dozens; add `--max-same-issues 0 --max-issues-per-linter 0` when auditing.
   Note `go test -race ./tests/` has **pre-existing** data races in `testutil.MockRideRepo`
   (it mutates a shared `*model.Ride` while a test goroutine JSON-encodes it), so
   `TestNoOfferWhenDriverSocketIsDown` and `TestNoOfferWhenDriverNeverPushedLocation` fail
   under `-race`. `make test` does not use `-race`; do not treat those as regressions.
3. **pgRouting IS available** (api_plans `[routing]`, see `api_plans/STATUS.md`): DB image is
   `pgrouting/pgrouting:16-3.5-4.0` (PostGIS 3.5.2 + pgRouting 4.0.1); migration 012 converges
   existing volumes, and migration 011's `pgr_dijkstra` stub + NYC seed are guarded behind
   extension-absent so the real function is never shadowed. Routing STILL runs on the Go
   engine by default (`internal/routing`, A* over an in-memory graph) — `ROUTING_ENGINE`
   defaults to `native` because the benchmark gate kept it (pgRouting was ~28,000× slower on
   the `hop` benchmark). The `pgr_dijkstra` repo path **is** wired
   (`internal/repository/pgrouting_repo.go`, factory selected at `internal/router/router.go:32`)
   and can be enabled with `ROUTING_ENGINE=pgrouting`; its 8-col output shape matters when
   tuning it. The OLD alpine image
   (`postgis/postgis:16-3.4-alpine`) has NO pgRouting — a volume from one is exactly what
   migration 012 fixes.
4. **Migrations** (`internal/database/migrate.go`): the runner embeds and executes only
   `migrations/*.up.sql` (alphabetically sorted; version = numeric prefix before the first `_`).
   `.down.sql` files are documentation only — never executed. Running the server applies
   pending migrations on startup.
5. **Road graph is cached in-process.** After `make import-osm` (or any change to
   `road_network_*_pgr`), restart the API or the route endpoint keeps serving the old graph.
6. **`scripts/init-pgrouting.sh`** is idempotent and control-file-guarded: it detects the
   numeric PG version dir (the Debian image has a stray `postgresql.conf.sample.dpkg` file
   that a bare `ls | sort -V` would pick), skips extensions the image doesn't package, and
   creates PostGIS before pgRouting. Re-run by hand:
   `docker exec -i ride-hailing-db sh -s < scripts/init-pgrouting.sh`
   (do NOT `psql -f` the file — it's a shell script). It runs only on first boot of an empty
   volume; reused volumes converge via migration 012.
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
(edge `cost` = road length in meters); duration = distance / 11 m/s. No route → 500, and the
rider app falls back to a straight line.

⚠️ That fallback is **not** 500-only. `rider_app/lib/features/home/presentation/home_screen.dart:128`
is `error: (_, _) => Polyline(...)`: it draws a pickup→dropoff straight line on **every** error
status and discards the exception. So a misclassified 4xx does not surface an error — it silently
renders a confident, road-less route. Never classify an outage as a 4xx; answer 5xx, or 200 with
`is_estimate: true` (see below). Narrowing the fallback to 5xx-only is a known follow-up.

Since api_plans `[routing]` (stage 05), routing is **region-scoped**: both pins must snap to the SAME
`routing_regions` row (resolution is snap-first over candidates ordered by bbox-center
distance, defaulting to `ROUTING_DEFAULT_REGION` or the `default_region=TRUE` row). Pins
outside every region → HTTP 200 with `"is_estimate": true`, the polyline as the straight
haversine line between the pins, and `total_distance_m`/`total_duration_s` (= /11) of that
line. Coverage is gated by `ROUTING_SNAP_RADIUS_M` (>0 required for estimates to fire;
default 0 = "always snap", so any pin on Earth resolves into the nearest imported region).
Cross-region trips are also estimates (intercity is deferred, `api_plans/[routing]_intercity.md`).

Since api_plans `[routing]` (stage 06), one stack serves **many cities**: each `routing_regions` row may name a
`datasource` (its own Postgres). The repo keeps one pool per datasource and one lazily built
native graph per region (evictable via `ROUTING_MAX_REGIONS_IN_MEMORY`); a region's routes
run on that region's graph in that region's pool. A datasource that is down degrades only
its own regions to the estimate (HTTP 200, `is_estimate`), never a 500 for other cities.
Same-DB regions (`datasource` NULL) behave exactly as stage 05.

## Conventions

- Go: `gofmt` formatted; small focused packages; table-driven unit tests next to the code
  (e.g. `internal/routing/routing_test.go`). `make test` AND `make lint` must stay green.
  Do not silence a linter with `//nolint` or by weakening `.golangci.yml`; handle the error
  (propagate it, or log it when the write is best-effort/audit-only) instead.
- Dart: keep the re-export-shim structure in both apps intact (never move app files into
  `shared/`; only ever ADD code there). Shared package owns the pure core (models, client,
  storage, auth controller, ws service, theme, validators) and, since the `[nav]` chain, the
  shared sidebar/settings/profile UI. `shared/test/` now has widget suites (not just pure
  functions) and `shared/pubspec.yaml` declares `uses-material-design: true` (it used to claim
  `false` while rendering Icons). Shared classes are parametrized
  (`ApiClient(baseUrl:)`, `WebSocketService(baseUrl:, wsPath:)`, `AppAuthController` takes
  endpoints + subclass hooks) so each app wires its own `ApiConfig`. `melos run analyze` and
  `melos run test` must stay green (via the Makefile targets above).
- Commits: short conventional messages (`feat:` / `fix:` / `docs:`), matching repo history.
- When behavior changes, update the domain's `STATUS.md` (condense the landed plan, record any
  new known bug) using the `plan-management` skill and the domain planner agent.