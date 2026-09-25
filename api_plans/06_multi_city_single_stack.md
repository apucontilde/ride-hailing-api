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
  and the importer is region-scoped (`--region`, per-region gate + region-scoped DELETE);
  this plan adds `--datasource <id>` to the importer (Part 3).
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

### Part 3 — Importer `--datasource`

- Extend `scripts/import-road-network.sh --region <id>` with `--datasource <id>` (default "",
  local DB): run the region-scoped pipeline against the target datasource, then upsert the
  region's registry row with that datasource (`routing_regions.datasource`). `routing_
  datasources` rows are created out-of-band (ops provisions a city's PG, then points the
  serialized registry at it).

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
  per-region native graph cache with LRU budget; `RegisteredRegions()`/`Snap` honor
  `RegionRef.Datasource` (plan-05 types).
- `internal/router/router.go:32` — build datasource pools alongside the local `db`.
- `internal/config/config.go` — `ROUTING_MAX_REGIONS_IN_MEMORY`.
- `scripts/import-road-network.sh` — `--datasource` flag; registry upsert sets datasource.
- `internal/repository/*_integration_test.go` — two-datasource dispatch + fail-safe + cache
  eviction cases.