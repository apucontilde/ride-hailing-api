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

### [elevation]
- Chain head (directional cost model): `CostWeights{AscentW,DescentW,MaxGrade,DeadbandM}` +
  `weightedEdgeCost`/`deadband`/`clamp`/`heuristicScale`/`Validate` in
  `internal/routing/elevation.go:47,58,65,99,112`; `Node.EleM` additive field at
  `internal/routing/routing.go:24`; `RouteWithWeights` returning `Path{Nodes,Meters,Cost,AscentM,DescentM}`
  at `routing.go:259`, with `Route` becoming a zero-weight wrapper (`routing.go:247`) so the
  default is byte-identical distance routing. Zero-elevation cost equivalence proved by
  `TestRouteZeroWeightsEqualsDistance` (`routing_test.go:225`); admissibility by
  `TestWeightedMatchesBruteForceDijkstra` (`:600`) + `TestHeuristicIsAdmissible` (`:641`);
10 new tests total appended (11 pre-existing unmodified), `BenchmarkRouteElevated`
   (`benchmark_test.go:179`).
- Vertex elevation column + repo/config plumbing (chain head, landed): migration
  `014_vertex_elevation.up.sql` (`elevation_m DOUBLE PRECISION`, `elevation_source TEXT`,
  both metadata-only + idempotent); `roadNode.EleM *float64` scan of `elevation_m` +
  `known` set in `toRoutingNodes` (`navigation_repo.go:57,550`); coverage gate + NULL-endpoint
  rule in `resolveElevation`/`fillUnknownElevation` (`navigation_repo.go:318,351`, the
  unknown-endpoint neighbour-mean propagation, pure + DB-free-tested); `RoutingElevation`
  config struct default-**off** with fail-closed bool parse
  (`internal/config/config.go:70,77,127,183`); `AggCost = p.Meters` never the weighted cost
  (`navigation_repo.go:643`); pgrouting-divergence warning in the factory
  (`pgrouting_repo.go:110,123`). *Renumber drift:* the plan's prose said migration 015 while
  the correct on-disk version is **014** (013 was the landed region schema) — already resolved
  on disk.
- DEM ingest + noise control (chain head, landed): `cmd/elevtool/hgt.go` (stdlib-only gzipped
  SRTM `.hgt.gz` reader — `ParseHGT`/`At`/`Sample`, north-up row order, void `-32768`
  rejection, size validation), `cmd/elevtool/main.go` (tile set derived from the **vertex set**
  — not the bbox corners — `-fetch`/`-dry-run`/`-min-coverage`, transaction-wrapped `COPY` into
  `road_network_vertices_pgr`, unmatched vertices stay `NULL`), `cmd/elevtool/hgt_test.go` +
  `main_test.go` (DB/network-free), `scripts/import-elevation.sh` (three-step runbook
  `import → elevation → restart` + a post-import coverage assertion that exits non-zero below
  the gate), `Makefile:62` `import-elevation` target. Measured 100.00 % coverage (152,665/152,665),
  five `skadi` tiles (`elevation_source` per vertex), grade histogram peaked at 2–4 % with a fat
  tail, `short − long` tripwire 5.0% vs 5.0% = 1.00× (retained as a tripwire, not a calibration
  input). The `short − long` calibration estimator was **deleted** (measured 1.00×, no signal);
  its replacement (cell-boundary straddling + known-flat-street `Δz` spread) is owned by the
  calibration stage.
- Additive elevation response fields (Item A — condensed from the retired
  duration/API-surface plan): raw `total_ascent_m` / `total_descent_m` + per-response
  `elevation_aware`, always present (0/false when off) — `RouteResult.AscentM/DescentM/ElevationAware`
  last-row (`internal/repository/navigation_repo.go:15,662-666`) → `service.RouteInfo`
  (`internal/service/navigation.go:20,283-285,299-304`) → `GET /api/v1/navigation/route`
  (`internal/handler/platform.go:415-423`, `internal/handler/responses.go:154-162`); spec
  regenerated. Raw metres, never the weighted cost; additive only — `total_distance_m` unchanged,
  neither app needs a change. Landed 2026-09-29, adversarially confirmed.

### [errors]
- Error taxonomy: `ErrNotFound`/`ErrConflict` sentinels + `wrapDB` classifier at
  `internal/repository/errors.go:17-24,44-59`; all repository sites routed through it. Chain
  **head landed** (deleted).
- HTTP error contract: `fail`/`respondRepo` helper in `internal/handler/respond.go:19-50` —
  `fail` attaches the cause (`c.Error`) and writes the house envelope via
  `AbortWithStatusJSON`, `respondRepo` maps `ErrNotFound`→404 `NOT_FOUND`, `ErrConflict`→409
  `CONFLICT`, else 500 `INTERNAL` (operation-specific sentence). All five (six including
  `platform.go`) handler files instrumented (`auth.go`, `driver.go`, `geo.go`, `platform.go`,
  `ride.go`, `rider.go`); no `gin.H{"error": gin.H` hand-roll and no `err.Error()` in any body
  remain. Service sentinels `ErrInvalidCredentials`/`ErrInvalidRefreshToken`/
  `ErrInvalidResetToken` at `internal/service/auth.go:36,42,48`, mapped by the handler so a
   login/refresh/reset outage now answers **500**, never 401/400 — still 401 for a genuinely bad
   token (`TestLoginDBOutageIs500Not401` + `TestLoginUnknownEmailStill401`,
   `tests/error_contract_test.go:104,128`).
