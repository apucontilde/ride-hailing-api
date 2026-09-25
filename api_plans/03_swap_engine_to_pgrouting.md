# Plan: Swap routing engine to pgRouting with a benchmark gate

Replace the in-process native A\* behind `NavigationRepository` with a pgRouting
implementation, keeping the interface frozen and the native path as a first-class fallback.
The swap is gated by performance + correctness — plans 01 and 02 are prerequisites.

## Problem

- `internal/repository/navigation_repo.go` builds an in-process graph on every server start
  (plan 01 frames the cost) and holds it forever (AGENTS.md env fact 5: restarts required on
  import). pgRouting is now installed (plan 02).
- A blind swap would (a) break the mocks in `tests/` and (b) risk a **silent behavior
  regression** with no comparison to the native engine.

## Current State (verified)

- `internal/router/router.go:32` is the ACTUAL wiring site:
  `navigationRepo := repository.NewNavigationRepo(db)` inside `func NewRouter` — NOT
  `cmd/server/main.go`. This is where the engine switch lives.
- `navigation_repo.go` currently: `NewNavigationRepo(db) *NavigationRepo` (also spins up the
  graph from the pgr tables via `db.Query` + `graph.NewGraph`), `GetShortestPath` snaps origin
  & goal through `g.Route` (`navigation_repo.go:116`) and pins polyline endpoints to
  `RouteResult` coords (`navigation_repo.go:93–98`); endpoint-pinning is **unchanged** in the
  new implementation.
- `internal/routing/routing.go` `Graph` is only referenced by `navigation_repo.go` — a clean
  seam for `NativeNavigationRepo`.
- `internal/repository/navigation_test.go` — uses `testutil.MockNavigationRepo` (the mock does
  NOT build a graph). `tests/` boot server via `testutil.NewTestServerE` which passes
  `MockNavigationRepo` + `db=nil` (AGENTS.md env fact 7). Plan 01's benchmarks + these mocks
  are the only consumers of the native engine.
- `internal/routing/routing_test.go:82` — `Route(10,10,20,20)` sample that plan 01's clamp
  protects.
- `Makefile:17` — `test-integration: go test -tags=integration ./tests/...`. **Bug**: the
  tagged integration test files under `internal/...` (older plan introduced `-tags
  integration` and put tests in `internal/repository`) would never run; must become
  `./...`. Verified: no `//go:build integration` files exist yet under `internal/` today; the
  DB-backed tests added by THIS plan are the first — so if the tag plumbing is not
  introduced correctly now it silently ships unreachable tests.

## Solution

### Part 1 — Repo split, same interface

- `internal/repository/navigation_repo.go` → rename type to `NativeNavigationRepo`, keep
  everything; add `var _ NavigationRepository = (*NativeNavigationRepo)(nil)` (already
  asserted in the file — update the name). `GetShortestPath` behaviour forever frozen:
  graph via `graph.NewGraph`, snap + A\* (plan 01), polyline endpoints pinned to `RouteResult`.
