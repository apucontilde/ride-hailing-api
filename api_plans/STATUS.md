# api_plans — Status

> Evolve the API routing layer into a region-indexed, multi-city platform. The
> `/api/v1/navigation/route` contract stays stable; `/estimates/price` is now a `POST` with an
> ordered `stops` body and additive `legs`/`is_estimate` (hard cutover from `GET`, so
> `/estimates/*` is no longer a stable contract). Plus the orthogonal elevation and
> error-contract series. Owner: `api-planner`.
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
  `ROUTING_SNAP_RADIUS_M=50000` (`internal/config/config.go:130,228`), the coverage predicate is
  the single exported `repository.WithinSnapRadius` (`navigation_repo.go:156`, replacing two
  inlined copies), and `0` remains the documented always-snap opt-in.
- 06 multi-city single stack — `internal/repository/datasource.go:28`
  (`ErrDatasourceUnavailable`), `:137` (`DatasourcePools`); per-region lazily built, evictable
  graph cache in `internal/repository/navigation_repo.go:152,221,358`; config knobs
  `internal/config/config.go:44-57`. Known issue: the native `RouteInRegion` does not itself
  apply the snap radius; coverage is enforced only at the resolver.
- Coverage-gate correctness (~265 m PostGIS/Go boundary band) — an uncovered pin is a **data
  gap** with its own sentinel, never a routing outage: `ErrPinUncovered`
  (`internal/repository/errors.go:26-36`), the `coverageAuthority` split so the region path
  never re-decides coverage the resolver already acted on
  (`internal/repository/navigation_repo.go:163-194,725-731,749-757`), and the service mapping
  to `200 is_estimate` (`internal/service/navigation.go:175-192,348-356,449-465`). Landed
  `00b2a5e` (2026-09-30, bug-fix item B "Uncovered pins returned 500; now 200 estimate").
  Pinned by `TestRadiusBoundaryBandBetweenTheTwoCoveragePredicates`
  (`internal/repository/pin_uncovered_test.go:116-178`) + `tests/route_uncovered_estimate_test.go:26`.
  This is the §A1 half; the §A5 elevation coverage gate landed alongside (next bullet). **No open
  work.**
