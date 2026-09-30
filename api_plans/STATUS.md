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
  `native` default (see the decisions line below for the measured numbers).
- 04 region schema — migration `013_region_schema.up.sql`; `internal/model/region.go:11`
  (`RegionRef`), `routing_regions`/`routing_datasources` registry, `region_id` on the routing
  tables.
- 05 region resolution + import — `internal/service/navigation.go:95` (`GetRoute`), `:161`
  (`ResolveRegion`), `:280` (`estimateRoute`); `is_estimate` at
  `internal/handler/platform.go:373,425` and `internal/handler/responses.go:133-155`; importer
  `--region` at `scripts/import-road-network.sh:64,264`. ~~Known issue: the estimate fallback is
  dead by default because `ROUTING_SNAP_RADIUS_M` defaults to 0 = always snap
  (`internal/config/config.go:101`).~~ **Fixed 2026-09-29:** the default is now
  `ROUTING_SNAP_RADIUS_M=50000` (`internal/config/config.go:83,141`), the coverage predicate is
  the single exported `repository.WithinSnapRadius` (`navigation_repo.go:141`, replacing two
  inlined copies), and `0` remains the documented always-snap opt-in.
- 06 multi-city single stack — `internal/repository/datasource.go:28`
  (`ErrDatasourceUnavailable`), `:137` (`DatasourcePools`); per-region lazily built, evictable
  graph cache in `internal/repository/navigation_repo.go:152,221,358`; config knobs
  `internal/config/config.go:44-57`. Known issue: the native `RouteInRegion` does not itself
  apply the snap radius; coverage is enforced only at the resolver.
