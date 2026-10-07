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
  there are no FCM/APNs credentials/SDK in this harness, and production token registration is inert:
  the **driver** app now ships the registration seam but resolves `NoopPushTokenSource` (no FCM/APNs
  dependency), so it registers nothing in a real build — `driver_app/lib/core/push/`. The **rider**
  half is Landed → `[push]` in `rider_app_plans/STATUS.md`. Adversarially
  confirmed.

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
| 17 | ~~A non-JSON replay comes back JSON-quoted / `\u`-escaped~~ — **fixed**: migration `017` adds `response_content_type` and the middleware replays via `c.Data` keyed on the stored content type (not on parseability); DB-proven by `TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres` (plain text, JSON-string, whitespace, empty, HTML bytes) | `internal/database/migrations/017_idempotency_key_scoping.up.sql:22-30`; `internal/middleware/idempotency.go:172,243,259` | closed | [errors] |
| 18 | ~~`idempotency_keys.key` is a bare PRIMARY KEY, not user-scoped~~ — **fixed**: migration `017` drops the global PK, dedupes `(key,user_id)` keeping the earliest row, adds `UNIQUE(key,user_id)` (the table now intentionally has no single-column PK); the store uses `ON CONFLICT (key, user_id)`. Proven by `TestMigration017ResolvesIdempotencyDuplicates` + `TestSQLIdempotencyStoreScopesKeysPerUser` against real Postgres | `internal/database/migrations/007_create_misc.up.sql:70-76` (old shape); `internal/database/migrations/017_idempotency_key_scoping.up.sql:34-61`; `internal/middleware/idempotency.go:68` | closed | [errors] |
| 19 | ~~The terminal dispatch trace cannot distinguish a failed `no_driver_available` write from a genuinely empty search~~ — **fixed**: a `terminal_write_failed` outcome + `noteTerminalError` + `abortIfOpen`; the terminal error rides on the trace and every dispatch exit path records a terminal state | `internal/service/dispatch_observability.go:95`; `internal/service/dispatch_traces.go:106,122`; `internal/service/dispatch.go:142`; pinned `internal/service/dispatch_test.go:649,705` | closed | [dispatch] |
| 20 | ~~`POST /feedback` ignores the client's `type` field~~ — **fixed**: `feedback.type` is persisted (migration `018`); the handler binds it and the repo inserts it, so `{"type":"app_issue","message":…}` retains the classification | `internal/database/migrations/018_push_pipeline.up.sql:31`; `internal/handler/platform.go:118-145`; `internal/repository/feedback_repo.go:30` | closed | [safety] |
| 21 | ~~Two pre-existing `make test-integration` failures~~ — **fixed 2026-09-30**: the coverage-gate fix (commit `00b2a5e`) made an out-of-radius pin report `ErrPinUncovered` (wrapped), but two integration tests still expected `ErrNoRoute`. They now assert `errors.Is(err, ErrPinUncovered)` — `TestPGRoutingRepoSnapRadius` (`internal/repository/pgrouting_repo_integration_test.go:179`) and `TestRouteInRegionPGRouting/dropoff_only_in_another_region` (`internal/repository/regions_integration_test.go:359`). The gate was correct; the test expectations were stale. `make test-integration` is green | `go test -tags=integration -run 'TestPGRoutingRepoSnapRadius\|TestRouteInRegionPGRouting' ./internal/repository/` | closed | [routing] |
| 22 | ~~Idempotency replay residual: the JSON/empty content-type branch trims surrounding whitespace (`bytes.TrimSpace`), and an empty content-type with a non-JSON body replays JSON-quoted~~ — **fixed**: every content type is stored as a JSON string of the exact captured bytes and unwrapped uniformly, so JSONB canonicalisation cannot alter the replay; empty captures replay zero bytes (no `null` sentinel); pre-change raw-JSON rows replay via the fallback. See Landed → [errors] | `internal/middleware/idempotency.go:235-238,259-267`; `internal/middleware/idempotency_integration_test.go:100,166` | closed | [errors] |
| 23 | ~~`POST /rides` binds the top-level `pickup_*`/`dropoff_*` with `binding:"required"`, so a literal `0` coordinate is rejected `422`; and none of the four top-level coords is range-checked (e.g. `999` is accepted and written to `rides.pickup_*`/`dropoff_*` verbatim), unlike stop coords, which `BuildItinerary` range-checks~~ — **fixed**: pointer fields + `required` distinguish absent from `0`, and all four are range-checked through the shared `service.CoordinateOutOfRange`. See Landed → [rides] | `internal/handler/ride.go:39-42,102-114,140-143`; `internal/service/ride.go:148-157,198`; tests `tests/multi_stop_test.go:639-764` | closed | [rides] |
| 24 | **Coverage-gate mismatch (surfaced by the Stage-3 audit).** The ingest gate is **0.98** (`cmd/elevtool/main.go:56`, `scripts/import-elevation.sh:23`) but the runtime gate is **0.99** (`defaultElevationMinCoverage`, `internal/config/config.go`). A region that imports at 0.98–0.989 passes ingest, then silently serves **flat routing on the now-default path**; the only signal is a per-graph log line. Before the flip this only meant "elevation off"; now it means the default path is flat for that region. Fix is a shared coverage constant (or aligning the ingest gate up), not a silent tolerance | ingest `cmd/elevtool/main.go:56`, `scripts/import-elevation.sh:23`; runtime `internal/config/config.go:139` (const), gate `internal/repository/navigation_repo.go:439-441` (log) | medium | [elevation] |

## Preserved records (resolved — not open)

| File | Tag | Why it is kept |
| --- | --- | --- |
| `[elevation]_calibration_and_rollout_gate.md` | elevation | **Resolved 2026-10-05.** Holds the 2026-09-29 NO-GO, the 2026-10-04 supersession and the resolved remaining-work items verbatim; the skill's delete-on-land is waived by the recorded supersession decision. G1 stays a permanent dataset limitation and the accepted risk is recorded in the flip commit |
| `[elevation]_review.md` | elevation | Historical 2026-09-25 pre-implementation adversarial review — every finding dispositioned and all reviewed stages landed. Its prose keeps the pre-renumbering stage numbers; see the mapping note at the top of the file |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[elevation]_duration_model.md` | elevation | landed elevation cost model + DEM ingest + default-on flip; blocked on a driver-trace dataset | Grade-aware `total_duration_s`; **blocked** — no driver-trace/drive-time dataset exists to calibrate the speed-vs-grade curve. Distance stays true meters and the flip changes no duration |
| `[elevation]_pgrouting_parity.md` | elevation | pgrouting engine + elevation columns (landed) | **deferred**; add `reverse_cost`/`cost_ascent` migration + elevation-aware edges SQL, backfilled by a script referenced from `import-osm` |
| `[routing]_intercity.md` | routing | routing region resolution (STATUS.md) | **deferred**; holds the archived overlay-ports/planner design |
| `[payout]_driver_earnings_and_withdraw.md` | payout | — | **deferred**: server half of driver-app bug #6 — `driver_earnings` ledger + credit-on-completion + real `GET /driver/me/earnings` and idempotent `POST /driver/earnings/withdraw` (pending debit, no external payout); design settled, no scheduling |

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
  (`[elevation]_duration_model.md`) stays blocked on a driver-trace dataset — the flip does not
  solve it and must not quietly change the time fare.

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
- Push follow-up (not a regression): production delivery is inert — no FCM/APNs provider is wired and
  production token registration is inert; the driver app's registration seam is landed but resolves
  `NoopPushTokenSource`, and the rider half is tracked in `rider_app_plans` (Landed → [push]).

