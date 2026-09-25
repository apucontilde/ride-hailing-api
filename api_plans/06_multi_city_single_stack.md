# Plan: Multi-city single-stack — one API, any place in the world, position-loaded

One API stack serves **many separate routing regions** (a city or a small country each).
A rider's/driver's position selects the region (and its datasource/DB) in one look-up;
routing then runs on **that region's native in-memory graph** (microseconds). Trips live
WITHIN one region — a path ACROSS regions is deferred to the intercity stub (plan 07).
Two deployment shapes share this one design: **near** (nearby cities on one cluster, each
with its own DB/datasource) and **far** (cities elsewhere in the world = separate full
deploys). The DB split is what keeps one city's import churn, load or blip from blocking —
or even slowing — any other city.

## Problem

- Plans 04/05 model regions inside ONE database (`region_id` column). Real ops for a
  city/small-country fleet want per-city **isolation and independent sizing**: one city's
  import/load/blip must not block another. That means separate Postgres per city while a
  single API binary position-loads the right one. The converse (SJ + Liberia in one DB) is
  also legitimate and must keep working.
- Current wiring is one handle: `internal/router/router.go:32` builds
  `NewRoutingRepository(db, cfg)` with a single `*sqlx.DB`, and the plan-03 native cache is
  **ONE** in-process graph built at startup. Neither dispatches per-position to a per-region
  datasource or builds per-region graphs.
- pgRouting's per-call cost is O(region edges) (plan 03: ~300 ms on the 183k-edge SJ layer),
  so a **smaller per-datasource region is itself a pgRouting speedup**; native per-region
  graphs are the microsecond hot path.

## Current State (verified)

- `router.go:32` — single `NewRoutingRepository(db, cfg)`; native engine builds ONE graph at
  startup (plan 03); pgRouting binds tables by name (region-scoped via plan 04).
- `routing_regions` + `routing_datasources` (plan 04): registry rows may point at a
  datasource (`datasource_id`/host/port/dbname/`db_user`; password via env, never stored).
  bboxes stay local — position→region candidacy never queries the remote datasource.
- Plan 05's resolver already returns `{regionID, datasource, snapVertexID, snapDistanceM}`
  and the importer is region-scoped (`--region`, per-region gate + region-scoped DELETE;
  plan 05 also lands the `--datasource <id>` flag on the importer). This plan wires the
  **pools/config** and the per-region graph cache (Part 3) against those, and exercises the
  two-datasource import path; it does NOT re-edit the importer script.
- Measured (plan 03): native ≈ 500–2000+ routing rps per node; ~150–200 MB RAM per city
  graph; DB pool pressure comes from auth/rides, not native routing. Use these to size
  Part 3.

## Solution

### Part 1 — position → region → native graph (the fast path)

- `service` resolver unchanged (plan 05). The repo queries the **resolved datasource pool**
  for that region's tables.
- Native routing becomes **per-region, lazy and cached**: `map[regionID]*graph.Graph`. First
  route for a region builds it (region-scoped snapshot from the resolved datasource); later
  routes reuse it. This is the "native after region was determined" pattern, applied at scale.
- **Import-fresh**: a region's new import is picked up by the next request for that region —
  no restart, restoring plan 02's original motivation.
- Eviction: `ROUTING_MAX_REGIONS_IN_MEMORY` (int; 0 = all — default for ≤ a handful of
  cities; set on pods that should hold only a subset). Budget ≈ 150–200 MB per city.
- pgRouting stays an **optional per-region** engine choice behind `ROUTING_ENGINE`; native
  per-region graphs are the default routing path everywhere.
- **Fail-safe**: an unreachable datasource → THAT region's routes degrade to the plan-05
  **estimate** (HTTP 200 `is_estimate:true`), never a 500; other regions are unaffected.

### Part 2 — Near / far deployment shapes (the DB split that prevents blocking)

- **NEAR — one stack, many cities (a cluster).** N datasources: one Postgres per city, or a
  shared host with per-city DBs. Each datasource behind its own pgbouncer pack; pool default
  ~50 (native routing is in-memory, so the pool serves auth/rides and grows with trip
  volume, not routing rps). API nodes are stateless; with all city graphs cached per node,
  RAM = Σ city graphs × nodes — node-group-per-region only when a single city passes
  ~100k+ DAU (plan-03 model). Blast radius per city: one city's PG blip affects its routes
  only. Imports run region-scoped **into that city's datasource**, never touching another
  city's DB — no cross-city TRUNCATE, no cross-city FK ordering, no shared gate.
- **FAR — separate full deploys.** Each far city is its own stack: API group + PG + Redis +
  its city DBs. The only shared piece is the **places/registry metadata** (federated or
  replicated) so an ingress/edge can resolve a pin to the right stack before proxying; users
  are regional. **No cross-stack DB calls**; no shared pool; independent scaling budgets.
  Trips within a city are unaffected by anything overseas.