- **Decision (bug #1): `native` is the intentional PERMANENT `ROUTING_ENGINE` default.** The
  benchmark gate is closed and is not being re-opened. Evidence re-measured 2026-09-29 on the
  shared 400×400 lattice workset (`internal/routing/benchmark_test.go:95` `BenchmarkRoute` vs
  `internal/repository/pgrouting_repo_benchmark_test.go:135` `BenchmarkRoutePGRouting`, same
  grid, AMD Ryzen 7 3700X): `hop` native **1,375 ns/op** (288 B, 12 allocs) vs pgRouting
  **224,359,399 ns/op** (5,137 B, 132 allocs) ≈ **163,000× faster**; `corner` native
  **243,977,671 ns/op** (43.6 MB, 243,014 allocs) vs pgRouting **264,147,948 ns/op** (272 KB,
  6,510 allocs) ≈ **1.08×** — i.e. pgRouting is not even faster on the long path, and it is the
  only engine that cannot express the elevation cost model (`pgr_dijkstra` reads
  `road_network_edges_pgr.cost`, which stays pure meters). *Drift note:* the earlier
  "~28,000×" figure recorded in the plan and in old `AGENTS.md` prose did **not** reproduce on
  this hardware/workset; the decision's direction is unchanged and stronger, and the current
  numbers are the ones recorded above. `pgrouting` stays opt-in for parity/validation and is the
  fallback target when the extension is absent
  (`internal/repository/pgrouting_repo.go:70-84,103-106`, `internal/config/config.go:40-56`).
  Default pinned by `TestRoutingEngineDefaultIsNative` (`internal/config/config_test.go`).

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
- Idempotency never replays a half-read or implausible response — `internal/middleware/idempotency.go:45`
  (`Load` reads status+body and fails if either read fails), `:152,156` (an unreadable pair or a
  status outside 100–599 is logged and the handler re-runs; the old path called
  `AbortWithStatusJSON(0, nil)`), `:193` (a failed INSERT, and a dropped one, is logged).

### [dispatch]
- A failed terminal `no_driver_available` persist **skips the rider push on BOTH dispatch
  paths**, because a push must never announce a status the database does not hold. Both paths
  now share one helper: the zero-candidate path (`internal/service/dispatch.go:112`) and the
  candidates-exhausted, still-pending path (`:176-180`) both call `finishWithoutDriver`
  (`:127-138`), whose early `return` at `:135` precedes `pushNoDriverAvailable` (`:137`); the
  ride stays `pending` so the ride service can retry or expire it. The trace is still published
  — from a `defer` at `:128-130`, after the write settles — so support sees the attempt.
  Pinned by `TestDispatchNoDriverAvailableWhenPersistenceFails`
  (`internal/service/dispatch_test.go:620`) and `TestDispatchFailedTerminalWriteDoesNotPushTheRider`
  (`:653`). See `rider_app_plans/STATUS.md:22` for the client-side dependency. What the trace
  still cannot say is bug #19 below.

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
| 2 | ~~Estimate fallback dead by default~~ — **fixed**: `ROUTING_SNAP_RADIUS_M` ships at 50000, so a pin >50 km from any road answers 200 `is_estimate`; `0` stays the documented always-snap opt-in (recorded in Landed → [routing] stage 05) | `internal/config/config.go:93` (const + rationale `:80-93`), `:141` (the load). *No `service/navigation.go` citation here on purpose: that file is under a concurrent routing edit, so a line number written now would rot on landing* | closed | [routing] |
| 3 | Rider app draws a straight line on **every** error status, so a misclassified 4xx silently renders a wrong route. API must answer an outage as 5xx or 200+`is_estimate`, never 4xx | `rider_app/lib/features/home/presentation/home_screen.dart:157` | high | [errors] |
| 9 | ~~No unit test at all~~ — **fixed**: `internal/middleware/idempotency_test.go` covers the partial-read re-run, the implausible-status guard, the 200/201-only store rule, the 1 MiB capture cap and the blank-key bypass. The three statements in `sqlIdempotencyStore` are still DB-free-untested (no go-sqlmock, `tests/` runs with `db=nil`) | `internal/middleware/idempotency_test.go` | closed (SQL untested) | [errors] |
| 10 | ~~`MarkStaleDriversOffline` is never called~~ — **fixed**: `run()` starts a `DriverLivenessSweeper`, which sweeps once at boot and then every `DefaultSweeperInterval` (10 s), so stale `driver_positions.status` rows are reconciled and the 30 s freshness window (`internal/repository/geo_repo.go:39`) is no longer the only bound. Scope is narrow and documented: it writes `driver_positions.status` only — `drivers.status` is untouched, and `GET /drivers/:id/location` is unchanged because its query selects no status column (`internal/repository/geo_repo.go:127-134`) | call site `cmd/server/main.go:82-84`; sweeper `internal/service/driver_liveness.go:36,55,87`; definition `internal/repository/geo_repo.go:172` | closed | [dispatch] |
| 11 | A DB-fresh online driver whose socket is absent is now **retried before being dropped**: `waitForSocket` polls the hub 4 × 150 ms (~450 ms) and only the give-up is recorded as a skip (`internal/service/dispatch_observability.go:201-219`, backoff consts `:180-181`). Still open: (a) a driver genuinely not connected after that window is dropped (`internal/websocket/hub.go:120-125` is map presence only), and (b) there is no driver-side keep-alive `ping()`, so presence depends on the app reconnecting — cross-app, `driver-planner` | `internal/service/dispatch_observability.go:201-219`; `internal/websocket/hub.go:120-125` | medium | [dispatch] |
| 12 | `PUT /rides/:id/destination` is a stub: returns `{"message":"destination updated"}` and never mutates state | `internal/handler/platform.go:386-388` | high | [multi] |
| 15 | Arrival notify over WS exists (`ride.go:193`) but `POST /driver/rides/:id/notify-arrival` is a no-op stub; `device_tokens` table is never written and register/unregister are stubs — no backgrounded push pipeline | `internal/handler/platform.go:466-477,106-128`, `internal/database/migrations/007_create_misc.up.sql:36` | high | [push] |
| 16 | ~~Replay stored `json.Marshal(gin.H{})` = `{}` regardless of the handler's body~~ — **fixed**: `captureWriter` tees the real body and `replayableBody` normalises it for the `JSONB NOT NULL` column | `internal/middleware/idempotency.go:202-226` | closed | [errors] |
| 17 | A replay is `AbortWithStatusJSON`, i.e. `json.Marshal` under `application/json`, so a non-JSON original comes back JSON-quoted and HTML-significant bytes come back `\u`-escaped. Only JSON objects/arrays round-trip byte-for-byte. Faithful replay needs the stored `Content-Type` (`c.Data`) and a `response_content_type` column — deliberately not added (a migration would collide with in-flight work) | `internal/middleware/idempotency.go:158` (the replay call), `:210-214` (the documented limitation), `:215` (`replayableBody`); pinned by `TestIdempotencyNonJSONReplayIsJSONQuoted` (`internal/middleware/idempotency_test.go:635`) | low | [errors] |
| 18 | `idempotency_keys.key` is a bare PRIMARY KEY (migration 007), so it is not user-scoped: a second user reusing a key they do not own gets `Count=0` forever and their INSERT is dropped by `ON CONFLICT DO NOTHING` — idempotency silently off for them, now at least logged. `Count`/`Load` filter on `user_id` already; the fix is a `UNIQUE(key, user_id)` migration | `internal/database/migrations/007_create_misc.up.sql:70-78`; `internal/middleware/idempotency.go:31-33` (the bare-PK note), `:41,49,53` (the user_id filters), `:61` (`ON CONFLICT DO NOTHING`), `:198` (the WARNING); `TestIdempotencyStoreConflictLeavesResponseUnchanged` (`internal/middleware/idempotency_test.go:715`) | medium | [errors] |
| 19 | The terminal dispatch trace cannot distinguish a failed `no_driver_available` write from a genuinely empty search: `Outcome()` answers `no_candidates` for both, so the one line a support query reads cannot say "was nobody there, or did our write fail?" — the only separating signal is a separate bare `log.Printf` on the failure path. Fix = a recorded terminal-write error on the trace with its own outcome (`dispatch_traces.go` + `finishWithoutDriver`); not done in the doc-honesty pass because it needs `dispatch.go`, which was under a concurrent routing edit | `internal/service/dispatch_observability.go:87-102` (`Outcome`, limitation documented at `:68-86`), `internal/service/dispatch.go:132-136`, pinned as-is by `TestDispatchNoDriverAvailableWhenPersistenceFails` (`internal/service/dispatch_test.go:632-634`) | medium | [dispatch] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[elevation]_calibration_and_rollout_gate.md` | elevation | landed DEM ingest | gate run 2026-09-29: **NO-GO, stay `off`**; remaining: (a) certify a flat control, (b) implement G6 + calibrate `DeadbandM` into `config.go`, (c) run the N=2000 sweep |
| `01_[elevation]_duration_model.md` | elevation | `[elevation]_calibration…` | grade-aware `total_duration_s`; **blocked** — no driver-trace/drive-time dataset exists to calibrate the speed-vs-grade curve |
| `[elevation]_pgrouting_parity.md` | elevation | pgrouting engine + elevation columns (landed) | **deferred**; add `reverse_cost`/`cost_ascent` migration + elevation-aware edges SQL, backfilled by a script referenced from `import-osm` |
| `[elevation]_review.md` | elevation | — | pre-implementation review of the whole elevation chain (all three landed heads + stage 01); keep dispositioned as the stages move. ⚠️ Its prose still uses the **pre-renumbering** stage numbers — see the mapping note at the top of that file |
| `[routing]_intercity.md` | routing | routing region resolution (STATUS.md) | **deferred**; holds the archived overlay-ports/planner design |
| `[multi]_add_stops_change_destination.md` | multi | — | waypoints in DB/model + DTO, service stop handling, real `PUT /rides/:id/destination` (replace stub), rider-app stop surface (cross-app) |
| `[dispatch]_reliability_and_no_driver_false_negative.md` | dispatch | — | **API side implemented**: presence re-arm (`internal/handler/driver.go:190`), the sweep (`cmd/server/main.go:82`), the socket retry (`internal/service/dispatch_observability.go:201-219`) and the per-skip/terminal trace all landed. Remaining: the cross-app driver keep-alive `ping()` contract, the drop-after-450 ms case (bug #11) and bug #19. Condensation/deletion is the orchestrator's pass, not this one's |
| `[push]_delivery_pipeline.md` | push | — | persist `device_tokens`, FCM/APNs provider, backgrounded notify-arrival + updates (WS-path stays for connected riders) |
| `[errors]_route_outage_contract_test.md` | errors | — | **implemented**: `TestRouteCalculationFailureIs500Not4xx` (`tests/error_contract_test.go:171`) injects a failing nav repo through `testutil.NewTestServerWithNav` and pins `500` + `INTERNAL` + the exact message for `/navigation/route` **and** `/geo/eta`. Its last item — the `RIDER_API_GUIDE.md` fallback wording — is now rewritten; nothing remains but condensation/deletion |
| `[routing]_native_engine_default.md` | routing | — | **implemented**: the config comment states the permanent default (`internal/config/config.go:40-48`), `.env.example:28,34`, the benchmark evidence + closed decision are in Landed → [routing], and `TestRoutingEngineDefaultIsNative` (`internal/config/config_test.go:156`) pins it. Nothing remains but condensation/deletion |
| `[routing]_estimate_fallback_default.md` | routing | — | **implemented**: default `50000` (`internal/config/config.go:93,141`), reconciled `.env.example:40`, covered by `TestGetRouteBeyondSnapRadiusIsEstimateWithTheDefaultRadius` (`internal/service/regions_test.go:682`) and `TestGetRouteRadiusZeroOptInStillSnapsUnconditionally` (`:755`). Nothing remains but condensation/deletion |
| `[errors]_idempotency_middleware_tests.md` | errors | — | **implemented**: a DB-free suite over the `idempotencyStore` seam (`internal/middleware/idempotency_test.go`, 21 test functions incl. table-driven ones) covering the partial-read re-run, the implausible-status guard, the 200/201-only store rule, the capture cap and the blank-key bypass. Remaining: the three `sqlIdempotencyStore` statements still have no DB-backed test (no go-sqlmock) — the same gap as row #9 |
| `[errors]_idempotent_replay_body.md` | errors | — | **implemented**: `captureWriter` tees the real body and `replayableBody` normalises it (`internal/middleware/idempotency.go:89,215`). Remaining: the two follow-ups filed as rows #17 (a `response_content_type` column for faithful replay) and #18 (`UNIQUE(key, user_id)`) |
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
  parity/validation. The plan-03 benchmark gate is closed, not pending; the measured numbers (and
  the hardware they were taken on) are in Landed → [routing] decision on bug #1. See
  `[routing]_native_engine_default.md`.
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

## Wave-1 condensed 2026-09-30
- [routing]_estimate_fallback_default (bug #2), [routing]_native_engine_default (bug #1), [errors]_route_outage_contract_test, [dispatch]_reliability_and_no_driver_false_negative, [errors]_idempotency_middleware_tests + [errors]_idempotent_replay_body: landed, files deleted, evidence in STATUS.md Landed sections. Routing regression N1 (native snap gate returns 500 instead of 200 estimate for uncovered pins ~265m band) remains; fix owned by routing planner.
