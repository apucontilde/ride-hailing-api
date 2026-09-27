# api_plans — Status

> Evolve the API routing layer into a region-indexed, multi-city platform that keeps the
> `/api/v1/navigation/route` and `/estimates/*` contracts stable, plus the orthogonal
> elevation and error-contract series. Owner: `api-planner`.
> Verify: `make test` / `make lint` / `make test-integration` / `gofmt -w <files> && go vet ./...`.

## Landed

### [routing]
- 01 spatial grid snap + benchmarks — `internal/routing/routing.go:49,88,150,157,176`
  (`cells [][]int64`, `buildGrid`/`gridNearest`/`scanNearest`), `benchmark_test.go:94`
  `BenchmarkRoute`, `make benchmark` (`Makefile:31`). Grid snap ~77,000× faster than the
  linear scan (163 ns vs 12.4 ms). *Deviation:* the plan wanted a flat `cells` slice; code
  uses a per-row `[][]int64`.
- 02 pgRouting infra — `docker-compose.yml:9` image `pgrouting/pgrouting:16-3.5-4.0`,
  `scripts/init-pgrouting.sh` (idempotent, control-file guarded), migration
  `012_enable_pgrouting.up.sql` (geo-guarded seed purge + extension convergence; safe on
  reused volumes). Known issue: rev-1 of 012 purged by vertex id and deleted real SJ rows;
  fixed by the geo guard.
- 03 engine mechanism — real `pgr_dijkstra` in `internal/repository/pgrouting_repo.go:14,42,59`;
  factory `NewRoutingRepositoryWithPools` at `pgrouting_repo.go:106,112`, called from
  `internal/router/router.go:32`; `ROUTING_ENGINE` whitelist in `internal/config/config.go:100,143`.
  **Landed mechanism, not an engine swap:** the benchmark gate deliberately kept the
  `native` default (pgRouting was ~28,000× slower on the `hop` benchmark).
- 04 region schema — migration `013_region_schema.up.sql`; `internal/model/region.go:11`
  (`RegionRef`), `routing_regions`/`routing_datasources` registry, `region_id` on the routing
  tables.
- 05 region resolution + import — `internal/service/navigation.go:95` (`GetRoute`), `:161`
  (`ResolveRegion`), `:280` (`estimateRoute`); `is_estimate` at
  `internal/handler/platform.go:373,425` and `internal/handler/responses.go:133-155`; importer
  `--region` at `scripts/import-road-network.sh:64,264`. Known issue: the estimate fallback is
  dead by default because `ROUTING_SNAP_RADIUS_M` defaults to 0 = always snap
  (`internal/config/config.go:101`).
- 06 multi-city single stack — `internal/repository/datasource.go:28`
  (`ErrDatasourceUnavailable`), `:137` (`DatasourcePools`); per-region lazily built, evictable
  graph cache in `internal/repository/navigation_repo.go:152,221,358`; config knobs
  `internal/config/config.go:44-57`. Known issue: the native `RouteInRegion` does not itself
  apply the snap radius; coverage is enforced only at the resolver.

### [errors] — partial; stages 01–03 of the series are still open
Landed as a side effect of the golangci-lint fix, **not** via the `[errors]` stages: there is
still no `wrapDB` taxonomy, no `respond.go`/`fail`/`respondRepo` helper, and no `c.Error` on any
of these sites. The stages' remaining work is unchanged except where noted below.
- A failed write answers 5xx instead of a false success — 10 new `INTERNAL` sites:
  `internal/handler/driver.go:41,51,101,129` (`Register`'s `UpdateUser`+`CreateDriver`,
  `UpdateProfile`, `UpdateStatus`), `internal/handler/rider.go:80,88,118,136` (`UpdateProfile`'s
  `UpdateRider`+`UpdateUser`, `UpdateStatus`, `DeleteAccount`), `internal/handler/geo.go:104`
  (the batch loop), `:132` (`UpdateRiderLocation`). Body is the house envelope
  `{"error":{"code":"INTERNAL","message":"<operation>"}}`. No *successful* write changed status.
- Revocation fails closed — `internal/service/auth.go:111` (`RefreshAccessToken` mints no new
  pair), `:222` (`ForgotPassword`), `:257` (`ResetPassword`, before the password is written).
- Audit/ancillary rows are best-effort and logged, never fatal — `internal/service/ride.go:63,112,156`
  (`CreateEvent`, after the authoritative `UpdateRideStatus` already committed), `:71,118,162`
  (the log lines), `internal/service/dispatch.go:166,172`, `internal/handler/ride.go:90`
  (the `go h.dispatchService.Dispatch` goroutine no longer discards its error).