- Validation + client contract: `bindJSON` helper + `fieldName` map + validator JSON
  `TagNameFunc` in `internal/handler/respond.go:38-125` — all 22 `ShouldBindJSON` sites now go
  through `bindJSON` and answer human field names (`"Invalid Email"`) or `"Malformed request
  body"` (`400 BAD_REQUEST`), never a validator trace; the envelope is documented in
  `RIDER_API_GUIDE.md` (`## Errors`). Chain landed complete.
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

### [fare]
- Completion fare is no longer manufactured: the 1.1× `TotalFare *= 1.1` is gone and the
  completed-ride WS payload carries the booked estimate unchanged — `internal/service/ride.go:175-196`;
  the price endpoint's `distance_rate`/`time_rate` now carry the real per-km/per-minute rates from
  `getRates` (`internal/handler/platform.go:328-329`, `internal/service/fare.go:83-91`) instead of
  the `DistanceFare`/`TimeFare` totals.

### [startup]
- `main()` delegates to `run() error`, so `defer db.Close()` actually runs on the early-return
  paths — `cmd/server/main.go:21,29,36`; the four `log.Fatalf` sites became
  `fmt.Errorf("…: %w", err)`, same text.
- `TestMain` closes the test server before `os.Exit` — `tests/setup_test.go:16-18` (the old
  `defer ts.Close()` before `os.Exit(m.Run())` never ran).

