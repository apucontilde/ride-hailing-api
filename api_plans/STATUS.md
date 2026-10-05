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

### [ratings]
- `GET /rider/ratings` + `GET /driver/ratings` are real **rater-scoped, newest-first,
  1-based-paginated** reads (replacing the shared stub): one role-aware `RideHandler.GetRatings`
  (`internal/handler/ride.go:427`) wired to both routes
  (`internal/router/router.go:181,203`). Reads `user_id`/`role` from the JWT, maps role →
  `rater_role` (`driver`→`'driver'`, else `'rider'`, `:441-444`), parses `page`/`per_page`
  (defaults 1/20, out-of-range resets to 20, `:431-438`), and answers the history envelope
  `{"ratings":[…],"total","page","per_page","total_pages"}` (`:466-472`); a repo failure goes
  through `respondRepo` → 500 `INTERNAL` `"failed to load ratings"` (`:447-450`). Query
  `FindRatingsByRater` filters `rater_id`+`rater_role` and orders `created_at DESC`
  (`internal/repository/ride_repo.go:24,190-205`), backed by migration
  `015_ratings_rater_index.up.sql` (`idx_ratings_rater`); DTOs `RatingItem`/`RatingListResponse`
  (`internal/handler/responses.go:83,94`). Mock in lockstep
  (`tests/testutil/mock_repos.go:448`); tests `tests/ratings_test.go` +
  `internal/repository/ratings_integration_test.go`; docs `docs/swagger.json:1604,3112`,
  `RIDER_API_GUIDE.md:125,165,222-241`.

### [multi]
- Multi-stop + real `PUT /rides/:id/destination` — migration `016_ride_stops.up.sql:14-34`
  (`ride_stops`, `UNIQUE(ride_id, sequence)`); `internal/model/ride.go:74-92`
  (`RideStop`/`StopKind`/`DestinationKind`/`Ride.Stops`); `internal/repository/ride_repo.go:97`
  (`FindStopsByRideID`, `[]` never `null`), `:118` (`FindStopsByRideIDs`), `:165`
  (`ReplaceDestination`, scalar dropoff + `kind='destination'` row in one tx);
  `internal/service/ride.go:165` (`BuildItinerary`), `:408` (`ChangeDestination`),
  `ErrDestinationLocked`/`ErrNotRideRider`; `internal/handler/ride.go:103` (create w/ stops),
  `:242` (`GET /:id`), `:285` (real `UpdateDestination`; the `platform.go` stub is gone);
  routes `internal/router/router.go:232,240`; itineraries on `/rides/current` (handler `:187`)
  and `/rides/history` (`:355`). Post-review shape recorded: (a) a client stop with
  `kind:"destination"` is rejected `422` and the top-level `dropoff_*` is always appended as the
  sole destination row, so `rides.dropoff_* == last kind='destination' row` by construction
  (`internal/service/ride.go:169-201`); (b) `GetCurrentRide` answers `200 {ride:null}` only for
  `ErrNotFound` and `5xx` for a real outage (`internal/handler/ride.go:200-215`). Adversarially
  confirmed.

### [push]
- Push delivery pipeline + bug #20 — migration `018_push_pipeline.up.sql:28,31`;
  `internal/repository/device_token_repo.go:49` (upsert/reassign by globally-unique token),
  `:69` (user-scoped unregister), `:77` (list-active); `internal/repository/feedback_repo.go:30`
  (`feedback.type` persisted); `internal/service/push/provider.go:40` (`LogProvider` safe no-op),
  `:60` (`MultiProvider`), `internal/service/push/service.go:43` (void `NotifyUser`); real
  handlers `Feedback`/`DeviceRegister`/`DeviceUnregister`/`ArrivalNotification` in
  `internal/handler/platform.go:118,164,198,556`; routes `/devices` + `/device-tokens` alias
  `internal/router/router.go:271-276`; best-effort non-blocking `PushNotifier` call sites
  `internal/service/ride.go:46,319,391`, wired `internal/router/router.go:133`. **Follow-up (not
  a regression):** production delivery is inert — the default `LogProvider` is wired
  (`internal/router/router.go:97`), `WithPushProvider`/`MultiProvider` have no production caller,
  there are no FCM/APNs credentials/SDK in this harness, and neither Flutter app registers a
  device token yet. Adversarially confirmed.