- New `internal/repository/pgrouting_repo.go`: `PGRoutingRepo` implements the SAME
  `NavigationRepository` (in `internal/repository/navigation_repo.go`'s interface). It takes
  a `*sql.DB` and `db.Query` per call — **no in-process graph, no cache in scope** (plan 04
  adds region scoping; the deferred intercity stub (plan 07) documents the optional-interface pattern).
- Factory: `internal/router/router.go:32` becomes
  `navigationRepo := repository.NewRoutingRepository(db, cfg)` returning
  `NavigationRepository`:
  - `cfg.RoutingEngine` (`ROUTING_ENGINE` env, new) — `native` (default) vs `pgrouting`.
  - `pgrouting` on a DB without the extension (fresh old-image volume, plan 02 degraded
    state) must `log.Println("fallback")` + return the native repo, never crash boot.
  - Assert on `:= repository.NewRoutingRepository(...)` that it is not `nil`.

### Part 2 — SQL contract (pgRouting correctness details)

Preconditions (plan 02): real extension, 8-column `pgr_dijkstra` output (since 3.5.0:
`seq,path_seq,start_vid,end_vid,node,edge,cost,agg_cost`). Statements in `PGRoutingRepo`:

1. **Snap** (both endpoints) — KNN on the GIST index, **lng first** param order. The
   `ORDER BY the_geom <-> ...` term is index-assisted ordering ONLY: on a 4326 geometry
   column `<->` returns **Cartesian degrees**, NOT meters. Never feed that value into a
   distance threshold. Compute true meters with `ST_Distance(..., ::geography)` on the
   single returned row:
   ```sql
   SELECT id,
          ST_Distance(
            the_geom::geography,
            ST_SetSRID(ST_MakePoint($lng, $lat), 4326)::geography
          ) AS distance_m
   FROM road_network_vertices_pgr
   ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint($lng, $lat), 4326)
   LIMIT 1;
   ```
   One index-assisted scan, one geodesic meter value. That `distance_m` is what a
   `ROUTING_SNAP_RADIUS_M: > radius → treat as "not covered"` threshold consumes.
2. **Short path** (`start_vid == end_vid`) — pgRouting returns **empty** for a same-node
   trip (no expanding search). Keep the native repo's current semantics: a 0-length single
   point + 0 m / 0 s. Return that WITHOUT calling `pgr_dijkstra` (both repos share the same
   `handler`-visible result via `service` conversion).
3. **Dashboard distance**: `pgr_dijkstra(edges_sql, start_vid, end_vid, FALSE)` returning
   the row set; `agg_cost` is the **cumulative** cost to each node — take the row with `seq =
   max` for the total. `cost`/`agg_cost` are what was STORED (meters — plan 04 keeps the
   meters convention; do NOT convert). The edges table (011) exposes `id, source, target,
   cost` ONLY — no `reverse_cost`, no geometry, no highway class. With `directed = FALSE`
   and no `reverse_cost` row, pgRouting uses `cost` in both directions (the native graph is
   also undirected — identical semantics). Do NOT write an `edges_sql` that references
   `reverse_cost`; it does not exist and the query will fail.
4. **Nested `edges_sql` interpolated by Go**: `pgr_dijkstra` treats its first arg as a
   literal SQL string; binding params inside does NOT work. Build it via
   `quote_literal($1)` (pg lib helper) of the *static* string
   `"SELECT id, source, target, cost FROM road_network_edges_pgr"` — never concatenate user
   input; the SQL is constant, only placeholder values are bound.
5. **Start/end not present in the edge set or missing pins**: `pgr_dijkstra` returns an
   EMPTY row set (it does not error for a vid absent from the edges' sources/targets).
   Treat empty-as-not-error → signal "no route" so `service` downgrades to the
   estimate/straight-line path (plan 05) instead of surfacing a 500.

### Part 3 — Tests, tools, and the decision gate

DB-backed (integration-tagged) tests + benchmarks:

- `internal/repository/pgrouting_repo_integration_test.go` (`//go:build integration`): seed a
  tiny graph in the 011 tables, assert `GetShortestPath` output `in` matches, and
  cross-check each of: same-vid, one-hop, multi-hop, no-route-between-components (empty
  `pgr_dijkstra` → defined error, NOT a silent straight line), plus `route_no_extension`
  degraded state (skip if extension absent). NOTE: KNN always returns SOME vertex (nearest),
  so "uncovered pin" is expressed as `distance_m > ROUTING_SNAP_RADIUS_M`, not as a null
  snap.
- `tests/` smoke unchanged: `NewTestServerE` still injects `MockNavigationRepo`.
- `benchmark` Makefile: `bench-integration` = `go test -tags=integration -bench=. -count=1
  ./internal/...` (`.PHONY` too).
- **Fix `test-integration` coverage bug**: `make test-integration` → `go test -tags=integration
  ./...` so `internal/repository/*_integration_test.go` actually executes.
- **Decision gate (documented, not hard-coded)**: keep `ROUTING_ENGINE=native` default. Run
  `BenchmarkRoute` (plan 01 baseline is already recorded there) vs `BenchmarkRoutePGRouting`
  — the SAME `benchmarkGridGraph(400)` workset loaded into the 011 tables (`make
  import-osm-force OSM_INPUT=<grid.osm>` or a one-off seed), NOT the SJ import (different
  topology makes the comparison meaningless). Flip default to `pgrouting` ONLY when (a)
  SJ real-route correctness matches native within tolerance and (b) `pgr_dijkstra` P50 ≤
  ~2× the recorded native `Route/hop`+`corner` numbers. If the gate fails, pgRouting stays
  behind the flag until fixed; native remains production.

  > **GATE RESULT (executed, 2026-09-25) — NOT MET: keep `native` default.**
  >
  > Same-workset numbers (400×400 grid temp tables, `-benchtime=5x`, this harness; native
  > baseline re-run alongside, plan-01 numbers in parentheses):
  >
  > | bench | native | pgRouting | verdict |
  > | --- | --- | --- | --- |
  > | `Route/corner` | ~356 ms | ~393 ms | ≈1.1× → PASS (≤2×) |
  > | `Route/hop` | ~10.6 µs | ~298 ms | ≈28,000× → **FAIL** |
  >
  > Correctness parity (a): REAL SJ pins, native vs pgrouting — the SAME two query pairs
  > return the EXACT same polyline length + total distance on both engines
  > (2094 m / 42 pts and 5334 m / 105 pts; `from==to` → 0 m / 0 s single point). So
  > correctness holds and `corner` passes; the gate fails on **`hop`**, the common
  > short-trip case. Root cause below (gate-failure analysis); policy consequence: the
  > hop criterion is **physically unreachable** for any pgRouting formulation — the gate
  > must be recalibrated to a route-length-aware hybrid, not to "flip the default".

  > **GATE-FAILURE ANALYSIS (executed 2026-09-25, live SJ data)** — where the time goes
  > and what can/cannot fix it:
  >
  > 1. **The ~300 ms is pgRouting's C graph-build, not SQL.** On the live SJ network
  >    (183,371 edges / 152,665 vertices) `EXPLAIN (ANALYZE, BUFFERS)` for the edges_sql
  >    alone is **8.6 ms**; `pgr_dijkstra` over the full graph measures **261–315 ms even
  >    for a 5-row trip** (dijkstra itself costs µs; the SPI fetch is 8.6 ms; the rest is
  >    pgRouting allocating/filling its adjacency arrays per call).
  > 2. **Contraction is the textbook lever and it works for graph size, up to a hard
  >    floor.** `pgr_contraction` of SJ (`methods {1,2}`, 2 cycles, `directed=false`,
  >    `reverse_cost=cost`) is cheap (0.8 s) and yields 18,985 shortcut edges (10.7×
  >    smaller). Routing over the contracted edge set drops the per-call cost to
  >    **20–27 ms**, confirming the cost scales with edge count. But that floor is still a
  >    DB round-trip + graph load ≈ **1000–2500× native's 10.6 µs hop**: the gate's hop bar
  >    (≤~2× native) is **unreachable by design** for any pgRouting engine.
  > 3. **Correct contracted routing is blocked on 4.0.1 specifics**, so a contracted engine
  >    cannot ship yet: pgRouting 4.0.1 emits **negative shortcut edge ids** (sign-collides
  >    with pgr's own reversed-edge id convention), has NO `pgr_contract_expand`, and — the
  >    blocker — the contracted output is **not a faithful routable core**: 83 % of original
  >    vertices (127,094) are stranded (no contracted edge, not in any `'v'` group; our real
  >    snap 38636 is reachable to only 2 vertices), and routing between two *known-live*
  >    contracted vertices returns **0 rows**. All union recipes (shortcuts only / +
  >    both-endpoints-live / + 600 m endpoint neighborhoods) return 0 rows for real pins.
  >    A faithful undirected contracted core needs careful validation (component count == 1,
  >    endpoint-neighborhood in, micro-path expand out) — that is CH machinery,
  >    **deferred-intercity scope (plan 07 stub)**, not a gate-flip.
  > 4. **Recalibrated policy (records the verdict instead of deferring it):** drop the
  >    "flip the single default" framing. Routing is route-length-aware:
  >    - `native` stays the engine for city hops/typical trips (`µs` per call; cached
  >      in-process SJ graph). This is the ride-hailing hot path.
  >    - `ROUTING_ENGINE=pgrouting` is the correct engine for **long-haul / future intercity**
  >      legs (deferred to the plan-07 stub): a ~300 ms fixed cost is <1 % of a 20-minute
  >      intercity trip, and pgRouting is import-fresh (no restart to reload a graph, plan
  >      02's motivation) and region-scoped (plan 04). It already passes the correctness +
  >      corner bars.
  >    - The hybrid switch (`~X km` threshold) is deferred with intercity (plan 07); the
  >      benchmarks above give it `corner ≈ 393 ms` and `hop ≈ 298 ms` fixed-cost numbers
  >      to use.

## Verification

1. `go test -count=1 ./...` green (mocks, no DB).
2. With DB up + real pgRouting: `make test-integration` runs `internal/...` tagged tests
   (assert file list in output).
3. `ROUTING_ENGINE=pgrouting make run` + curl the route endpoint between two SJ coords →
   HTTP 200, `total_distance_m` ≈ native (within tolerance) and polyline not a straight line.
4. `ROUTING_ENGINE=pgrouting` + curl with `from == to` coords → 0 m / 0 s single point.
5. Run plan 01 + new pgRouting benchmarks; record gate result in this file.

> **EXECUTED (2026-09-25).** All five items pass; gate result = NOT MET (see Decision gate
> block above — `native` stays the default).
> - `go test -count=1 ./...` green. `make test-integration` (now `./...`) green, and its
>   output lists `internal/repository` — confirming the previously-unreachable `-tags
>   integration` tests under `internal/` now run (`TestPGRoutingRepoGetShortestPath`,
>   `TestPGRoutingRepoSnapRadius`, `TestNewRoutingRepository`).
> - Integration tests seed TEMP tables named like the real ones on a single-connection
>   handle, so the static edges_sql and snap/route queries resolve to the tiny fixture — the
>   real SJ import is never touched. Covers same-vid, one-hop, multi-hop (chain 1-2-3-4, exact
>   300 m total), no-route-across-components, empty-dijkstra (lone vertex → `ErrNoRoute`),
>   snap-radius covered/uncovered, and factory selection (native default / bogus → native /
>   pgrouting-when-extension-present).
> - Live engine swap (item 3/4): `ROUTING_ENGINE=pgrouting` server vs native server on two real
>   SJ pin pairs → identical distance/points (2094 m/42 and 5334 m/105); `from==to` → 0 m/0 s.
> - Two implementation notes for whoever revisits: pgRouting binds the edges_sql as a text
>   parameter (`$1`) — no `quote_literal` needed and no interpolation — and `pq.CopyIn` for the
>   benchmark seed MUST run inside a transaction (`COPY is only allowed inside a transaction`).

## Alternatives & Future

- If correctness parity fails on real data, investigate (a) `reverse_cost`/one-way flags from
  import, (b) cost units, (c) KNN snap radius — before abandoning the swap.
- After plan 04, pgRouting's bottleneck shifts from engine to *import-synchronization*
  (restart-free refresh). Plan 03 deliberately does NOT add graph-cache invalidation.

## Files to Modify

- `internal/repository/navigation_repo.go` — rename to `NativeNavigationRepo`, update
  interface assertion.
- `internal/repository/pgrouting_repo.go` *(new)* — `PGRoutingRepo` + factory.
- `internal/router/router.go:32` — `NewRoutingRepository(db, cfg)`.
- `internal/config/config.go` — add `RoutingEngine` / `ROUTING_ENGINE` (whitelist
  `native`|`pgrouting`, default `native`).
- `internal/repository/pgrouting_repo_integration_test.go` *(new)* — tagged DB tests.
- `internal/repository/pgrouting_repo_benchmark_test.go` *(new, integration-tagged)* —
  `BenchmarkRoutePGRouting` over a 400×400 temp-table grid seeded with `pq.CopyIn` (seeding
  must run inside a transaction). Pairwise-comparable to `internal/routing/benchmark_test.go`'s
  native `BenchmarkRoute` (same grid constants duplicated there).
- `Makefile` — `bench-integration` target; **`test-integration` → `./...`**.