# api_plans — Routing & Platform Plans (index)

Goal: evolve the API's routing layer from the current single-city in-process Go A\* engine
(`internal/routing`) into a **region-indexed, multi-city routing platform** that keeps the
`/api/v1/navigation/route` and `/estimates/*` contracts stable and makes the API **usable
from any place in the world**: a rider's/driver's position selects the region, and routing
runs fast on that region's native graph. Intercity (a path BETWEEN cities) is explicitly
deferred to a stub (plan 07) and does not block this series. Each plan below is
**self-contained and small** — sized so a fresh model context window can execute it by
reading *this file only* plus the files it names. Facts (current code refs, table layout,
pitfalls) are embedded inline; the routing stack is documented in
`.opencode/skills/road-routing/SKILL.md` and `RIDER_API_GUIDE.md`.

## Plans

| File | Work | Depends on |
|---|---|---|
| `01_benchmarks_and_snap.md` | Add `BenchmarkRoute`/nearest-node benchmarks to the current engine + replace the O(V) linear `NearestNode` scan with an in-process spatial grid index (**do first**: produces the baseline and fixes the biggest per-request cost before anything else churns). **Implemented**: grid snap ~77,000× faster than linear (163 ns vs 12.4 ms), new bench targets `make benchmark`, numbers recorded in the plan | none |
| `02_enable_pgrouting_infra.md` | Make pgRouting **available**: swap the image (`postgis/postgis:16-3.4-alpine` → `pgrouting/pgrouting:16-3.5-4.0`), make init idempotent, guard the migration-011 stub + demo seed, new migration 012 converges a reused volume (`DROP`/recreate, **geo-guarded** seed purge — vertex ids are per-extract SEQUENTIAL, an id-based purge deleted real SJ data, postgis catalog update) without Go changes | 01 |
| `03_swap_engine_to_pgrouting.md` | Swap the engine to real `pgr_dijkstra`: repo split (`NativeNavigationRepo` / `PGRoutingRepo`), factory at `internal/router/router.go:32`, GIST KNN snapping (index-ordered search + geodesic `::geography` meters — the `<->` value is degrees, never a threshold), 8-column projection, `ROUTING_ENGINE` toggle, DB tests/benchmarks (**fix `make test-integration` → `./...`**), benchmark **decision gate** keeps `native` default until pgRouting passes | 02 (extension real), 01 (baseline) |
| `04_region_schema_and_registry.md` | Model the network as routing **regions** — the worldwide `position → region` index: `routing_regions` registry (+ `cr`/`cr-sj` seeds, province bbox, `default_region`), `region_id` + composite PKs (concrete constraint names, 008 FKs rebuilt) on pgr **and** 008 tables, per-region GIST (vertices only — edges have no geom)/btree indexes, `routing_datasources` + `routing_regions.datasource` (same-DB default; separate-DB option) | 03 |
| `05_region_resolution_and_import.md` | Resolve a position to the ONE winning region (snap-first, `default_region` fallback); **region-scoped import** (`--region`, per-region gate + region-scoped `DELETE`, 008 FK wipe order, self-registration via `ST_Extent`, `getFloat` helper); no-coverage → HTTP 200 straight-line **estimate** with `is_estimate:true` (NOT 422) | 04 |
| `06_multi_city_single_stack.md` | **One API stack, many cities, position-loaded**: per-region native graph cache ("native after the region is determined", lazy/import-fresh/evictable via `ROUTING_MAX_REGIONS_IN_MEMORY`), `map[datasourceID]*sqlx.DB` pools from the plan-04 registry, importer `--datasource`; deployment shapes near (one cluster, per-city DBs + pgbouncer packs) / far (separate full deploys sharing only the registry); everything per-region so one city never blocks another; unreachable datasource → that region degrades to estimate | 05 (resolver), 04 (registry) |
| `07_intercity_future_stub.md` | **Intercity — DEFERRED.** No ports, no leg chaining, no chain-escalation; only prep that cannot interfere (level/parent hierarchy in the plan-04 schema). Holds the deferred design register + the archived overlay-ports/intercity-planner detail for the later revisit | none (never blocks 04–06) |
| [`elevation/README.md`](elevation/README.md) | **Sub-series — elevation-aware routing (native engine).** 5 small stages in `api_plans/elevation/`: directional cost model (01, no DB) → `elevation_m` column + repo/config plumbing (02, migration 015) → DEM ingest + noise control (03) → calibration + rollout gate (04) → deferred duration/API/parity (05). Orthogonal to 03–06: changes the native engine's *cost function*, not the engine, the region model, or the endpoint contract. Default OFF. See `elevation/REVIEW.md` for the adversarial review | none (engine-internal; composes with 04–06) |
| [`errors/README.md`](errors/README.md) | **Sub-series — the API error contract.** 3 small stages in `api_plans/errors/`: repository error taxonomy (`ErrNotFound`/`ErrConflict` + `*pq.Error` SQLSTATE, mocks moved in lockstep — 01) → one `respond`/`respondRepo` over the already-dead `ErrorResponse` types, `errors.Is` → status/code, and `c.Error` instrumentation for the 5 handler files that have none (02) → stop leaking go-playground/validator text from the 22 `ShouldBindJSON` sites, document the envelope (03). Orthogonal to everything above: changes **what the API says when it fails**, not routing. Generalises the pattern the routing layer already uses (`routing.ErrNoRoute`, `repository.ErrDatasourceUnavailable`, `navigation.go:141`) | none (composes with 01–07) |