## Known bugs & issues

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 2 | Estimate fallback dead by default (`ROUTING_SNAP_RADIUS_M=0` = always snap) | `internal/config/config.go:101`, `internal/service/navigation.go:280` | medium | [routing] |
| 3 | Rider app draws a straight line on **every** error status, so a misclassified 4xx silently renders a wrong route. API must answer an outage as 5xx or 200+`is_estimate`, never 4xx | `rider_app/lib/features/home/presentation/home_screen.dart:157` | high | [errors] |
| 9 | `internal/middleware/idempotency.go` has no unit test at all (the package's only tests cover `AuthRequired`/`maskQueryTokens`), so the "never replay a partial read" rule is unenforced | `internal/middleware/` (no `idempotency_test.go`) | low | [errors] |
| 10 | `MarkStaleDriversOffline` is in the `GeoRepo` interface but is **never called** — no cron/goroutine invokes it, so stale `status='online'` rows are not swept and the 30 s freshness window (`geo_repo.go:73`) is the only liveness bound | `internal/repository/geo_repo.go:125-129` (definition) vs no call site | medium | [dispatch] |
| 11 | Dispatch search reads the DB but the offer loop skips any driver whose socket isn't in the hub map (`IsConnected` = map presence only), so a DB-fresh online driver with a stale/absent WS entry is dropped and the loop can answer `no_driver_available` despite a live driver; no driver-side keep-alive `ping()` exists | `internal/service/dispatch.go:101-105`, `internal/websocket/hub.go:120-125` | high | [dispatch] |
| 12 | `PUT /rides/:id/destination` is a stub: returns `{"message":"destination updated"}` and never mutates state | `internal/handler/platform.go:386-388` | high | [multi] |
| 15 | Arrival notify over WS exists (`ride.go:193`) but `POST /driver/rides/:id/notify-arrival` is a no-op stub; `device_tokens` table is never written and register/unregister are stubs — no backgrounded push pipeline | `internal/handler/platform.go:466-477,106-128`, `internal/database/migrations/007_create_misc.up.sql:36` | high | [push] |
| 16 | Idempotent replay stores `json.Marshal(gin.H{})` = `{}` as `response_body` regardless of what the handler wrote, so a replay returns the right status with an **empty** body | `internal/middleware/idempotency.go:54` | medium | [errors] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[elevation]_calibration_and_rollout_gate.md` | elevation | landed DEM ingest | gate run 2026-09-29: **NO-GO, stay `off`**; remaining: (a) certify a flat control, (b) implement G6 + calibrate `DeadbandM` into `config.go`, (c) run the N=2000 sweep |
| `01_[elevation]_duration_model.md` | elevation | `[elevation]_calibration…` | grade-aware `total_duration_s`; **blocked** — no driver-trace/drive-time dataset exists to calibrate the speed-vs-grade curve |
| `[elevation]_pgrouting_parity.md` | elevation | pgrouting engine + elevation columns (landed) | **deferred**; add `reverse_cost`/`cost_ascent` migration + elevation-aware edges SQL, backfilled by a script referenced from `import-osm` |
| `[elevation]_review.md` | elevation | — | pre-implementation review of the whole elevation chain (all three landed heads + stage 01); keep dispositioned as the stages move. ⚠️ Its prose still uses the **pre-renumbering** stage numbers — see the mapping note at the top of that file |
| `[routing]_intercity.md` | routing | routing region resolution (STATUS.md) | **deferred**; holds the archived overlay-ports/planner design |
| `[multi]_add_stops_change_destination.md` | multi | — | waypoints in DB/model + DTO, service stop handling, real `PUT /rides/:id/destination` (replace stub), rider-app stop surface (cross-app) |
| `[dispatch]_reliability_and_no_driver_false_negative.md` | dispatch | — | reconcile search vs WS-eligibility so a DB-fresh online driver isn't skipped; wire `MarkStaleDriversOffline`; observe/log every skip. Driver keep-alive `ping()` is cross-app |
| `[push]_delivery_pipeline.md` | push | — | persist `device_tokens`, FCM/APNs provider, backgrounded notify-arrival + updates (WS-path stays for connected riders) |
| `[errors]_route_outage_contract_test.md` | errors | — | regression test: a nav-repo failure answers 500 `INTERNAL`, never 4xx; inject a failing nav repo into the test server; fix the `RIDER_API_GUIDE` fallback wording |
| `[routing]_native_engine_default.md` | routing | — | record `native` as the permanent engine default (config comment + AGENTS + benchmark evidence); close bug #1 as a decision |
| `[routing]_estimate_fallback_default.md` | routing | — | bug #2: default `ROUTING_SNAP_RADIUS_M=50000` so the no-coverage `is_estimate` path can fire; keep `0` = always-snap |
| `[errors]_idempotency_middleware_tests.md` | errors | — | bug #9: DB-free unit tests for `idempotency.go` via an `idempotencyStore` seam; pin the partial-read re-run rule (test-only) |
| `[errors]_idempotent_replay_body.md` | errors | — | bug #16: capture the real response body so a replay is not `{}` |
| `[ratings]_ratings_list.md` | ratings | — | server half of driver-app bug #5 **plus** the symmetric rider endpoint: replace `GET /driver/ratings` **and** `GET /rider/ratings` stubs with real rater-scoped, paginated lists so each app's "already rated" set is server-backed |
| `[payout]_driver_earnings_and_withdraw.md` | payout | — | **deferred**: server half of driver-app bug #6 — `driver_earnings` ledger + credit-on-completion + real `GET /driver/me/earnings` and idempotent `POST /driver/earnings/withdraw` (pending debit, no external payout); design settled, no scheduling |

## Decisions already taken — [errors] (do not re-litigate)

- Taxonomy shape: two sentinels (`ErrNotFound`, `ErrConflict`) + a `wrapDB` classifier — not a
  typed `RepoError` struct, not service-layer classification.
- 5xx body text is **operation-specific** (`"failed to load nearby drivers"`), not a flat
  `"internal error"`.
- Duplicate-register copy: **`"Account already exists"`** (the wording `auth.go` already
  documents), not the mock's string.
- Client straight-line fallback: the plan was corrected to the truth (any-error, not 500-only).
  The app-side fix is now planned in `rider_app_plans/01_[map]_route_fallback_honesty.md` (honest
  grey-dashed fallback + surface the API `error.message`), gated on the API-contract test
  `[errors]_route_outage_contract_test.md`. The API keeps answering outages as 5xx.
- The landed write-failure 500s are now constructed via `fail(...)` and their causes attached
  (`c.Error`) — the `respond.go` HTTP contract (STATUS.md `[errors]`) standardised them.

## Decisions already taken — [routing] (do not re-litigate)

- **`native` (in-process A*) is the permanent production default**; `pgrouting` is opt-in for
  parity/validation. The plan-03 benchmark gate (~28,000× slower on the `hop` workset) is not
  going to be re-opened. See `[routing]_native_engine_default.md`.
- **`ROUTING_SNAP_RADIUS_M` default becomes `50000` m** (was `0` = always-snap) so the
  no-coverage `is_estimate` path can fire; `0` stays as an explicit always-snap opt-in. See
  `[routing]_estimate_fallback_default.md`.

## Decisions already taken — [payout] (do not re-litigate)

> Status: **deferred** — decisions are settled, implementation unscheduled. See
> `[payout]_driver_earnings_and_withdraw.md`.

- **Integer cents** in the ledger; the `float64` ride fare is converted once at credit time.
- **No wallet column**: available balance is `SUM(amount_cents)` over `status='available'` ledger
  rows (single source of truth, no drift).
- **Commission defaults to 0** in dev (`PAYOUT_COMMISSION_RATE`); per-region/versioned fares are
  deferred to the `fare.go` trigger.
- **Withdrawal is a `pending` ledger debit, not a bank transfer** — no external payout provider in
  this plan; the API is honest about the pending state.
- **Withdraw is idempotent** (`Idempotency-Key`), like create-ride.
  See `[payout]_driver_earnings_and_withdraw.md`.

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
- A genuine outage answers **5xx or 200+`is_estimate`, never 4xx**. `is_estimate` stays.
- A cause is logged (`c.Error`) whenever a message is generalised.
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