- Rule that makes both shapes non-blocking: **every resource is per-region** — pool,
  graph, import, registry candidacy. Nothing global except the registry rows and places.

### Part 3 — Datasource-aware wiring (imports + config)

- Plan 05's `import-road-network.sh --region <id> --datasource <id>` (default "", local DB)
  already imports a region into any datasource and upserts the region's registry row with
  that datasource. Plan 05 also creates `routing_datasources` rows out-of-band during ops;
  this plan:
  - wires `routing_datasources` rows into the repo's `map[datasourceID]*sqlx.DB` pools
    (Part 1) so `--datasource` imports are routeable;
  - adds `ROUTING_MAX_REGIONS_IN_MEMORY` so a pod can hold a subset of graphs;
  - exercises a real second-datasource import in the integration suite (verification 3).

### Part 4 — Config + tests

- Config: `ROUTING_MAX_REGIONS_IN_MEMORY` (int, 0 = all). Passwords via env
  (`DATASOURCE_<ID>_PASSWORD`) or `.pgpass` — never stored.
- Integration (`//go:build integration`): **two datasources on one stack** — pins on each
  side resolve to their own pool AND their own native graph; routes stay correct per region;
  stopping the secondary datasource degrades that side to estimate while the primary keeps
  routing; cold-graph eviction under `ROUTING_MAX_REGIONS_IN_MEMORY=1`.
- `go test ./...` green (dispatch/resolution are table-driven against fakes; no DB).

## Verification

1. `go test -count=1 ./...` green (mocks).
2. `make test-integration` green including the two-datasource integration case.
3. Live near-shape: SJ in the local DB + a second synthetic region (`cr-lc`, tiny extract)
   in a second local Postgres (or a second schema exposed as a datasource row) → pin in SJ
   routes the local pool, pin in CR-LC routes the external pool; curl both, assert correct
   region + HTTP 200 polylines; stop the external datasource → CR-LC returns 200
   `is_estimate:true`, SJ unaffected.
4. Memory check: after the two-region setup, RSS shows only the SJ graph; the first CR-LC
   request builds the CR-LC graph; `ROUTING_MAX_REGIONS_IN_MEMORY=1` evicts the cold one.

## Decisions Recorded

- **The registry (bbox + datasource) is the single source of truth** for
  position→region→pool; env/config only overrides passwords and the in-memory graph budget.
  Candidacy never queries a remote datasource.
- **Separate-DB is the default for NEW cities** (isolation, sizing, blast radius);
  same-DB regions stay fully supported (schemas and `--region` import identical within a DB).