Recommended order: 01 → 02 → 03 → 04 → 05 → 06 → 07. Each plan lands a working, testable
state; nothing except 01→02 and the numbering requires the previous plan to be *deployed*,
only that it *exists* (later plans assume the interface and file layout from earlier ones).
06 (multi-city single-stack) is the deployment/ops layer over the region series — schedule it
before adding a second real city. 07 is a stub only: intercity is deferred and must not
block or interfere with 04–06.

`elevation/` and `errors/` are separate sub-series with their own ordering; neither ever blocks
01–07 and none of 01–07 block them. Read each sub-series' `README.md` first — they carry the
invariants their series is judged against. For `elevation/`: reported distance stays in true
meters, default off, missing elevation degrades to flat. For `errors/`: success paths and
status codes for *valid* requests never change, a genuine outage answers 5xx or 200 +
`is_estimate` and never 4xx (the rider app draws a straight line on *every* error status, so a
misclassified 4xx silently renders a wrong route), a cause is logged whenever a message is
generalised, and the mocks move in lockstep with the repositories.

## Golden rules (carried over from the rest of the repo)

1. **`NavigationRepository` interface signature is frozen** — `GetShortestPath(fromLat,
   fromLng, toLat, toLng float64) ([]RouteResult, error)` is consumed by
   `service.NavigationService` and by `tests/testutil/mock_navigation_repo.go`. Engine swaps
   are invisible to every test that mocks the repo. New capabilities (region resolution,
   multi-city datasource dispatch) ride on **optional interfaces** asserted downstream with
   `, ok :=`.
2. **Route cost must stay in meters.** `total_distance_m`, `total_duration_s`, and the fare
   estimator all assume `AggCost` == distance in meters. `pgr_dijkstra` must run over edges
   whose `cost` is meters (`road_network_edges_pgr.cost` already is; don't "fix" it).
3. **Keep the Go engine alive as a fallback.** The native engine (plan 01 retains it) is the
   dev/edge fallback behind a `ROUTING_ENGINE` toggle until untested — never delete the package
   outright. Separately, the rider app's straight-line fallback fires on **every** error status
   (`rider_app/.../home_screen.dart:127` is `error: (_, _)`), not only on a 500 — so any routing
   failure that should be visible to the user must not be answered with a 4xx.
4. **Migrations are append-only, executed in sorted order.** The runner
   (`internal/database/migrate.go`) executes only `*.up.sql`, version = numeric prefix before
   the first `_`. `.down.sql` files are documentation only. New work = a new numbered
   migration; rewrites of old ones must remain safe for already-applied DBs.
5. **NO assumptions about pgRouting being installed.** Only plan 02 makes it real; every plan
   after 02 gates `pgr_*` behind extension-present and keeps the native fallback (plan 06
   keeps native per-region graphs as the default). Empty/stale states degrade to a
   **200 estimate**, never a crash or 422.

## Verification (every plan)

```bash
make test                                            # unit tests, no DB (must stay green)
make test-integration                                # DB-backed + benchmark comparisons
gofmt -w <files> && go vet ./...                     # lint, since golangci-lint is absent
```

Live routing check (needs the DB up; after 02 the extension is real):

```bash
curl -s "localhost:8080/api/v1/navigation/route?from_lat=9.9333&from_lng=-84.0833&to_lat=9.9433&to_lng=-84.0733" \
  -H "Authorization: Bearer <token>"
```

## Authoritative sources

- Routing engine/flow: `.opencode/skills/road-routing/SKILL.md` (data model, import flow, gotchas).
- API contract: `RIDER_API_GUIDE.md` (route endpoint response shape).
- Import pipeline: `scripts/import-road-network.sh`.