## Known bugs & issues

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 2 | ~~Estimate fallback dead by default~~ — **fixed**: `ROUTING_SNAP_RADIUS_M` ships at 50000, so a pin >50 km from any road answers 200 `is_estimate`; `0` stays the documented always-snap opt-in (recorded in Landed → [routing] stage 05) | `internal/config/config.go:93` (const + rationale `:80-93`), `:141` (the load). *No `service/navigation.go` citation here on purpose: that file is under a concurrent routing edit, so a line number written now would rot on landing* | closed | [routing] |
| 3 | **Stale "confident/silent" claim corrected 2026-10-04.** The rider Home preview's `error:` branch now draws a **grey dashed** line and `_buildRouteInfo` surfaces `apiErrorMessage` + Retry, so an error is neither confident nor silent. Residual (smaller) honesty gap: the error branch still synthesizes a straight line on **every** error status instead of drawing nothing, an `is_estimate` response is rendered from the client's straight line rather than the API geometry, and a failed refresh can swap a straight line under a stale distance/time row. Owned by `rider_app_plans/[map]_route_failure_honesty.md`. The API obligation is unchanged: answer outages as 5xx or 200+`is_estimate`, **never 4xx** | `rider_app/lib/features/home/presentation/home_screen.dart:179-195` (error branch), `:440-474` (`_buildRouteInfo`); rider plan `rider_app_plans/[map]_route_failure_honesty.md` | medium | [errors] (client fix: rider-planner) |
| 9 | ~~No unit test at all~~ — **fixed**: `internal/middleware/idempotency_test.go` covers the partial-read re-run, the implausible-status guard, the 200/201-only store rule, the 1 MiB capture cap and the blank-key bypass. The three statements in `sqlIdempotencyStore` are still DB-free-untested (no go-sqlmock, `tests/` runs with `db=nil`) | `internal/middleware/idempotency_test.go` | closed (SQL untested) | [errors] |
| 10 | ~~`MarkStaleDriversOffline` is never called~~ — **fixed**: `run()` starts a `DriverLivenessSweeper`, which sweeps once at boot and then every `DefaultSweeperInterval` (10 s), so stale `driver_positions.status` rows are reconciled and the 30 s freshness window (`internal/repository/geo_repo.go:39`) is no longer the only bound. Scope is narrow and documented: it writes `driver_positions.status` only — `drivers.status` is untouched, and `GET /drivers/:id/location` is unchanged because its query selects no status column (`internal/repository/geo_repo.go:127-134`) | call site `cmd/server/main.go:82-84`; sweeper `internal/service/driver_liveness.go:36,55,87`; definition `internal/repository/geo_repo.go:172` | closed | [dispatch] |
| 11 | A DB-fresh online driver whose socket is absent is now **retried before being dropped**: `waitForSocket` polls the hub 4 × 150 ms (~450 ms) and only the give-up is recorded as a skip (`internal/service/dispatch_observability.go:201-219`, backoff consts `:180-181`). Still open: (a) a driver genuinely not connected after that window is dropped (`internal/websocket/hub.go:120-125` is map presence only). **Half (b) fixed 2026-09-30 cross-app** — the retired `driver_app_plans/01_[dispatch]_keepalive_and_offer_reliability.md` landed the driver-side keep-alive `ping()`: opt-in `heartbeatInterval` loop armed on every connect (`shared/lib/src/network/websocket_service.dart:37,54-58,112,148-156`), the driver opts into 25 s and re-arms on `setOnline`/reconnect with an immediate ping (`driver_app/lib/core/network/websocket_service.dart:17,32,45-55,78-86`), wired to presence + `publishLastPosition` (`driver_app/lib/core/location/location_service.dart:245,249`) | `internal/service/dispatch_observability.go:201-219`; `internal/websocket/hub.go:120-125` | medium | [dispatch] (client half landed, `driver-planner`) |
| 12 | ~~`PUT /rides/:id/destination` is a stub~~ — **fixed**: real `RideHandler.UpdateDestination` mutates `rides.dropoff_*` + the itinerary's `kind='destination'` row in one transaction, with owner/locked checks (`404`/`409`) and a safe-retry `5xx`; the `platform.go` stub is gone | `internal/handler/ride.go:285`; `internal/service/ride.go:408`; `internal/repository/ride_repo.go:165`; route `internal/router/router.go:240` | closed | [multi] |
| 15 | ~~Arrival notify is a no-op stub; `device_tokens` never written~~ — **fixed**: real backgrounded push pipeline — `ArrivalNotification` sends live WS or a backgrounded push, device register/unregister persist, `feedback.type` stored (see Landed → [push]) | `internal/handler/platform.go:556,164,198`; `internal/service/push/`; migration `018_push_pipeline.up.sql` | closed | [push] |
| 16 | ~~Replay stored `json.Marshal(gin.H{})` = `{}` regardless of the handler's body~~ — **fixed**: `captureWriter` tees the real body and `replayableBody` normalises it for the `JSONB NOT NULL` column | `internal/middleware/idempotency.go:202-226` | closed | [errors] |
| 17 | ~~A non-JSON replay comes back JSON-quoted / `\u`-escaped~~ — **fixed**: migration `017` adds `response_content_type` and the middleware replays via `c.Data` keyed on the stored content type (not on parseability); DB-proven by `TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres` (plain text, JSON-string, whitespace, empty, HTML bytes) | `internal/database/migrations/017_idempotency_key_scoping.up.sql:22-30`; `internal/middleware/idempotency.go:172,238,284` | closed (residual #22) | [errors] |
| 18 | ~~`idempotency_keys.key` is a bare PRIMARY KEY, not user-scoped~~ — **fixed**: migration `017` drops the global PK, dedupes `(key,user_id)` keeping the earliest row, adds `UNIQUE(key,user_id)` (the table now intentionally has no single-column PK); the store uses `ON CONFLICT (key, user_id)`. Proven by `TestMigration017ResolvesIdempotencyDuplicates` + `TestSQLIdempotencyStoreScopesKeysPerUser` against real Postgres | `internal/database/migrations/007_create_misc.up.sql:70-76` (old shape); `internal/database/migrations/017_idempotency_key_scoping.up.sql:34-61`; `internal/middleware/idempotency.go:68` | closed | [errors] |
| 19 | ~~The terminal dispatch trace cannot distinguish a failed `no_driver_available` write from a genuinely empty search~~ — **fixed**: a `terminal_write_failed` outcome + `noteTerminalError` + `abortIfOpen`; the terminal error rides on the trace and every dispatch exit path records a terminal state | `internal/service/dispatch_observability.go:95`; `internal/service/dispatch_traces.go:106,122`; `internal/service/dispatch.go:142`; pinned `internal/service/dispatch_test.go:649,705` | closed | [dispatch] |
| 20 | ~~`POST /feedback` ignores the client's `type` field~~ — **fixed**: `feedback.type` is persisted (migration `018`); the handler binds it and the repo inserts it, so `{"type":"app_issue","message":…}` retains the classification | `internal/database/migrations/018_push_pipeline.up.sql:31`; `internal/handler/platform.go:118-145`; `internal/repository/feedback_repo.go:30` | closed | [safety] |
| 21 | ~~Two pre-existing `make test-integration` failures~~ — **fixed 2026-09-30**: the coverage-gate fix (commit `00b2a5e`) made an out-of-radius pin report `ErrPinUncovered` (wrapped), but two integration tests still expected `ErrNoRoute`. They now assert `errors.Is(err, ErrPinUncovered)` — `TestPGRoutingRepoSnapRadius` (`internal/repository/pgrouting_repo_integration_test.go:179`) and `TestRouteInRegionPGRouting/dropoff_only_in_another_region` (`internal/repository/regions_integration_test.go:359`). The gate was correct; the test expectations were stale. `make test-integration` is green | `go test -tags=integration -run 'TestPGRoutingRepoSnapRadius\|TestRouteInRegionPGRouting' ./internal/repository/` | closed | [routing] |
| 22 | Idempotency replay residual: the JSON/empty content-type branch trims surrounding whitespace (`bytes.TrimSpace`), and an empty content-type with a non-JSON body replays JSON-quoted. Both are unreachable in production — idempotency is mounted only on `POST /api/v1/rides` and `CreateRide` always writes `application/json; charset=utf-8` | `internal/middleware/idempotency.go:249`; mount `internal/router/router.go:232` | low | [errors] |
| 23 | `POST /rides` binds the top-level `pickup_*`/`dropoff_*` with `binding:"required"`, so a literal `0` coordinate is rejected `422`; and none of the four top-level coords is range-checked (e.g. `999` is accepted and written to `rides.pickup_*`/`dropoff_*` verbatim), unlike stop coords, which `BuildItinerary` range-checks. Owned by `[rides]_create_dropoff_coordinate_bounds.md` | `internal/handler/ride.go:33-36` (`required`), `:136` (no top-level range check); checks only `reqStops` `internal/service/ride.go:178-183`; contrast `PUT` destination `internal/handler/ride.go:292` | medium | [rides] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[elevation]_calibration_and_rollout_gate.md` | elevation | landed DEM ingest | gate run 2026-09-29: **NO-GO, stay `off`**; remaining: (a) certify a flat control, (b) implement G6 + calibrate `DeadbandM` into `config.go`, (c) run the N=2000 sweep |
| `01_[elevation]_duration_model.md` | elevation | `[elevation]_calibration…` | grade-aware `total_duration_s`; **blocked** — no driver-trace/drive-time dataset exists to calibrate the speed-vs-grade curve |
| `[elevation]_pgrouting_parity.md` | elevation | pgrouting engine + elevation columns (landed) | **deferred**; add `reverse_cost`/`cost_ascent` migration + elevation-aware edges SQL, backfilled by a script referenced from `import-osm` |
| `[elevation]_review.md` | elevation | — | pre-implementation review of the whole elevation chain (all three landed heads + stage 01); keep dispositioned as the stages move. ⚠️ Its prose still uses the **pre-renumbering** stage numbers — see the mapping note at the top of that file |
| `[routing]_intercity.md` | routing | routing region resolution (STATUS.md) | **deferred**; holds the archived overlay-ports/planner design |
| `[payout]_driver_earnings_and_withdraw.md` | payout | — | **deferred**: server half of driver-app bug #6 — `driver_earnings` ledger + credit-on-completion + real `GET /driver/me/earnings` and idempotent `POST /driver/earnings/withdraw` (pending debit, no external payout); design settled, no scheduling |
| `[rides]_create_dropoff_coordinate_bounds.md` | rides | — | Range-check create `pickup_*`/`dropoff_*` like stops; make literal `0` a valid coordinate (pointer/custom validator, not `required`); preserve the `rides.dropoff_* == last kind='destination' row` invariant. Closes bug #23 |
| `[errors]_idempotency_json_replay_caveat.md` | errors | — | Make JSON-CT replay byte-faithful (store exact bytes as a JSON string + uniform unwrap, or explicitly accept JSONB canonicalisation) and fix empty-body semantics; keep non-JSON correct; real-Postgres JSON round-trip tests. Closes bug #22 (correctness insurance, low priority) |
| `[history]_rating_existence_endpoint.md` | history | — | Add a `ride_id` existence filter to `GET /{rider,driver}/ratings` (recommended) so an app can ask "did I rate this ride" directly instead of walking a 1000-row bound; keyset cursor is the larger alternative. Prerequisite for `rider_app_plans/01_[history]_rated_seed_past_cap.md` + `driver_app_plans/01_[history]_rated_pagination_past_cap.md` |

## Decisions already taken — [errors] (do not re-litigate)

- Taxonomy shape: two sentinels (`ErrNotFound`, `ErrConflict`) + a `wrapDB` classifier — not a
  typed `RepoError` struct, not service-layer classification.
- 5xx body text is **operation-specific** (`"failed to load nearby drivers"`), not a flat
  `"internal error"`.
- Duplicate-register copy: **`"Account already exists"`** (the wording `auth.go` already
  documents), not the mock's string.
- Client straight-line fallback: the plan was corrected to the truth (any-error, not 500-only).
  The app-side fix is now planned in `rider_app_plans/[map]_route_failure_honesty.md` (honest
  grey-dashed fallback + surface the API `error.message`), gated on the API-contract test that
  has now landed (STATUS.md Landed → [errors]). The API keeps answering outages as 5xx.
- The landed write-failure 500s are now constructed via `fail(...)` and their causes attached
  (`c.Error`) — the `respond.go` HTTP contract (STATUS.md `[errors]`) standardised them.

## Decisions already taken — [routing] (do not re-litigate)

- **`native` (in-process A*) is the permanent production default**; `pgrouting` is opt-in for
  parity/validation. The plan-03 benchmark gate is closed, not pending; the measured numbers (and
  the hardware they were taken on) are in Landed → [routing] decision on bug #1.
- **`ROUTING_SNAP_RADIUS_M` default becomes `50000` m** (was `0` = always-snap) so the
  no-coverage `is_estimate` path can fire; `0` stays as an explicit always-snap opt-in. See
  Landed → [routing] stage 05.

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

## Wave-2 condensed 2026-10-03
- [multi]_add_stops_change_destination (closes bug #12), [push]_delivery_pipeline (closes bugs #15/#20): landed, files deleted, evidence in Landed → [multi]/[push]. Also closed by verification this wave: #17 + #18 (idempotency content-type/user-scoping, migrations `017` + middleware/integration tests) and #19 (dispatch terminal-write outcome). New known bug #23 (top-level create `dropoff_*` is `binding:"required"` so `0` is rejected, and is never range-checked); residual idempotency caveat #22. Adversarially confirmed by `antagonistic-reviewer` runs.
- Push follow-up (not a regression): production delivery is inert — no FCM/APNs provider is wired and neither app registers a device token yet (Landed → [push]).