- **Native per-region graphs are the routing fast path** ("native after the region is
  determined"). pgRouting is an optional per-region engine choice, never the global default.
- **Everything is per-region** (pool, graph, import, registry candidacy) — that is what
  guarantees one city never blocks another.
- **Intercity is deliberately out of scope here**: no ports, no leg chaining, no
  cross-datasource gateway. See the `07_intercity_future_stub.md` for the deferred seam.

## Files to Modify

- `internal/repository/` — `map[datasourceID]*sqlx.DB` pools + datasource-scoped queries;
  per-region native graph cache with LRU budget; `RegisteredRegions()`/`Snap`/`RouteInRegion`
  honor `RegionRef.Datasource` (plan-05 types).
- `internal/router/router.go:32` — build datasource pools alongside the local `db`.
- `internal/config/config.go` — `ROUTING_MAX_REGIONS_IN_MEMORY`.
- `internal/repository/*_integration_test.go` — two-datasource dispatch + fail-safe + cache
  eviction cases. (The importer `--datasource` flag itself is plan 05's.)

## EXECUTED (2026-09-25)

Implemented on branch `plan/06-multi-city` off `main` (`846c07b`, plans 04 + 05 merged).

### Interface change (the one ripple across the seam)

`service.RegionRouter.RouteInRegion` gains the resolved `datasource`:
`RouteInRegion(regionID, datasource string, fromLat, fromLng, toLat, toLng float64)`.
The datasource travels WITH the region the resolver picked, so the repo never re-reads the
registry to know which pool to query. Both repos and the service fakes were updated; the
plan-05 service tests now assert the `{RegionID, Datasource}` pair reaches the router.

### The pool layer (`internal/repository/datasource.go`, new)

- `DatasourcePools` resolves `routing_datasources.datasource_id` → its own `*sqlx.DB`,
  **lazily** (boot opens nothing remote; a city appears the moment its row does). One pool
  per id, cached; a failed open is remembered for `datasourceRetryDelay` (30 s) so a down
  city costs one dial per window, not one per pin. `connect_timeout` (5 s) bounds the dial.
- Password comes ONLY from `DATASOURCE_<ID>_PASSWORD` (id uppercased, `-`→`_`) or
  `~/.pgpass`; the DSN omits the password parameter entirely when the env var is unset so
  lib/pq's own lookup still works. Never stored in the row.
- `poolFor` is the single dispatch point: `""` → local handle, an id → registry pool, and a
  nil result (unavailable) means "this datasource covers nothing" (fail-safe, not a panic).
- `ErrDatasourceUnavailable` tags ONLY remote failures. The service catches it in `GetRoute`
  and serves the plan-05 straight-line estimate (HTTP 200 `is_estimate`) — a down city
  degrades that one request; local-DB failures stay hard errors (500) by design.

### Per-region graphs + eviction (`internal/repository/navigation_repo.go`)

- `regionGraph(regionID, datasource)` caches `map[regionID]regionGraphEntry{graph,datasource}`.
  The entry remembers its datasource, so re-pointing a region rebuilds instead of routing on
  a stale graph. Successful loads are cached; failures are not (an import or a datasource
  coming back is picked up on the next request, no restart).
- Concurrent first-loads for the SAME region share one build (in-flight `graphLoad` with a
  channel); different regions never wait on each other. LRU order is `graphOrder`;
  `evictRegionsLocked` drops the coldest once `ROUTING_MAX_REGIONS_IN_MEMORY` is exceeded
  (0 = never evict). `CachedRegionIDs()` is introspection for tests/ops.
- `NewNavigationRepo`/`NewPGRoutingRepo` stay local-only; `NewNavigationRepoWithDatasources`/
  `NewPGRoutingRepoWithDatasources` take the pools. The engine factory
  `NewRoutingRepositoryWithPools` is what `router.Setup` calls. Legacy `GetShortestPath` is
  untouched and its unscoped graph is never evicted.

### Config (`internal/config/config.go`)

`ROUTING_MAX_REGIONS_IN_MEMORY` (0 = all, the default). Two extras that fell out of the
pool design: `ROUTING_DATASOURCE_SSLMODE` (defaults to `DB_SSLMODE`) and
`ROUTING_DATASOURCE_MAX_CONNS` (default 10).

### Tests

- `internal/repository/datasource_test.go` (new, no DB): env-name convention, DSN shape
  (password/pgpass/ipv6/defaults/connect_timeout), `poolFor` fail-safe branches, error
  tagging (remote vs local).
- `internal/repository/datasources_integration_test.go` (new, `-tags=integration`): two
  datasources on one stack using a second POOL (same server, separate session) as the
  sanctioned stand-in for a second DB. Covers registry→datasource mapping, lazy/cached/
  fail-safe pools, snap+routing dispatch to the region's own pool (with a poisoned local
  decoy copy of the same region id/vertex ids as the control), pgRouting dispatch,
  unreachable-datasource degradation of only its own region, LRU eviction at budget 1 (incl.
  evict-then-rebuild), datasource-change rebuilds the graph, and "no path" stays an error.
- `internal/config/config_test.go` (new): the env knobs above incl. garbage/negative input.
- `internal/service/regions_test.go`: new `TestGetRouteRoutesInTheResolvedRegionsDatasource`
  and `TestGetRouteDatasourceUnavailableIsEstimate`; existing fakes updated for the new
  signature.
- `internal/repository/regions_integration_test.go`: helpers extracted for reuse; the old
  `remote_datasource_is_not_covered_locally` subtest became
  `unprovisioned_datasource_is_not_covered` (same answer, now because no pool exists).

### Verification performed

- `go vet ./...` clean; `go test -count=1 ./...` green (no DB); `go test -tags=integration
  -count=1 ./...` green against the live docker DB.
- Live boot (single-city default config): `/api/v1/navigation/route` and `/api/v1/estimates/eta`
  still return 2094 m / 190 s with `is_estimate:false` — the default path is byte-compatible
  with plans 04/05.

### Deviations / notes

- **Native `RouteInRegion` does not itself apply `ROUTING_SNAP_RADIUS_M`** (unscoped A* snaps
  to the nearest node in the region graph). That is pre-existing plan-05 behavior: the
  service only calls `RouteInRegion` after BOTH pins passed the radius-gated `Snap`, so
  coverage is still enforced at resolution. The integration test's "no path" case uses a
  disconnected vertex rather than a far pin for this reason.
- The plan's verification #4 (RSS measurement) is exercised as cache-membership assertions
  (`CachedRegionIDs`) rather than process RSS; the RAM figure is operational, not testable.
- Review fixes applied after the first agent pass: `sjPin(n)[0]`-style indexing of a
  multi-value return (invalid Go) replaced with single-value accessors; a missing `model`
  import; a premature cache assertion; a backwards coordinate assertion; and the "no path"
  case switched to a disconnected vertex.