- **Elevation coverage-gate correctness (bug #24, the §A5 half).** Ingest and runtime now share
  the ONE gate constant `DefaultElevationMinCoverage = 0.99` (`internal/config/config.go:240`,
  wired `:336`); `cmd/elevtool` registers its flags via `registerFlags` with `-min-coverage`
  defaulting to that constant (`cmd/elevtool/main.go:65,75`), and
  `scripts/import-elevation.sh` mirrors `0.99` (`:28`) and scopes the post-import assertion to
  `--region`/`REGION` (`WHERE region_id = :'region'`, `:69-72`; the global form warns, `:78-79`).
  Pinned by `TestElevationMinCoverageIsOneSharedIngestRuntimeGate` (`internal/config/config_test.go:317`)
  and `TestMinCoverageFlagDefaultIsTheSharedConfigConstant` (`cmd/elevtool/main_test.go:18`). Closes
  bug #24.
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
  Default pinned by `TestRoutingEngineDefaultIsNative` (`internal/config/config_test.go`). **Since
  the elevation flip, selecting `pgrouting` without also setting `ROUTING_ELEVATION=off` now logs
  the divergence WARNING on every boot** (`pgrouting_repo.go:124-129`): elevation is on by
  default, so the factory warns that the flag has no effect on the pgRouting path. It is a
  warning, not an error; the route is still served (flat, by pgRouting's meter costs).

### [elevation]
- Chain head (directional cost model): `CostWeights{AscentW,DescentW,MaxGrade,DeadbandM}` +
  `weightedEdgeCost`/`deadband`/`clamp`/`heuristicScale`/`Validate` in
  `internal/routing/elevation.go:11,55,66,74,107,120`; `Node.EleM` additive field at
  `internal/routing/routing.go:24`; `RouteWithWeights` returning `Path{Nodes,Meters,Cost,AscentM,DescentM}`
  at `routing.go:259`, with `Route` staying a zero-weight wrapper (`routing.go:247`). Since the
  Stage-3 flip the **server** calls `RouteWithWeights` (via `NativeNavigationRepo`), so the
  default path is elevation-aware; `Route` itself is still the pre-elevation wrapper and the
  zero-weight `CostWeights{}` still reproduces it exactly. Zero-elevation cost equivalence proved by
  `TestRouteZeroWeightsEqualsDistance` (`routing_test.go:225`); admissibility by
  `TestWeightedMatchesBruteForceDijkstra` (`:600`) + `TestHeuristicIsAdmissible` (`:641`);
  10 new tests total appended (11 pre-existing unmodified), `BenchmarkRouteElevated`
   (`benchmark_test.go:179`).
- Vertex elevation column + repo/config plumbing (chain head, landed): migration
  `014_vertex_elevation.up.sql` (`elevation_m DOUBLE PRECISION`, `elevation_source TEXT`,
  both metadata-only + idempotent);   `roadNode.EleM *float64` scan of `elevation_m` +
  `known` set in `toRoutingNodes` (`navigation_repo.go:66,655`); coverage gate + NULL-endpoint
  rule in `resolveElevation`/`fillUnknownElevation` (`navigation_repo.go:423,456`, the
  unknown-endpoint neighbour-mean propagation, pure + DB-free-tested); `RoutingElevation`
  config struct default-**on** for the native engine with fail-closed bool parse
  (unset/empty → on, garbage → off; `internal/config/config.go:107` the type, `:202` the
  weights wired in `Load`, `:264` `routingElevationEnabledFromEnv`); `AggCost = p.Meters`
  never the weighted cost
  (`navigation_repo.go:779`); pgrouting-divergence warning in the factory
  (`pgrouting_repo.go:124-129`). *Renumber drift:* the plan's prose said migration 015 while
  the correct on-disk version is **014** (013 was the landed region schema) — already resolved
  on disk.
- **Flip landed 2026-10-05 (the now-condensed deadband-calibrate-and-flip execution plan,
  condensed here).** Native-engine default is now **on** at the measured operating point
  `AscentW=12, DescentW=0.3, MaxGrade=0.15, DeadbandM=3.8` (each default in
  `config.go:107-140,202-209` carries its measured reason; `defaultElevationDeadbandM` at
  `:159`, calibrated to the p95 `|Δz|` of 43,673 relief-certified flat edges by the estimator in
  `internal/repository/elevation_calibration.go`, checked by `TestElevationDeadbandCalibration`).
  Set from the Stage-2 **N=2000** run (2,000 routable, 224 rejected; `TestZZStage2Sweep2000`,
  `internal/repository/zz_stage2_sweep_test.go`, env-gated `RUN_STAGE2_SWEEP=1`): median ascent
  `0.9314`, 168/2000 qualifying (G2), median meters `1.0090` (G3), p99 `1.0901` (G4), G7
  monotone, real-graph hot path `1.34×` (G5). **Accepted risk stated in the commit:** G1
  flat-invariance stays uncertified on this import (no ≤15 m/≥500-vertex control box; best
  33 m relief) — the flip is a product decision, not a clean eight-of-eight. The
  `routingElevationEnabledFromEnv` parser now distinguishes unset/empty (on) from garbage
  (off), pinned by `TestRoutingElevationConfigFromEnv` (`internal/config/config_test.go:207`)
  and `TestRoutingElevationDefaultOnAtWiringBoundary`
  (`internal/repository/navigation_elevation_test.go:92`).
  Migration untouched; duration/fare unchanged. **pgrouting** remains inert and warns at boot.
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
  last-row (`internal/repository/navigation_repo.go:788-792`) → `service.RouteInfo`
  (`internal/service/navigation.go:34,315`) → `GET /api/v1/navigation/route`
  (`internal/handler/platform.go:498-500`, `internal/handler/responses.go:214-216`); spec
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
- Revocation fails closed — `internal/service/auth.go:120` (`RefreshAccessToken` mints no new
  pair), `:240` (`ForgotPassword`), `:268` (`ResetPassword`, before the password is written).
- Audit/ancillary rows are best-effort and logged, never fatal — `internal/service/ride.go:63,112,156`
  (`CreateEvent`, after the authoritative `UpdateRideStatus` already committed), `:71,118,162`
  (the log lines), `internal/service/dispatch.go:166,172`, `internal/handler/ride.go:90`
  (the `go h.dispatchService.Dispatch` goroutine no longer discards its error).
- Idempotency never replays a half-read or implausible response — `internal/middleware/idempotency.go:45`
  (`Load` reads status+body and fails if either read fails), `:152,156` (an unreadable pair or a
  status outside 100–599 is logged and the handler re-runs; the old path called
  `AbortWithStatusJSON(0, nil)`), `:193` (a failed INSERT, and a dropped one, is logged).
- Idempotency replay is **byte-faithful for every content type** — `replayableBody` JSON-string-encodes
  the exact captured bytes for all content types (`bytes.TrimSpace` and the `json.Valid` branch are
  gone) and `replayBody` unwraps uniformly, so key order, whitespace and numeric formatting survive
  the `response_body JSONB` column (`internal/middleware/idempotency.go:235-238,259-267`); an empty
  capture stores `""` and replays zero bytes (the `null` sentinel is retired); a pre-change raw-JSON
  row still replays via the `json.Unmarshal`-fails fallback (`:264-267`). No migration. DB-proven by
  `TestIdempotencyJSONReplayIsFaithfulThroughPostgres` + `TestIdempotencyOldRawJSONRowReplaysThroughPostgres`
  (`internal/middleware/idempotency_integration_test.go:100,166`) and unit
  `TestNonJSONReplayRoundTripsExactBytes` (`internal/middleware/idempotency_test.go:580`). Closes bug #22.

### [dispatch]
- **Terminal `no_driver_available` write fixed** (condensed from the landed `[dispatch]` SQL
  hotfix, adversarially confirmed FIXED) — the pre-fix
  status→timestamp switch left the column empty and emitted
  `UPDATE rides SET status=$1, =$2, updated_at=NOW() WHERE id=$3` (a Postgres syntax error), so a
  normal "nobody found" ride stayed `pending` and the rider never got the terminal update.
  `rideStatusTimestampColumn` (`internal/repository/ride_repo.go:305-320`) + `updateRideStatusQuery`
  (`:330-339`) now emit `UPDATE rides SET status=$1, updated_at=NOW() WHERE id=$2` for
  `no_driver_available` (and any status without a timestamp column) while the five timestamped
  statuses stay byte-identical; `UpdateRideStatus` branches on `withTimestamp` (`:341-355`) with the
  signature/interface unchanged. Pinned by `TestUpdateRideStatusQuery`
  (`internal/repository/ride_repo_test.go:16`), the required DB-backed
  `TestRideRepoUpdateRideStatusNoDriverAvailable`
  (`internal/repository/ride_status_integration_test.go:20`, real Postgres) and
  `TestDispatchNoDriverAvailablePushesTerminalUpdateOnSuccess` (`internal/service/dispatch_test.go:497`);
  a failed write still pushes nothing (both failure-path tests stay green). No CAS/interface/
  rename/migration/config/app change.
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
- **Offer-path fixes (bug #11 server half + the HTTP decline mis-wire).** Hub presence is now
  liveness-aware — `Hub.IsConnected` returns true only for a client seen within
  `clientLivenessTTL = 28 s` (`internal/websocket/hub.go:23,54,209-220`; `lastSeen` refreshed on
  every inbound frame incl. the protocol ping/pong, `:107-110`), so a stale/half-open entry stops
  reading as connected. A candidate that fails the ~450 ms fast backoff is **parked** for the
  bounded `socketRearmWindow = 3 s` and re-offered if it reconnects
  (`internal/service/dispatch.go:194-201,225-275`; consts
  `internal/service/dispatch_observability.go:188,200-210`); only a candidate that never
  reconnects records one `skipSocketNotConnected`. `POST /api/v1/driver/rides/:id/decline` is now
  bound to `rideHandler.DeclineRide` (`internal/router/router.go:254`), which funnels through
  `DispatchService.DeclineOffer` (`internal/service/dispatch.go:358-395`, `ErrNoActiveOffer`) and
  records `skipDriverDeclined` (`:347`): active offer → `200 {"status":"declined"}`; no active
  offer → 404 `NOT_FOUND`; malformed id → 422 `VALIDATION_ERROR`
  (`internal/handler/ride_decline.go:25-51`) — never the old `"status":"stub"`. Pinned by
  `TestHubIsConnectedLiveness` (`internal/websocket/hub_test.go:23`),
  `TestDispatchSocketRetrySucceedsWhenDriverConnectsDuringRearm` and
  `TestDispatchRearmStillDropsDriverWhoNeverReconnects`
  (`internal/service/dispatch_rearm_test.go:20,75`), and
  `TestDispatchDeclineHTTPRecordsDriverDeclined` (`tests/dispatch_decline_test.go:17`). Closes bug
  #11 (the driver-side keepalive half landed 2026-09-30, recorded in the bug's evidence).

### [fare]
- Region-scoped, versioned DB pricing engine (chain head, landed 2026-10-05) — migration
  `internal/database/migrations/019_region_fares.up.sql:22,42,54,65,83` (`fare_regions` currency +
  IANA timezone, `fare_rates` integer cents with the partial unique active index,
  `fare_demand_windows`, and `rides` audit cols `fare_region_id`/`fare_rate_id`/`fare_currency`/
  `grade_uplift_pct`); repo `internal/repository/fare_repo.go:16,45,56,74,89` (local main-DB reads
  only, never the region's `datasource` pool); engine `internal/service/fare.go:112,119,133,143-160,182`
  — one `conditions_multiplier = demand(region-local time) × supply(nearby drivers)` clamped
  `[1.0, FARE_MAX_MULTIPLIER]`, empty windows reproduce the pre-`[fare]` fare exactly, typed
  fail-closed `FareConfigurationError` (→ 500) with **no cross-region card fallback**, unknown
  vehicle → sedan. Config `FARE_CURRENCY` (**USD**) + `FARE_MAX_MULTIPLIER` (**3.0**)
  `internal/config/config.go:82,98-99,230-231`; seed `cmd/faretool/main.go` +
  `internal/database/fare_seed.go:40,69` via `make seed-fares` (`Makefile:55`); wiring
  `internal/router/router.go:106,143`; mock in lockstep `tests/testutil/mock_fare_repo.go:17`.
- **Capped climb uplift on the distance leg** (chain stage 01, landed 2026-10-05) — migration
  `internal/database/migrations/020_grade_uplift.up.sql:37,39,47` adds per-(region, class)
  `fare_rates.grade_uplift_factor`/`grade_uplift_cap` (default `0` = off) and the audit
  `rides.grade_ascent_m` (NULL when no uplift). `min(ascent_per_km × factor, cap)` is clamped
  `[0, cap]`, touches the **distance leg only**, and is exactly `0` unless the route is
  elevation-aware, the leg is non-zero, the card enables it and the route climbed —
  `internal/service/fare.go:166-168,204-223`; the single final half-up round is unchanged
  (`:170`), so a fail-flat total is bit-identical to pre-020. Factors are **derived** at
  card-author time from a documented energy model (not measured): constants
  `internal/database/fare_seed.go:43,50-54`, derivation `:68-83`, insert `:179`, idempotence
  `:152-154` — sedan `0.001377`, suv `0.001446`, luxury `0.000872`, cap `0.15`; `cmd/faretool/main.go:53`.
  The applied `grade_uplift_pct` is snapshotted at create
  (`internal/service/ride.go:227-233,253`, `internal/repository/ride_repo.go:68,76`) and echoed
  additively on the estimate DTO (`internal/handler/platform.go:424`,
  `internal/handler/responses.go:194`) and receipt (`internal/handler/ride.go:633-636,647`,
  `responses.go:145`); `grade_ascent_m` is **snapshot-only, not echoed**. Tests
  `internal/service/fare_grade_test.go`, `internal/database/fare_seed_test.go`,
  `internal/handler/receipt_grade_test.go`.
- `RouteInfo.RegionID` plumbed for the fare layer — set on the region-scoped path and **empty** on
  `estimateRoute`/legacy (`internal/service/navigation.go:35,186`); snapshotted at create
  (`internal/service/ride.go:224-247`, `internal/repository/ride_repo.go:68,76`); additive DTO/receipt
  fields (`internal/handler/platform.go:414,420-424`, `internal/handler/responses.go:143-145,190-194`,
  `internal/handler/ride.go:626-647`).
- Completion **recomputes** the charge from actuals when they are usable and otherwise charges the
  booked quote unchanged (the old 1.1× manufacture is gone) — see the actuals-recompute entry below;
  the price endpoint's `distance_rate`/`time_rate` carry the real per-km/per-minute card rates
  (`internal/handler/platform.go:414-415`, `internal/service/fare.go:164-165`), not the leg totals.
- **Actuals recompute on completion** (chain stage 02, migration `022_final_fare`, landed 2026-10-06) —
  migration `internal/database/migrations/022_final_fare.up.sql:35-40` adds the hidden `quoted_*` audit
  columns; `FareService.RecomputeActualFare` (`internal/service/fare.go:223`) prices a completed ride
  from its stored actuals against the **booked** card (`GetFareRateByID(*fare_rate_id)`, `fare.go:231`)
  and the **booked** conditions multiplier reused verbatim (`fare.go:239`) — demand windows and the
  live nearby-driver count are deliberately not re-sampled, so retries stay deterministic. The climb
  uplift is re-derived from the booked raw ascent on the actual distance. It returns `(nil, nil)` when
  there is no booked card or either actual is NULL, so the caller charges the booked quote unchanged
  (`fare.go:224-229`). `RideService.AdvanceStatus` wires it on the `completed` transition
  (`internal/service/ride.go:407-441`), persisted by `FinalizeRideFare`
  (`internal/repository/ride_repo.go:375`), which copies the row's pre-finalization money columns into
  `quoted_*` and writes the final in one statement guarded by `quoted_total_fare IS NULL`
  (`ride_repo.go:378-388`) — exactly-once/idempotent at the DB level, with the state machine rejecting
  `completed→completed` as the service half. Because the plain money columns hold the final after
  completion, every read path (ride JSON, receipt `internal/handler/ride.go:638-648`, driver history)
  resolves to the final with **no new field**; `quoted_*` is `json:"-"` (`internal/model/ride.go:60-64`).
  Tests `internal/service/fare_recompute_test.go`, `internal/repository/final_fare_integration_test.go`,
  `tests/fare_actuals_recompute_test.go`. **Residual (being fixed concurrently):** the receipt's
  `grade_uplift_pct` is currently the **booked** snapshot even on a recomputed ride; the intended final
  behaviour is that a completed ride reports the uplift actually applied to its final distance leg
  (the Go agent is adding that as migration `023`). Grade metadata is display/audit only — the charge
  on the wire is already final.
- **`POST /estimates/price` hard cutover** (landed 2026-10-08, condensed from the deleted
  `[fare]_waypoint_fare.md`; working tree, commit pending) — `estimates.POST("/price", …)` is the
  only route (`internal/router/router.go:277`); the `GET` registration is removed with no alias and
  no `Deprecation` header, so a stale GET answers **404**, never 200/405
  (`TestEstimatesPriceGetIsGone`, `tests/estimates_price_post_test.go:97-104`). The POST body mirrors
  `POST /rides` (`pickup_*`/`dropoff_*` + ordered `stops`), and `docs/swagger.{json,yaml}` +
  `RIDER_API_GUIDE.md:442,503-510` document POST only.
- **One shared stop cap `RIDE_MAX_STOPS`** on create and estimate — `DefaultRideMaxStops = 8`
  (`internal/config/config.go:114`), loaded `:247`; enforced once in
  `BuildItinerary(..., maxStops int)` (`internal/service/ride.go:192,196-201`) and passed by both
  handlers (`internal/router/router.go:159,162`; `internal/handler/ride.go:189`;
  `internal/handler/platform.go:436`); over-cap → 422 `VALIDATION_ERROR` "a trip can have at most
  8 stops" with the cause attached; boundary pinned by `TestStopCapSharedByCreateAndEstimate`
  (`tests/estimates_price_post_test.go:157`).
- **Waypoint-aware booking quote (summed once)** — `RequestRide` passes the intermediate waypoints
  to `CalculateItineraryEstimate` (`internal/service/ride.go:256-265`); zero stops delegates
  structurally to `CalculateEstimate` (`internal/service/fare.go:159-161`), so the no-stop price is
  bit-identical (pinned totals 16.28/23.30/34.57 in `internal/service/fare_itinerary_test.go`);
  one base, one conditions multiplier, one capped uplift and one half-up round over the summed
  route (`internal/service/fare.go:181-249`). The snapshot fields and
  `RecomputeActualFare`/`FinalizeRideFare` are untouched.
- **Additive `is_estimate` + per-leg `legs` on the estimate response only** —
  `internal/handler/responses.go:205,210,216`; built from the fare agent
  (`internal/service/fare.go:246-247,257-275`); create/receipt payloads stay aggregate.
- **Cross-region / uncovered itinerary → whole-itinerary straight-line estimate on the default
  card** — `internal/service/navigation.go:288-290,319-346`; `itineraryEstimate` emits one leg per
  consecutive pair (`stops+1`), so the aggregate is their sum and no region-A card ever prices
  another region's geometry.

### [tracking]
- **Actual trip distance + duration** (migration `021_ride_actuals`, landed 2026-10-06) — additive
  `rides.actual_duration_s` / `rides.actual_distance_m` (both SQL NULL, never a fabricated 0) plus the
  append-only `ride_track_points` trace (`internal/database/migrations/021_ride_actuals.up.sql:27,30`).
  The geo endpoint appends a fix only while the ride is `in_progress` (`internal/handler/geo.go:74`);
  completion derives duration from the status timestamps (`ActualDurationSeconds`,
  `internal/service/ride_tracking.go:94`) and driven distance as a pure haversine sum
  (`DrivenDistanceMeters`, `ride_tracking.go:58`) with a 3 m jitter floor + 60 m/s teleport gate that
  re-anchors on a dropped segment (`ride_tracking.go:15,24`); fewer than two usable fixes yields nil
  distance. Persisted via `SetRideActuals` (`internal/repository/ride_repo.go:357`), read back ordered
  (`FindRideTrackPoints`, `ride_repo.go:343`) and exposed additively on ride JSON
  (`internal/model/ride.go:48-49`) and the completion WS payload
  (`internal/websocket/messages.go:25-26`). Fare-agnostic source consumed by the `[fare]` stage above.
  Tests `internal/service/ride_tracking_test.go`, `tests/ride_actuals_test.go`,
  `internal/repository/ride_actuals_integration_test.go`; mock in lockstep
  (`tests/testutil/mock_repos.go:634`).

### [startup]
- `main()` delegates to `run() error`, so `defer db.Close()` actually runs on the early-return
  paths — `cmd/server/main.go:21,29,36`; the four `log.Fatalf` sites became
  `fmt.Errorf("…: %w", err)`, same text.
- `TestMain` closes the test server before `os.Exit` — `tests/setup_test.go:16-18` (the old
  `defer ts.Close()` before `os.Exit(m.Run())` never ran).

### [ratings]
- `GET /rider/ratings` + `GET /driver/ratings` are real **rater-scoped, newest-first,
  1-based-paginated** reads (replacing the shared stub): one role-aware `RideHandler.GetRatings`
  (`internal/handler/ride.go:436`) wired to both routes
  (`internal/router/router.go:197,219`). Reads `user_id`/`role` from the JWT, maps role →
  `rater_role` (`driver`→`'driver'`, else `'rider'`, `:457-460`), parses `page`/`per_page`
  (defaults 1/20, out-of-range resets to 20, `:440-447`), and answers the history envelope
  `{"ratings":[…],"total","page","per_page","total_pages"}` (`:482-488`); a repo failure goes
  through `respondRepo` → 500 `INTERNAL` `"failed to load ratings"` (`:463-466`). Query
  `FindRatingsByRater` filters `rater_id`+`rater_role` and orders `created_at DESC`
  (`internal/repository/ride_repo.go:464-489`), backed by migration
  `015_ratings_rater_index.up.sql` (`idx_ratings_rater`); DTOs `RatingItem`/`RatingListResponse`
  (`internal/handler/responses.go:114,125`). Mock in lockstep
  (`tests/testutil/mock_repos.go:574`); tests `tests/ratings_test.go` +
  `internal/repository/ratings_integration_test.go`; docs `docs/swagger.json:1939,3479`,
  `RIDER_API_GUIDE.md:125,165,396-415`.

### [history]
- **Per-ride rating existence filter** (condensed from the landed, adversarially verified
  2026-10-05 `[history]_rating_existence_endpoint.md`) — optional `ride_id` on the shared
  `GET /api/v1/{rider,driver}/ratings` answers the caller's 0-or-1 row for one ride, so an app
  resolves `rated`/`unrated` without walking the 1000-row seed bound. A known rated ride returns
  the caller's row; an unrated ride is a definitive `200` empty (`total:0`, `total_pages:0`); a
  malformed `ride_id` is `422 VALIDATION_ERROR "invalid ride_id"` at the handler, never a
  Postgres cast 500; the `{ratings,total,page,per_page,total_pages}` envelope and the no-param
  list contract are unchanged. Handler `RideHandler.GetRatings` validates with `uuidRE`
  (`internal/handler/ride.go:415-419`), rejects at `:450-455`, passes the param at `:462`; repo
  `FindRatingsByRater(raterID, raterRole, rideID, limit, offset)` appends `AND ride_id = $3` to
  COUNT+SELECT only when set, keeping the `idx_ratings_rater` path and aligned placeholders
  (`internal/repository/ride_repo.go:464-489`); interface `:44`; mock in lockstep
  (`tests/testutil/mock_repos.go:574,582`). No migration. Tests `tests/ratings_test.go:234,295`,
  `internal/repository/ratings_integration_test.go:101-137`. **Unblocks** the rider/driver
  history pagination plans.

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

### [rides]
- Top-level create `pickup_*`/`dropoff_*` presence + range validation — the four fields are now
  `*float64` with `binding:"required"`, so an explicit `0` is a real coordinate while an omitted
  field still `422`s naming it (`internal/handler/ride.go:39-42`); `validateCreateCoordinates`
  range-checks them via the single shared `service.CoordinateOutOfRange` (lat ∈ [-90,90], lng ∈
  [-180,180]) and answers `422 VALIDATION_ERROR` with a human `Pickup/Drop-off <dim> out of range`
  message plus an attached cause (`handler/ride.go:102-114,140-143`). `PUT /rides/:id/destination`
  and `BuildItinerary` reuse the same helper (`handler/ride.go:326`; `service/ride.go:148-157,198`),
  so the ride-creation/destination bounds live in one place. (Two pre-existing inline copies remain in
  the driver-location handler, `internal/handler/geo.go:52,114`; out of this bug's scope and not a
  regression.) No migration. Tests `internal/handler/ride_test.go:11-53`,
  `tests/multi_stop_test.go:639-764`. Closes bug #23.
- **Atomic ride-status CAS** — `UpdateRideStatusFrom(rideID, expectedFrom, status, timestamp)`
  performs one conditional `UPDATE … WHERE id=$n AND status = ANY($m)`, rejects an empty
  `expectedFrom`, returns `(false, nil)` on a lost race, and preserves the landed no-timestamp
  `no_driver_available` form (`internal/repository/ride_repo.go:26-30,346-390`). All three writers
  use it: cancel (`internal/service/ride.go:471`), `AdvanceStatus` (`:599`; lost race →
  `ErrTransitionConflict` **before** any event/fare/earnings/broadcast/push, `:603-608`), and
  `finishWithoutDriver` (`internal/service/dispatch.go:193`). DB-backed proofs
  `internal/repository/ride_status_integration_test.go:47,87,121`.
- **Identity-scoped cancel** — `CancelRide(rideID, actor, callerID)` (`internal/service/ride.go:451-513`):
  rider/driver ownership, every mismatch → 404 with the missing-ride body (`:425-440`; handler
  classification `internal/handler/ride.go:574-586`); malformed id → 422 (`:560-565`); terminal →
  `409 CONFLICT`; authorized repeat → 200 with no second event/participant push; one CAS from
  `pending|accepted|driver_arrived`, then a post-write re-read returns committed
  `cancelled_at`/`updated_at` (`:475-512`). Rider route role gate `internal/router/router.go:280`;
  driver group gate `:250-251`.
- **Offer withdrawal + per-candidate stop on cancel** — `WithdrawOffer` deletes the matching
  generation, sends `ride.offer_closed {reason:"cancelled"}`, and wakes the loop with
  `ErrOfferWithdrawn` (`internal/service/dispatch.go:580-598`; wired
  `internal/router/router.go:177`); cancel fan-out reaches the rider, the post-write assigned
  driver, and the offered driver (deduped) with `ride.updated
  {status:"cancelled",cancelled_by}` (`internal/service/ride.go:498-512,526-580`). Every offer send
  re-reads the ride first (`ridePendingOrStop`, `internal/service/dispatch.go:351-366`; call sites
  `:245,:300`), so no later candidate is offered an accepted/cancelled ride.
- **One WS+HTTP accept funnel** — `HandleAccept` is the only entry point and `acceptRide` the only
  assignment write (`internal/service/dispatch.go:522-574,646-733`); it rejects another driver
  (`ErrNotOffered`, `:534-538`), claims the generation under the mutex/token (`:540-544`), assigns
  exactly once, answers the parked loop, and re-reads to send a terminal `ride.updated` when the
  write loses. HTTP calls it (`internal/handler/ride.go:718-749`, `errors.Is`/`errors.As` →
  404/409/500, never 400); WS calls it in a goroutine and emits `ride.accept_failed`
  (`internal/websocket/hub.go:196-217`). Decline is the same pre-send claim
  (`DeclineOffer`, `internal/service/dispatch.go:623-643`).
- **§4.1.1 timeout is generation-claim-gated** — an already-buffered answer wins
  (`internal/service/dispatch.go:411-420`); the timer claims only its own token and emits
  `expired`/records `skipOfferTimeout` only when the claim succeeds (`:425-440`); a different
  generation is left untouched (`:441-444`); a claimed/absent generation makes the timeout **block**
  for the claimant's guaranteed answer (`:445-452`). Reviewer verdict **CONFIRMED**. Pinned by
  `TestNoExpiredOfferClosedAfterCommittedAccept` (`internal/service/cancel_accept_race_test.go:731-810`),
  `TestDeclineClaimsBeforeTimeout` (`:823-908`), `TestTimeoutLeavesReplacementGenerationUntouched`
  (`:910-947`) and the WS timeout test (`tests/cancel_accept_race_test.go:407-440`).
- **Race/wire tests** — service proofs (`internal/service/cancel_accept_race_test.go:173,230,251,304,
  396,432,466,499,583,616,653,731`) and HTTP/WS proofs (`tests/cancel_accept_race_test.go:100,107,128,
  141,178,185,193,216,231,258,290,347,372,407`); frame names/shapes pinned verbatim
  (`ride.accept_failed` codes, `ride.offer_closed` reasons). **Reviewer verdicts:** §4.1.1
  CONFIRMED; the decline/WS extension PARTIAL — only latent residuals, recorded as bugs #27–#30.

### [push]
- Push delivery pipeline + bug #20 — migration `018_push_pipeline.up.sql:28,31`;
  `internal/repository/device_token_repo.go:49` (upsert/reassign by globally-unique token),
  `:69` (user-scoped unregister), `:77` (list-active); `internal/repository/feedback_repo.go:30`
  (`feedback.type` persisted); `internal/service/push/provider.go:40` (`LogProvider` safe no-op),
  `:60` (`MultiProvider`), `internal/service/push/service.go:43` (void `NotifyUser`); real
  handlers `Feedback`/`DeviceRegister`/`DeviceUnregister` in
  `internal/handler/platform.go:118,164,198`; routes `/devices` + `/device-tokens` alias
  `internal/router/router.go:271-276`; best-effort non-blocking `PushNotifier` call sites
  `internal/service/ride.go:46,319,391`, wired `internal/router/router.go:133`. **Follow-up (not
  a regression):** production delivery is inert — the default `LogProvider` is wired
  (`internal/router/router.go:113-115`), `WithPushProvider`/`MultiProvider` have no production caller,
  there are no FCM/APNs credentials/SDK in this harness, and production token registration is inert:
  the **driver** app now ships the registration seam but resolves `NoopPushTokenSource` (no FCM/APNs
  dependency), so it registers nothing in a real build — `driver_app/lib/core/push/`. The **rider**
  half is Landed → `[push]` in `rider_app_plans/STATUS.md`. The canonical deferred plan for a real
  provider + real token sources is `[push]_production_provider.md`. Adversarially
  confirmed.

### [arrival]
- **Server-owned proximity arrival geofence** (landed 2026-10-13, adversarially confirmed FIXED) —
  additive `driver.location` `near_pickup`/`distance_to_pickup_m`
  (straight-line haversine) + auto `accepted→driver_arrived` via the existing state machine
  (actor `system`) inside the arrive radius, with hysteresis + min-move debounce and a
  backgrounded `ride.nearby` push; the evaluator never fails the location update and nearby
  never changes `status`. Config `GEOFENCE_{ENABLED,NEARBY_RADIUS_M,ARRIVE_RADIUS_M,HYSTERESIS_M,MIN_MOVE_M}`
  (on/300/80/30/10) `internal/config/config.go:267-273,282-287,343-349,420-422`; additive
  WS fields `internal/websocket/messages.go:90-91`; evaluator `internal/service/arrival.go:58-91`
  (hysteresis `:137-148`, clamp `:96-106`, nearby push `:167-177`); hot path
  `internal/handler/geo.go:50-59,91,173`; transition broadcast/push reuses `AdvanceStatus`
  `internal/service/ride.go:606-615`. The redundant `notify-arrival` route and
  `ArrivalNotification` handler are **removed** (`internal/router/router.go`,
  `internal/handler/platform.go`). Tests `internal/service/arrival_test.go`,
  `internal/handler/geo_arrival_test.go`, `tests/arrival_geofence_test.go`,
  `internal/config/config_test.go:467-548`; docs regenerated (`docs/swagger.{json,yaml}`,
  `RIDER_API_GUIDE.md`, `DRIVER_APP_PLAN.md`, `USER_STORIES.md`). Reported green: `make test`
  366 pass, `make lint` 0, `make test-integration` green. Closes bug #25; the rider/driver
  `01_[arrival]` consumers are condensed by their own owners.

### [payout]
- **Driver earnings ledger + `GET /driver/me/earnings` + idempotent `POST /driver/earnings/withdraw`
  (server half of driver-app bug #5).** Append-only migration
  `internal/database/migrations/024_driver_earnings.up.sql:12` (`driver_earnings`; integer
  `amount_cents` credit +/debit −; status `available/pending/paid/failed/reversed`; a partial
  unique index on `ride_id` for the exactly-once credit and one on `(driver_id, idempotency_key)`
  for the double-debit guard). `EarningsRepo` (`internal/repository/earnings_repo.go:87`
  `CreditRideEarning`, `:105` `GetEarningsSummary`, `:161` `CreateWithdrawal`): the ledger IS the
  wallet — no balance column; available = credits − withdrawals in `pending` OR `paid`, from the
  single `availableBalanceExpr`/`withdrawalCountedExpr` (`:78-85`); the withdrawal insert is a
  **negative** debit (`-amountCents`, `:221`) under a per-driver advisory lock with an in-lock
  balance re-check. Handlers `internal/handler/earnings.go:47,85`; routes
  `internal/router/router.go:242` (`GET /driver/me/earnings`) and `:329`
  (`POST /driver/earnings/withdraw` behind `idempotencyMw`). Completion credits once in
  `RideService.AdvanceStatus` (`internal/service/ride.go:62-69` `SetEarnings`; `:548-570`), and a
  failed credit is **not** best-effort (it returns 5xx). Config
  `PAYOUT_COMMISSION_RATE`/`PAYOUT_MIN_WITHDRAW_CENTS`/`PAYOUT_CURRENCY`
  (`internal/config/config.go:168-183`, wired `:351-353`, commission parsed fail-closed
  `:425-445`). Docs `RIDER_API_GUIDE.md` `## Driver Earnings`; `docs/swagger.{json,yaml}`
  regenerated. **Wire contract (cross-app, consumed by the driver app):** GET answers the
  `{"earnings":{...}}` envelope and POST answers `{"withdrawal":{...},"earnings":{...}}`; every
  money field is **integer cents** and a withdrawal debit is **negative**. Tests
  `tests/payout_test.go`, `internal/repository/earnings_integration_test.go`; mock in lockstep
  (`tests/testutil/mock_earnings_repo.go`). **Integration-tag caveat:** the production
  `pending → paid` double-payout guard is pinned **only** by the `//go:build integration` DB test
  `TestEarningsRepoPaidWithdrawalKeepsBalanceReduced`
  (`internal/repository/earnings_integration_test.go:187`) — the unit
  `TestEarningsWithdrawPaidKeepsBalanceReduced` (`tests/payout_test.go:173`) exercises the mock's
  inline predicate, not the production SQL — so `make test-integration` (DB up) **must** stay part
  of the gate or the guard ships effectively unpinned. **Cross-domain (both halves landed):** the
  driver-app withdraw UI half has since landed too — `driver_app_plans/01_[payout]_withdraw_ui.md`
  was condensed into `driver_app_plans/STATUS.md` → Landed `[payout]` (adversarially confirmed
  2026-10-15) and deleted, closing driver bug #5.

## Known bugs & issues

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 2 | ~~Estimate fallback dead by default~~ — **fixed**: `ROUTING_SNAP_RADIUS_M` ships at 50000, so a pin >50 km from any road answers 200 `is_estimate`; `0` stays the documented always-snap opt-in (recorded in Landed → [routing] stage 05) | `internal/config/config.go:130` (const + rationale `:117-130`), `:228` (the load). *No `service/navigation.go` citation here on purpose: that file is under a concurrent routing edit, so a line number written now would rot on landing* | closed | [routing] |
| 3 | ~~Residual route-preview honesty gap~~ — **closed 2026-10-15 (no API fix needed).** The rider residual named here was fixed by rider bug #2 via `[map]_route_failure_honesty.md` (rider plan now landed/deleted): the `error: (_, _)` branch is gone, **no** polyline is drawn on *any* error status, and an `is_estimate` body renders the **API** geometry dashed + labelled. The earlier "confident/silent" wording had already been corrected. The API obligation is unchanged: answer outages as 5xx or 200+`is_estimate`, **never 4xx** | rider evidence: `rider_app_plans/STATUS.md:150` (`### [map]` honesty entry), `:455` (bug #2 FIXED); `rider_app/lib/features/home/data/home_route_preview.dart:68-115`, `rider_app/lib/features/home/presentation/home_screen.dart:210-222,505-522` | closed | [errors] (client landed: rider-planner) |
| 5 | ~~**Driver-app bug #5 — no withdraw UI**~~ — **resolved 2026-10-15.** The API server half is landed (Landed → [payout]: `driver_earnings` ledger + `GET /driver/me/earnings` + idempotent `POST /driver/earnings/withdraw`), and the Flutter withdraw UI half landed too: `driver_app_plans/01_[payout]_withdraw_ui.md` was condensed into `driver_app_plans/STATUS.md` → Landed `[payout]` (adversarially confirmed 2026-10-15; bug #5 marked resolved there) and deleted — code at `driver_app/lib/features/payout/` | `internal/router/router.go:242,329`; `internal/handler/earnings.go`; `internal/repository/earnings_repo.go`; driver `driver_app_plans/STATUS.md` → Landed `[payout]` (bug #5 resolved) | closed | [payout] (client landed: driver-planner) |
| 9 | ~~No unit test at all~~ — **fixed**: `internal/middleware/idempotency_test.go` covers the partial-read re-run, the implausible-status guard, the 200/201-only store rule, the 1 MiB capture cap and the blank-key bypass. The three statements in `sqlIdempotencyStore` are still DB-free-untested (no go-sqlmock, `tests/` runs with `db=nil`) | `internal/middleware/idempotency_test.go` | closed (SQL untested) | [errors] |
| 10 | ~~`MarkStaleDriversOffline` is never called~~ — **fixed**: `run()` starts a `DriverLivenessSweeper`, which sweeps once at boot and then every `DefaultSweeperInterval` (10 s), so stale `driver_positions.status` rows are reconciled and the 30 s freshness window (`internal/repository/geo_repo.go:39`) is no longer the only bound. Scope is narrow and documented: it writes `driver_positions.status` only — `drivers.status` is untouched, and `GET /drivers/:id/location` is unchanged because its query selects no status column (`internal/repository/geo_repo.go:127-134`) | call site `cmd/server/main.go:82-84`; sweeper `internal/service/driver_liveness.go:36,55,87`; definition `internal/repository/geo_repo.go:172` | closed | [dispatch] |
| 11 | ~~A DB-fresh online driver whose socket is absent is dropped after the ~450 ms retry~~ — **fixed**: hub presence is now liveness-aware (`clientLivenessTTL`, refreshed on every frame incl. ping/pong), and a candidate that fails the fast backoff is **parked** for the bounded `socketRearmWindow` and re-offered on reconnect; only a driver who never reconnects records one `socket_not_connected` skip. **Half (b)** (the driver-side keepalive `ping()`) landed 2026-09-30 cross-app: opt-in `heartbeatInterval` loop armed on every connect (`shared/lib/src/network/websocket_service.dart:37,54-58,112,148-156`), the driver opts into 25 s and re-arms on `setOnline`/reconnect (`driver_app/lib/core/network/websocket_service.dart:17,32,45-55,78-86`), wired to presence + `publishLastPosition` (`driver_app/lib/core/location/location_service.dart:245,249`) | `internal/websocket/hub.go:23,209-220`; `internal/service/dispatch.go:194-275`; `internal/service/dispatch_observability.go:210` | closed | [dispatch] (client half landed, `driver-planner`) |
| 12 | ~~`PUT /rides/:id/destination` is a stub~~ — **fixed**: real `RideHandler.UpdateDestination` mutates `rides.dropoff_*` + the itinerary's `kind='destination'` row in one transaction, with owner/locked checks (`404`/`409`) and a safe-retry `5xx`; the `platform.go` stub is gone | `internal/handler/ride.go:285`; `internal/service/ride.go:408`; `internal/repository/ride_repo.go:165`; route `internal/router/router.go:240` | closed | [multi] |
| 15 | ~~Arrival notify is a no-op stub; `device_tokens` never written~~ — **fixed**: real backgrounded push pipeline — device register/unregister persist and `feedback.type` is stored (see Landed → [push]). The `ArrivalNotification` handler this bug was raised against was **later removed** by the `[arrival]` proximity geofence (see Landed → [arrival]); the device/feedback pipeline it fed is unchanged | `internal/handler/platform.go:164,198`; `internal/service/push/`; migration `018_push_pipeline.up.sql` | closed | [push] |
| 16 | ~~Replay stored `json.Marshal(gin.H{})` = `{}` regardless of the handler's body~~ — **fixed**: `captureWriter` tees the real body and `replayableBody` normalises it for the `JSONB NOT NULL` column | `internal/middleware/idempotency.go:202-226` | closed | [errors] |
| 17 | ~~A non-JSON replay comes back JSON-quoted / `\u`-escaped~~ — **fixed**: migration `017` adds `response_content_type` and the middleware replays via `c.Data` keyed on the stored content type (not on parseability); DB-proven by `TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres` (plain text, JSON-string, whitespace, empty, HTML bytes) | `internal/database/migrations/017_idempotency_key_scoping.up.sql:22-30`; `internal/middleware/idempotency.go:172,243,259` | closed | [errors] |
| 18 | ~~`idempotency_keys.key` is a bare PRIMARY KEY, not user-scoped~~ — **fixed**: migration `017` drops the global PK, dedupes `(key,user_id)` keeping the earliest row, adds `UNIQUE(key,user_id)` (the table now intentionally has no single-column PK); the store uses `ON CONFLICT (key, user_id)`. Proven by `TestMigration017ResolvesIdempotencyDuplicates` + `TestSQLIdempotencyStoreScopesKeysPerUser` against real Postgres | `internal/database/migrations/007_create_misc.up.sql:70-76` (old shape); `internal/database/migrations/017_idempotency_key_scoping.up.sql:34-61`; `internal/middleware/idempotency.go:68` | closed | [errors] |
| 19 | ~~The terminal dispatch trace cannot distinguish a failed `no_driver_available` write from a genuinely empty search~~ — **fixed**: a `terminal_write_failed` outcome + `noteTerminalError` + `abortIfOpen`; the terminal error rides on the trace and every dispatch exit path records a terminal state | `internal/service/dispatch_observability.go:95`; `internal/service/dispatch_traces.go:106,122`; `internal/service/dispatch.go:142`; pinned `internal/service/dispatch_test.go:649,705` | closed | [dispatch] |
| 20 | ~~`POST /feedback` ignores the client's `type` field~~ — **fixed**: `feedback.type` is persisted (migration `018`); the handler binds it and the repo inserts it, so `{"type":"app_issue","message":…}` retains the classification | `internal/database/migrations/018_push_pipeline.up.sql:31`; `internal/handler/platform.go:118-145`; `internal/repository/feedback_repo.go:30` | closed | [safety] |
| 21 | ~~Two pre-existing `make test-integration` failures~~ — **fixed 2026-09-30**: the coverage-gate fix (commit `00b2a5e`) made an out-of-radius pin report `ErrPinUncovered` (wrapped), but two integration tests still expected `ErrNoRoute`. They now assert `errors.Is(err, ErrPinUncovered)` — `TestPGRoutingRepoSnapRadius` (`internal/repository/pgrouting_repo_integration_test.go:179`) and `TestRouteInRegionPGRouting/dropoff_only_in_another_region` (`internal/repository/regions_integration_test.go:359`). The gate was correct; the test expectations were stale. `make test-integration` is green | `go test -tags=integration -run 'TestPGRoutingRepoSnapRadius\|TestRouteInRegionPGRouting' ./internal/repository/` | closed | [routing] |
| 22 | ~~Idempotency replay residual: the JSON/empty content-type branch trims surrounding whitespace (`bytes.TrimSpace`), and an empty content-type with a non-JSON body replays JSON-quoted~~ — **fixed**: every content type is stored as a JSON string of the exact captured bytes and unwrapped uniformly, so JSONB canonicalisation cannot alter the replay; empty captures replay zero bytes (no `null` sentinel); pre-change raw-JSON rows replay via the fallback. See Landed → [errors] | `internal/middleware/idempotency.go:235-238,259-267`; `internal/middleware/idempotency_integration_test.go:100,166` | closed | [errors] |
| 23 | ~~`POST /rides` binds the top-level `pickup_*`/`dropoff_*` with `binding:"required"`, so a literal `0` coordinate is rejected `422`; and none of the four top-level coords is range-checked (e.g. `999` is accepted and written to `rides.pickup_*`/`dropoff_*` verbatim), unlike stop coords, which `BuildItinerary` range-checks~~ — **fixed**: pointer fields + `required` distinguish absent from `0`, and all four are range-checked through the shared `service.CoordinateOutOfRange`. See Landed → [rides] | `internal/handler/ride.go:39-42,102-114,140-143`; `internal/service/ride.go:148-157,198`; tests `tests/multi_stop_test.go:639-764` | closed | [rides] |
| 24 | ~~Coverage-gate mismatch: ingest **0.98** vs runtime **0.99** let a 0.98–0.989 region pass ingest and silently serve flat routing on the now-default path~~ — **fixed**: one shared `DefaultElevationMinCoverage = 0.99` used by both gates (elevtool's `-min-coverage` default imports `config`, runtime `ROUTING_ELEV_MIN_COVERAGE` default) + a region-scoped `import-elevation.sh` post-import assertion. See Landed → [routing] gate correctness | `internal/config/config.go:240,336`; `cmd/elevtool/main.go:65,75`; `scripts/import-elevation.sh:28,69-72` | closed | [routing] |
| 25 | ~~The removed `POST /driver/rides/:id/notify-arrival` route had stale companion docs~~ — **fixed 2026-10-13**: the route/`ArrivalNotification` handler are gone, `docs/swagger.{json,yaml}` were regenerated (`scripts/update-openapi.sh`), `RIDER_API_GUIDE.md` / `DRIVER_APP_PLAN.md` / `USER_STORIES.md` now say the route was removed and document the additive `driver.location` proximity fields + auto `accepted→driver_arrived`, and the last API-adjacent residue (`driver_app/lib/core/api/endpoints.dart` declared constant) has been removed. No unresolved API residue remains; the `[arrival]` geofence is Landed | swagger grep for `notify-arrival` = 0; `RIDER_API_GUIDE.md:324,704`, `USER_STORIES.md:430`; `driver_app/lib/core/api/endpoints.dart` no longer declares the constant | closed | [arrival] |
| 26 | ~~**`no_driver_available` never persisted on a real database**~~ — **closed 2026-10-19, adversarially confirmed FIXED.** *Pre-fix (historical):* `UpdateRideStatus`'s status→timestamp-column switch left `statusCol == ""`, producing `UPDATE rides SET status=$1, =$2, updated_at=NOW() WHERE id=$3`; Postgres raised `ERROR: syntax error at or near "="`, so `finishWithoutDriver` always took its error branch, left the ride `pending`, and never pushed `ride.updated {status:"no_driver_available"}`. Reproduced live with `EXPLAIN`; the unit suite was green only because `MockRideRepo` models no SQL; the `rides` CHECK already allows the status. *Post-fix:* `rideStatusTimestampColumn` + `updateRideStatusQuery` emit the no-column form for `no_driver_available`, `UpdateRideStatus` branches on `withTimestamp`, and a failed write still pushes nothing. The old fix plan file is deleted (condensed into Landed → [dispatch]); the landed `[rides]` CAS write (`UpdateRideStatusFrom`) preserves the no-timestamp-column form when it supersedes the method | `internal/repository/ride_repo.go:305-355` (mapping `:305-320`, query `:330-339`, branch `:341-355`); tests `internal/repository/ride_repo_test.go:16`, `internal/repository/ride_status_integration_test.go:20` (real Postgres), `internal/service/dispatch_test.go:497`; reviewer re-ran the integration test (`PASS`, no SKIP), confirmed both old `EXPLAIN` errors and the new forms, the success push, and the two failure-path tests; `internal/service/dispatch.go:171-180` failure branch still pushes nothing; stale pre-fix mock masking `tests/testutil/mock_repos.go:627-655` | closed | [dispatch] |
| 27 | **`DeclineOffer` claims by rideID/driverID without a generation token** (latent; unreachable while only one dispatch generation per ride exists). It deletes whatever entry is present rather than comparing `cur.token` as `HandleAccept`/`WithdrawOffer`/the timeout branch do, so a re-offer for the same ride could let a stale decline claim the replacement generation | `internal/service/dispatch.go:623-637` (delete `:636`; token rule only nearby `:540-544,:425-431`) | low | [rides] |
| 28 | **Replacement-generation-then-deleted liveness case** (latent). The timeout branch treats `present` with a different token as its own timeout and returns without a frame (`:441-444`); the absent branch blocks for a claimant answer (`:445-452`). A replacement generation that is itself claimed and deleted between those observations is the retained reviewer residual — not reachable in the current one-generation-per-ride dispatch flow | `internal/service/dispatch.go:441-452`; replacement left untouched pinned by `internal/service/cancel_accept_race_test.go:910-947` | low | [rides] |
| 29 | **Cancel-vs-timeout boundary can leave the offered driver with only `expired`** (latent). If the timeout wins the generation claim just before the rider cancel, `WithdrawOffer` finds nothing and returns `""`; the offered driver gets `ride.offer_closed {reason:"expired"}` but no terminal `ride.updated {status:"cancelled"}`, because the fan-out cannot name them | `internal/service/dispatch.go:434-440,580-587`; `internal/service/ride.go:498-512,531-560` | low | [rides] |
| 30 | **`SetOfferTimeoutForTest` is an unsynchronized exported test seam** — it writes the package-level `offerTimeout` with no lock, so a test that changes it concurrently with a dispatch goroutine is a data race. Production never calls it | `internal/service/dispatch_observability.go:219-226` (`offerTimeout` at `:216`) | low | [rides] |

## Test-audit follow-ups

> From `tests/AUDIT_REPORT.md` §5. Test-infra debt, not a production bug; no plan file (no design or
> schedule yet). The DDL item below is resolved and was adversarially CONFIRMED-LANDED by running the
> DB-backed suite.

- **DDL fixture duplication across repository integration tests** (`tests/AUDIT_REPORT.md` §5.4) —
  **RESOLVED** (landed, adversarially confirmed; `make test-integration` **402 PASS / 0 FAIL / 1
  opt-in SKIP**, `make lint` 0 issues). The canonical TEMP-table DDL now lives once in
  `internal/repository/testdb_integration_test.go` (`//go:build integration`): `createRidesTable`
  with the `ridesFull`/`ridesFareQuote`/`ridesActuals` `ridesSchema` enum, `createRideStopsTable`,
  `createRideTrackPointsTable`, `createRoutingRegionsTable`,
  `createFareRegionsTable`/`createFareRatesTable`/`createFareRatesActiveIndex`/
  `createFareDemandWindowsTable`, and `createSingleRegionRoadTables`; `mustExec` is widened to
  `testing.TB` (`pgrouting_repo_integration_test.go:32`) so the routing benchmark reuses it. Shared
  by the 11 repository `//go:build integration` test files that reference the helpers (10 callers
  plus the definitions file) and by `pgrouting_repo_benchmark_test.go`, replacing the four divergent
  `rides` declarations and the repeated `routing_regions` / `road_network_{vertices,edges}_pgr`
  pairs named in the original finding. **Two honest caveats:** (a) the single source of truth is
  **package-local** — the three suites outside `package repository`
  (`internal/service/pin_uncovered_integration_test.go`,
  `internal/service/fare_recompute_integration_test.go`,
  `internal/database/fare_seed_integration_test.go`) cannot import the helpers and still hand-roll
  their DDL; (b) the fixtures deliberately drop some production CHECKs/FKs (e.g. the
  `fare_regions`→`routing_regions` and `fare_rates`→`fare_regions` FKs, and the `vehicle_type` /
  `day_mask` / `multiplier` CHECKs) to keep insert ordering flexible, so the **migrations remain the
  schema oracle**, not the fixtures.
- **The integration gate can be green-by-skip when Postgres is absent** (test-infra debt, not a
  production bug). `connectPG` calls `t.Skipf` when the DB is unreachable
  (`internal/repository/pgrouting_repo_integration_test.go:22,26`), so a DB-less CI run reports the
  required `pending → no_driver_available` gate as SKIP, not FAIL. Run `make test-integration` against
  the `ride-hailing-db` container for that gate to mean anything.
- **Pre-existing decline flake, unrelated to the SQL hotfix** (test-infra debt, not a production
  bug). `TestDispatchDeclineHTTPRecordsDriverDeclined` (`tests/dispatch_decline_test.go:75`, second
  decline expects 404) failed 2/13 runs with 200 vs 404; it reproduces independently of the
  `no_driver_available` change and is not caused by it.

## Preserved records (resolved — not open)

| File | Tag | Why it is kept |
| --- | --- | --- |
| `[elevation]_calibration_and_rollout_gate.md` | elevation | **Resolved 2026-10-05.** Holds the 2026-09-29 NO-GO, the 2026-10-04 supersession and the resolved remaining-work items verbatim; the skill's delete-on-land is waived by the recorded supersession decision. G1 stays a permanent dataset limitation and the accepted risk is recorded in the flip commit |
| `[elevation]_review.md` | elevation | Historical 2026-09-25 pre-implementation adversarial review — every finding dispositioned and all reviewed stages landed. Its prose keeps the pre-renumbering stage numbers; see the mapping note at the top of the file |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[elevation]_duration_calibration_data.md` | elevation | landed elevation cost model + DEM ingest + default-on flip; landed `[tracking]` actuals (`ride_track_points`, migration 021) | **chain head** — derive + document the per-segment grade-vs-observed-speed calibration dataset from `ride_track_points` (read-only deterministic tool + artifact/schema + documented fit procedure + coverage report). Blocked only on the derivation meeting its acceptance bar, **not** on the absence of a trace — the trace table exists |
| `01_[elevation]_duration_model.md` | elevation | open `[elevation]_duration_calibration_data.md` | Grade-aware `total_duration_s`; **blocked** on the calibration-data head. Distance stays true meters and the flip changes no duration |
| `[elevation]_pgrouting_parity.md` | elevation | pgrouting engine + elevation columns (landed) | **deferred**; add `reverse_cost`/`cost_ascent` migration + elevation-aware edges SQL, backfilled by a script referenced from `import-osm` |
| `[routing]_intercity.md` | routing | routing region resolution (STATUS.md) | **deferred**; holds the archived overlay-ports/planner design |
| `[routing]_valle_central.md` | routing | landed `[routing]` gate correctness + snap-radius coverage (STATUS.md) | **open (independent, unnumbered — renamed back from `01_` now that its prerequisite is landed)** — one `valle_central` region (`level=state`, `parent_region='cr'`) covering the **Central Valley BASIN** (supersedes the nationwide/province question; the 4 full provinces are **out** — Alajuela reaches the northern border, San José the Pacific). Within-basin trips road-follow; any pin outside the basin (incl. the rest of the 4 provinces and cross-basin trips) → 200 `is_estimate`. **TOP OPEN INPUT:** the exact basin polygon (`regions/valle_central.poly`, CONFIRM-BEFORE-IMPORT) vs the bbox fallback `-84.45,9.65,-83.65,10.25`. Remaining: clip + import `valle_central`; the elevation gate fix (bug #24) is now **landed** (STATUS.md → Landed `[routing]` gate correctness), so run the `--region valle_central` backfill; one fare card (`make seed-fares SEED_FARES_REGION=valle_central`); retire the `cr-sj` **network** rows (edges before vertices) + single `default_region` owner; restart; then the **final `cr-sj` delete** (`fare_rates`→`fare_demand_windows`→`fare_regions`→`routing_regions`, FK order, guarded on no active `cr-sj` ride; historical `rides.fare_region_id` audit refs go stale by design — no FK); acceptance tests. Still open: any downstream keying on `cr-sj`. **No app contract change** beyond `region_id` moving `cr-sj`→`valle_central` for new rides (completed keep booked `cr-sj`; no app keys on it) |
| `[push]_production_provider.md` | push | push delivery pipeline + device-token registration seam (STATUS.md) | **deferred** — wire real FCM/APNs/web providers behind `push.Provider`/`MultiProvider` (the shipped `LogProvider` is a no-op) and real token sources (both apps ship `NoopPushTokenSource`); no credentials/SDK exist in this harness. Canonical push file; the rider/driver halves are referenced by path from their own STATUS, not duplicated |
| `[auth]_web_session_token_contract.md` | auth | — | **contract record, no API change**: the rider-web session bug is fixed Flutter-only. Documents the Bearer refresh contract (15m access / 720h refresh, rotate-and-revoke, 401-vs-5xx, `AllowAllOrigins` rules out cookies) + the client obligations (cold-start exchange, atomic rotated-token persist, single-flight refresh) and contract guardrails |
| `[arrival]_accept_time_evaluation.md` | arrival | landed `[rides]` CAS + accept funnel (STATUS.md → Landed `[rides]`) | **open** — evaluate arrival once inside the single accept write (`DispatchService.acceptRide`) from the last `driver_positions` fix, SQL-side freshness-gated at **60 s** (`NearbyDriverResult.AgeS` selected by the existing `GetDriverLocation`; no `DriverFix`/new read), so a driver who accepts while already inside the 80 m arrive radius no longer depends on the client re-publishing a fix. Covers the WebSocket accept (the primary path) as well as the HTTP fallback; the evaluation must never fail the accept, is **arrive-only** (never fires `ride.nearby` or touches nearby hysteresis). CAS is **adopted verbatim** from the now-landed `[rides]` work (`UpdateRideStatusFrom` + `ErrTransitionConflict`); this plan adds no repository method/sentinel and only requires the accept-time evaluation + concurrent `PUT /geo/driver/location` ⇒ exactly one transition/event/broadcast test. App-side re-publish stays as defence. **Decision-complete** — D1=A + env knob `GEOFENCE_ACCEPT_FIX_MAX_AGE_S` (default 60 s, unset/empty→60, garbage/non-finite/≤0→skip; independent of `GEOFENCE_ENABLED`), D2=A SQL-side `AgeS`, D3=A keep both WS patches (`accepted` then `driver_arrived`, evaluation after the accepted sends, zero client change), D4=A arrive-only, D5=A CAS adopted from the landed `[rides]` work, D6=B no `DriverFix`. **Unblocked** — its `[rides]` prerequisite is now landed; no product decisions remain |

**Deferred follow-up (no plan file yet) — receipt-level per-leg breakdown:** the completed-ride
receipt/history would need the per-leg split stored on the ride (a new row/columns → a migration)
so it can be rendered after the fact. Only the estimate response carries `legs` today (Landed →
`[fare]`, above); design this as its own additive plan (response + migration) when the product
asks, preserving the single-summed-price semantics and the estimate `legs` contract.

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

> Status: **landed, both halves** (2026-10-15; condensed into Landed → `[payout]`). The decisions
> below are settled and implemented, and the driver-app withdraw UI half has also landed
> (`driver_app_plans/STATUS.md` → Landed `[payout]`, adversarially confirmed 2026-10-15 — driver
> bug #5 resolved).

- **Integer cents** in the ledger; the `float64` ride fare is converted once at credit time.
- **No wallet column**: available = **lifetime earned − withdrawals in `pending` OR `paid`**
  (`availableBalanceExpr` / `withdrawalCountedExpr`, `internal/repository/earnings_repo.go:78-85`;
  single source of truth, no drift). A withdrawal debit reduces the balance from request (`pending`)
  through settlement (`paid`). ⚠️ The older prose here — "`SUM(amount_cents)` over `status='available'`
  rows" — was **wrong**: it would let a `pending` debit drop out, so the same earnings could be
  withdrawn twice. Do **not** realign the code to it; that reintroduces immediate overdraw.
- **Commission defaults to 0** in dev (`PAYOUT_COMMISSION_RATE`); per-region/versioned fares are
  deferred to the `fare.go` trigger.
- **Withdrawal is a `pending` ledger debit, not a bank transfer** — no external payout provider in
  this plan; the API is honest about the pending state.
- **Withdraw is idempotent** (`Idempotency-Key`), like create-ride.

## Decisions already taken — [elevation] (do not re-litigate)

> Recorded 2026-10-04. Supersedes the 2026-09-29 gate's NO-GO **as a blocker**; the measured
> verdict itself is preserved verbatim in `[elevation]_calibration_and_rollout_gate.md`.

- **Elevation SHOULD avoid steep roads.** The gate escalated this as a product question ("who pays
  for flatter?") and deliberately refused to answer it; the product owner answered: flatter routes
  are a service-quality feature worth pricing.
- **Rider exposure is bounded, not open-ended.** The answer is "surface it *and* cap it":
  `total_ascent_m` is already landed additively, and the climb uplift is a **capped** percentage of
  the distance leg (Landed → `[fare]` capped grade uplift, above). No uncapped "hill tax" ever ships.
- **The NO-GO is superseded, never deleted.** It stays in the gate plan with its numbers; what
  changed is the decision, not the measurement.
- **G1's flat-control certification is abandoned as impossible on this import**, not merely
  deferred: no ≤15 m / ≥500-vertex cluster exists (best box = 33 m relief). Recorded as a permanent
  dataset limitation, with the **accepted risk** that flat-invariance evidence rests on an
  uncertified control. Importing a genuinely flat CR extract is *not* being done.
- **The remaining gate work (b) + (c) landed 2026-10-05**, then the flip: G6 estimator built
  (calibrated `DeadbandM=3.8`), full **N=2000** sweep run (G2 168/2000), default flipped. The
  execution plan is condensed into Landed → `[elevation]` and deleted (git history is the
  archive).
- **Operating point (now the shipped default): `asc12_db3.8`** (`AscentW=12`, `DescentW=0.3`,
  `MaxGrade=0.15`, `DeadbandM=3.8`). This supersedes the earlier "by-eye `asc12_db8`" wording by
  the plan's own "measured wins / no tuning by eye" rule: at asc12 the calibrated 3.8 beats db8 on
  the ascent objective (168 vs 150 qualifying pairs, median ascent 0.9314 vs 0.9461) at a
  negligible 0.0004 meters-median cost. The *old* shipped defaults (1.5/0.3/0.15/3.0) were
  **inert** (median ascent ratio 1.0000) and are the historical pre-flip finding. Native engine only.
- **The pre-elevation engine is still reproducible exactly** by the zero-weight
  `CostWeights{}`/`Route`, by `ROUTING_ELEVATION=off`, or by any install/region with no (or
  below-`MinCoverage`) elevation data — the coverage gate degrades to flat. That stays a hard
  invariant after the flip.
- **Duration is deliberately untouched.** Grade-aware `total_duration_s`
  (`01_[elevation]_duration_model.md`) stays blocked on the open chain head
  `[elevation]_duration_calibration_data.md`: the raw per-ride driver-fix trace now exists
  (`ride_track_points`, migration 021), but the derived + documented grade-vs-speed calibration
  dataset does not — the flip does not solve it and must not quietly change the time fare.

## Decisions already taken — [fare] (do not re-litigate)

> Condensed 2026-10-05 from the landed chain head (region-scoped pricing engine, deleted; git
> history is the archive). Stage 02 (actuals recompute) resolved the quote-vs-charge policy
> 2026-10-06 — recorded below, **not open**.

- **The actual REPLACES the quote, uncapped in both directions.** On completion the charge is
  recomputed from the stored actuals (driven distance + elapsed time) against the **booked** card and
  the **booked** conditions multiplier; the result is charged as-is, with no ± tolerance and no cap.
  A NULL actual (no usable trace/timestamp) falls back to the booked quote unchanged — never a
  fabricated recompute. This is a deliberate product decision, not a pending question.
- **FINAL ONLY on the wire.** Every read path (ride JSON, receipt, driver history) resolves to the
  final charge; there is no separately displayed "quoted" line. The quote is copied to the
  `quoted_*` audit columns and hidden (`json:"-"`), so the JSON shape is unchanged for a client that
  ignores it. (`quoted_*` still exists for audit/support; do not surface it without a product call.)
- **The recompute is exactly-once.** The `FinalizeRideFare` UPDATE is guarded on
  `quoted_total_fare IS NULL`, and the state machine rejects `completed→completed`; a retry is a
  no-op for the fare. Booked `fare_rate_id`/`fare_region_id` are used, so a later rate change or
  region-card correction cannot retroactively reprice a finished ride.
- **Rate card is a versioned, per-region `fare_rates` table** (integer cents; a price change is a
  new effective-dated row, never an in-place `UPDATE`). Commercial region attributes (currency +
  IANA timezone) live in `fare_regions`, never in `routing_regions`.
- **Fuel is absorbed into `per_km_cents`** — no fuel line item; the derivation happens at
  card-author time (`make seed-fares`), never per request.
- **One unified multiplier**: `conditions_multiplier = demand(region-local time) × supply(nearby
  drivers)`, clamped to `[1.0, FARE_MAX_MULTIPLIER]` (default 3.0). Demand windows are evaluated
  in the region's IANA timezone; a missing timezone means factor 1.0, never a guessed offset.
  Empty windows reproduce the pre-`[fare]` fare exactly.
- **No cross-region price fallback.** A region with no active card is a configuration error (typed
  `FareConfigurationError` → 500 `INTERNAL`); the only fallback is the registry's
  `default_region=TRUE` row when a ride has **no** region at all (estimate/legacy). `make seed-fares`
  is a required per-region deploy step.
- **Pricing is a local operation** (main DB only): a region's `datasource` pool is never queried to
  price a ride, so a down city database degrades to an estimate and never to a pricing outage.
- **Climb uplift is capped, never open-ended.** The grade uplift is a **capped** percentage of the
  distance leg (Landed → `[fare]` capped grade uplift, above); no uncapped "hill tax" ever ships.

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
- `[errors]`: idempotency replay is **byte-faithful for every content type** — the body is stored as a
  JSON *string* of the exact captured bytes and unwrapped uniformly, so the `JSONB` column cannot
  canonicalise whitespace, key order or numeric formatting; an empty body replays zero bytes, never
  `null`. A pre-change raw-JSON row is the one documented exception (replayed JSONB-canonicalised,
  still valid JSON). A replay echoes the original `Content-Type`.
- **Fail closed on revocation.** If a token or password-reset token cannot be revoked, no new
  token pair is minted and the password is not changed. Do not "optimise" the error away.
- Mocks in `tests/testutil` move in lockstep with the repositories: a mock must be able to return
  the failures its production counterpart can. A branch only production can fail is untested.
- `[elevation]`: reported distance stays true meters; **default on** for the native engine
  (flipped 2026-10-05; `off` via env); a missing/partial-coverage region degrades to flat
  (`elevation_aware=false`, ascent/descent 0), never garbage.
- `[fare]`: pricing is a **local** main-DB operation (card/region/timezone only) and **never prices
  region A with region B's card**; a region with no active card fails closed (500), and the
  `default_region=TRUE` row is a fallback only for a ride with **no** region at all
  (estimate/legacy). Money is integer cents with one final half-up round; a rate change is a new
  versioned row; the unified multiplier is clamped `[1.0, FARE_MAX_MULTIPLIER]`. `FARE_CURRENCY`
  and the card/region currencies must agree.
- `[fare]`: the climb uplift multiplies the **distance leg only** and is clamped `[0, cap]` from the
  resolved card; it is exactly `0` unless the route is elevation-aware, the leg is non-zero, the
  card enables it and the route climbed — a descent never credits the rider. A fail-flat total
  keeps the old single final half-up round, bit for bit.
- `[fare]`: on completion the recomputed **actual replaces the quote uncapped in both directions**
  and is the **only** charge shown; the booked quote is `quoted_*` audit-only and hidden from JSON.
  NULL actuals fall back to the booked quote, and the recompute reuses the **booked** card + booked
  conditions multiplier (never re-sampled) so it is deterministic and exactly-once.
- `[arrival]`: the proximity geofence **never fails the location update** and never changes its
  status code (204 success / existing 422/500); a failed or lost-race `accepted→driver_arrived`
  transition is logged and swallowed. The arrive gate is the **only** auto path to
  `driver_arrived` (the manual `PUT /:id/status` stays as an explicit override), it fires only for
  the ride's own `driver_id`, and `MIN_MOVE` debounces the nearby crossing **only** — never the
  arrive gate. `near_pickup` is advisory and **never changes `ride.status`**: a push must never
  announce a status the database does not hold.
- `[payout]`: the two earnings endpoints speak **integer cents end-to-end** (the documented
  exception to the ride JSON's major-units rule — the client converts once at render time). A
  withdrawal is a **recorded `pending` ledger debit, never a bank transfer**; the ledger IS the
  wallet (no balance column anywhere — available is derived, so credit and debit cannot drift).
  The completion credit is exactly-once (partial unique index on `ride_id`) and a failed credit
  **fails completion with 5xx** — the one non-bests-effort money write in the request path.
  `EarningsRepository`/`MockEarningsRepo` move in lockstep.

## Verification

```bash
make test                       # unit tests, no DB (must stay green)
make lint                       # golangci-lint v2, schema v2 config; 0 issues
make test-integration           # DB-backed
gofmt -w <files> && go vet ./...   # golangci-lint is NOT on PATH by default: PATH="$PATH:$(go env GOPATH)/bin"
```

## Wave-1 condensed 2026-09-30
- [routing]_estimate_fallback_default (bug #2), [routing]_native_engine_default (bug #1), [errors]_route_outage_contract_test, [dispatch]_reliability_and_no_driver_false_negative, [errors]_idempotency_middleware_tests + [errors]_idempotent_replay_body: landed, files deleted, evidence in STATUS.md Landed sections. ~~Routing regression N1 (native snap gate returns 500 instead of 200 estimate for uncovered pins ~265m band) remains; fix owned by routing planner.~~ **Correction 2026-10-15: N1 is landed.** `ErrPinUncovered` + the `coverageAuthority` split + the service's `200 is_estimate` mapping shipped in `00b2a5e` (2026-09-30), pinned by `TestRadiusBoundaryBandBetweenTheTwoCoveragePredicates` (`internal/repository/pin_uncovered_test.go:116-178`) and `tests/route_uncovered_estimate_test.go:26`; see Landed → [routing] coverage-gate correctness (the §A1 half). The stale "remains" here was never reconciled until now.

## Wave-2 condensed 2026-10-03
- [multi]_add_stops_change_destination (closes bug #12), [push]_delivery_pipeline (closes bugs #15/#20): landed, files deleted, evidence in Landed → [multi]/[push]. Also closed by verification this wave: #17 + #18 (idempotency content-type/user-scoping, migrations `017` + middleware/integration tests) and #19 (dispatch terminal-write outcome). New known bug #23 (top-level create `dropoff_*` is `binding:"required"` so `0` is rejected, and is never range-checked); residual idempotency caveat #22. Adversarially confirmed by `antagonistic-reviewer` runs.
- Push follow-up (not a regression): production delivery is inert — no FCM/APNs provider is wired and
  production token registration is inert; the driver app's registration seam is landed but resolves
  `NoopPushTokenSource`, and the rider half is tracked in `rider_app_plans` (Landed → [push]).