- Idempotency never replays a half-read response — `internal/middleware/idempotency.go:16`
  (`loadStoredResponse` reads status+body and fails if either read fails), `:42-48` (logs and
  lets the handler re-run; the old path called `AbortWithStatusJSON(0, nil)`), `:60` (a failed
  INSERT is logged).

### [dispatch]
- A failed `no_driver_available` persist in the sequential offer loop now aborts the loop and
  **skips** the rider push — `internal/service/dispatch.go:92-95` (early `return` before
  `pushNoDriverAvailable`). The other path is unchanged: no drivers found at all still logs and
  pushes (`:59-63`). See `rider_app_plans/STATUS.md:22` for the client-side dependency.

### [startup]
- `main()` delegates to `run() error`, so `defer db.Close()` actually runs on the early-return
  paths — `cmd/server/main.go:21,29,36`; the four `log.Fatalf` sites became
  `fmt.Errorf("…: %w", err)`, same text.
- `TestMain` closes the test server before `os.Exit` — `tests/setup_test.go:16-18` (the old
  `defer ts.Close()` before `os.Exit(m.Run())` never ran).

## Known bugs & issues

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 1 | `ROUTING_ENGINE` default stays `native` (performance gate not met) | `internal/config/config.go:145`, `internal/repository/pgrouting_repo.go:112` | medium | [routing] |
| 2 | Estimate fallback dead by default (`ROUTING_SNAP_RADIUS_M=0` = always snap) | `internal/config/config.go:101`, `internal/service/navigation.go:280` | medium | [routing] |
| 3 | Rider app draws a straight line on **every** error status, so a misclassified 4xx silently renders a wrong route. API must answer an outage as 5xx or 200+`is_estimate`, never 4xx | `rider_app/lib/features/home/presentation/home_screen.dart:128` | high | [errors] |
| 4 | Migration numbering: max on disk is 013; elevation reserves 015 (absent); the retired `elevation/README.md` claimed max 012 | `internal/database/migrations/013_region_schema.up.sql`; `01_[elevation]_elevation_column_and_repo_plumb.md:90` | low | [elevation] |
| 5 | The new fail-closed revocation errors are surfaced as **4xx with the raw wrapped error in the body**: `Refresh` answers 401 + `err.Error()`, `ResetPassword` answers 400 + `err.Error()`. A DB outage during revoke now masquerades as "bad token" *and* leaks driver text — violates bug 3 / the never-4xx invariant. Regression introduced by the fail-closed change | `internal/handler/auth.go:157-161`, `:259-263`; service at `internal/service/auth.go:111,257` | high | [errors] |
| 6 | The 10 new write-failure 500s drop the cause entirely — no `c.Error`, no `log`, so `ErrorLogger` has nothing to print and the 500 is undiagnosable from the server side | `internal/handler/driver.go:41`, `internal/handler/rider.go:80`, `internal/handler/geo.go:104`; logger at `internal/router/router.go:61` | medium | [errors] |
| 7 | The `FindByID`/`FindDriverByID`/`FindRiderByID` **reads** immediately before each guarded write still discard their error, so a missing row nil-derefs and is swallowed by gin's `Recovery` (`gin.Default()`, `internal/router/router.go:48`) as an unexplained 500 — never the 404 the endpoint owes | `internal/handler/driver.go:38,96,126`; `internal/handler/rider.go:75,85,115` | medium | [errors] |
| 8 | None of the new failure branches is reachable from `tests/`: `MockGeoRepo.Upsert{Driver,Rider}Position`, `MockRideRepo.CreateEvent` and all three `MockUserRepo.Revoke*` return `nil` unconditionally, and the real repositories only fail them on a driver error. No test asserts any of the new 500s | `tests/testutil/mock_repos.go:459,571,581,218,254,266` vs `internal/repository/user_repo.go:153,175,180`, `internal/repository/ride_repo.go:139` | medium | [errors] |
| 9 | `internal/middleware/idempotency.go` has no unit test at all (the package's only tests cover `AuthRequired`/`maskQueryTokens`), so the "never replay a partial read" rule is unenforced | `internal/middleware/` (no `idempotency_test.go`) | low | [errors] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[elevation]_directional_cost_model.md` | elevation | — | engine minimizes `meters + w·ascent`; pure Go, no schema |
| `01_[elevation]_elevation_column_and_repo_plumb.md` | elevation | `[elevation]_directional_cost_model.md` (unnumbered head) | `elevation_m` column (migration 015) + repo/config plumbing, default off |
| `02_[elevation]_dem_ingest_and_noise_control.md` | elevation | `01_[elevation]_…` | DEM ingest (`cmd/elevtool`) + noise-control rationale |
| `03_[elevation]_calibration_and_rollout_gate.md` | elevation | `02_[elevation]_…` | sweep-first calibration, acceptance suite, go/no-go gate |
| `04_[elevation]_duration_and_api_surface.md` | elevation | `03_[elevation]_…` | deferred: grade-aware duration + additive response fields + pgr parity |
| `[errors]_error_taxonomy_in_repositories.md` | errors | — | `ErrNotFound`/`ErrConflict` + `wrapDB`; mocks in lockstep |
| `01_[errors]_repository_errors_to_http.md` | errors | `[errors]_error_taxonomy_in_repositories.md` (unnumbered head) | one `respond`/`respondRepo`, `c.Error` instrumentation, stop `err.Error()` leaks; must **not** re-do the landed 500s, and must fix bug 5 |
| `02_[errors]_validation_and_client_contract.md` | errors | `01_[errors]_…` | clean validator text from the 22 `ShouldBindJSON` sites; document envelope |
| `[elevation]_review.md` | elevation | — | pre-implementation review of the whole elevation chain (the unnumbered head plus stages 01–04); keep dispositioned as the stages move. ⚠️ Its prose still uses the **pre-renumbering** stage numbers — see the mapping note at the top of that file |
| `[routing]_intercity.md` | routing | routing region resolution (STATUS.md) | **deferred**; holds the archived overlay-ports/planner design |

## Decisions already taken — [errors] (do not re-litigate)

- Taxonomy shape: two sentinels (`ErrNotFound`, `ErrConflict`) + a `wrapDB` classifier — not a
  typed `RepoError` struct, not service-layer classification.
- 5xx body text is **operation-specific** (`"failed to load nearby drivers"`), not a flat
  `"internal error"`.
- Duplicate-register copy: **`"Account already exists"`** (the wording `auth.go` already
  documents), not the mock's string.
- Client straight-line fallback is **out of scope**: the plan was corrected to the truth
  (any-error, not 500-only); narrowing the app to 5xx-only is a logged follow-up.
- The landed write-failure 500s use the **existing** hand-rolled `c.JSON` envelope and the
  operation-specific sentence, i.e. exactly what stage 02 decides to standardise. Stage 02's
  diff therefore *shrinks*: 10 sites already have the right status, code and wording and only
  need their cause attached (bug 6).

## Invariants

- `NavigationRepository.GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error)`
  is **frozen**; richer capabilities ride on optional interfaces (`r, ok := repo.(...)`).
- Route cost stays **meters** (`AggCost` == distance); pgRouting runs over meter-cost edges —
  never "fix" `road_network_edges_pgr.cost` into a weighted value.
- The native A\* engine stays alive as the fallback behind `ROUTING_ENGINE`; never delete it.
- Migrations are **append-only**; the runner executes only `*.up.sql`, version = numeric prefix
  before the first `_`.
- **No assumption that pgRouting is installed**: `pgr_*` is gated behind extension-present and
  every failure degrades gracefully.
- Success paths and status codes for *valid* requests never change.
- A genuine outage answers **5xx or 200+`is_estimate`, never 4xx**. `is_estimate` stays. (Currently
  violated on `POST /auth/refresh` and `/auth/reset-password` — bug 5.)
- A cause is logged (`c.Error`) whenever a message is generalised. (The 10 landed 500s generalise
  nothing but also log nothing — bug 6.)
- **A failed write never answers success.** Any repository write error is a 5xx, never the
  endpoint's success code, and the cause is logged.
- **Ancillary rows are best-effort.** `ride_events` and `idempotency_keys` are written *after* the
  authoritative row has committed; their failure is logged and must never change a response or
  fail a request. Do not route them through `fail(...)`/`respondRepo`.
- **Fail closed on revocation.** If a token or password-reset token cannot be revoked, no new
  token pair is minted and the password is not changed. Do not "optimise" the error away.
- Mocks in `tests/testutil` move in lockstep with the repositories: a mock must be able to return
  the failures its production counterpart can. A branch only production can fail is untested.
- `[elevation]`: reported distance stays true meters; default off; missing/partial elevation
  degrades to flat, never garbage.

## Verification

```bash
make test                       # unit tests, no DB (must stay green)
make lint                       # golangci-lint v2, schema v2 config; 0 issues
make test-integration           # DB-backed
gofmt -w <files> && go vet ./...   # golangci-lint is NOT on PATH by default: PATH="$PATH:$(go env GOPATH)/bin"
```
