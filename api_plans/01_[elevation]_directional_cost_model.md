---
tag: elevation
depends_on: []
status: open
---

# Stage 01 — Directional elevation cost model in `internal/routing`

**Goal.** Teach the native A\* engine to minimize `meters + w·ascent` instead of `meters`,
with synthetic elevations supplied by hand. No schema, no repository, no config, no DEM — pure
Go in `internal/routing`, fully unit-tested. When this stage lands, the engine can already
prefer "keep going down / contour the hill" over the shortest-by-meters path, and the default
behaviour is **byte-identical to today**.

## Context

**Read (nothing else):**

- `internal/routing/routing.go` — the whole file (339 lines). Everything below is a change to it.
- `internal/routing/routing_test.go` — the **11** existing tests (lines 34, 48, 62, 76, 84, 98,
  106, 133, 161, 184, 199), all of which MUST stay green and UNMODIFIED. Seven of them
  exercise route cost; the four `TestNearestNodeGrid*` cases exercise the snap index and are
  easy to forget when counting. They are the regression proof that the default path did not
  change.
- `internal/routing/benchmark_test.go` — `benchmarkGrid`, `benchmarkGridGraph`, `benchGridN`,
  `benchOriginLat/Lng/Step`. Extend, do not rewrite.

**Write:**

- `internal/routing/routing.go` (edited)
- `internal/routing/routing_test.go` (append only — never edit the existing 11)
- `internal/routing/benchmark_test.go` (append)
- `internal/routing/elevation.go` *(new — the cost model, weights, proof comments)*

**Do NOT touch:** `internal/repository/*`, `internal/service/*`, `internal/config/*`, any
migration, `scripts/*`, the Flutter apps. If this stage seems to need one of those, it is
overreaching — stage 02 exists for that.

**Needs a DB?** No.

## Problem

`Graph.Route` (`routing.go:238-286`) accumulates `tent := gScore[cur.node] + e.cost`, and every
`e.cost` is road length in meters. The search therefore minimizes distance and is blind to
grade. `NewGraph` (`routing.go:67-79`) symmetrizes every edge — the same `cost` in both
directions — which is only valid while cost is a property of the segment rather than of the
direction of travel.

## Current State (verified 2026-09-25)

- `Node{ID, Lat, Lng}` (`routing.go:17-20`); `Edge{Source, Target, Cost}` with
  `Cost` = **meters** (`routing.go:26-30`); `adjEdge{to, cost}` (`routing.go:32-35`).
- `NewGraph` drops self-loops, unknown endpoints and `Cost <= 0`, then adds **both**
  directions with the identical cost (`routing.go:74-78`).
- `Route` returns `(path []int64, totalCost float64, err)`; `totalCost` is the accumulated
  cost, which today **is** the distance in meters (`routing.go:268`).
- Heuristic: `heur := g.haversineTo(e.to, goal.ID)` — plain haversine (`routing.go:279,288-292`),
  valid only because cost == distance.
- `reconstruct` (`routing.go:294-308`) walks `cameFrom` and returns the reversed node slice
  plus the goal's `gScore`.
- The 7 tests in `routing_test.go` assert exact paths and exact integer costs
  (e.g. `cost != 11132` at `:43`, `cost != 22264` at `:56` and `:70`) over `testGraph()`,
  whose nodes have no elevation. They pass only if the zero-value weight model reproduces
  distance-only cost.
- `Graph` is referenced by exactly one production caller: `NativeNavigationRepo.GetShortestPath`
  (`internal/repository/navigation_repo.go:126`, `g.Route(...)` → `results[last].AggCost = totalCost`).
  Changing `Route`'s *meaning* is therefore contained to one call site; changing its
  *signature* would break `benchmark_test.go` (3 call sites) — do not.

## Solution

### Part 1 — The cost model (`internal/routing/elevation.go`, new)

> ⚠ **Corrected after review (`[elevation]_review.md` §2.1, §2.2, §2.3, §3.3, §3.5, §4.1–4.3).**
> `Validate` now rejects **negative** weights; the cost identity below is stated with the
> deadband and clamp; `MaxGrade`'s claim is narrowed to what it actually does; and the default
> weight set is explicitly **provisional — pre-falsified measurements say it is too weak to
> change the median trip**. Read those sections before implementing.

```go
// CostWeights parameterizes the elevation cost model. The ZERO VALUE is
// distance-only routing — bit-for-bit the pre-elevation engine — so callers
// that never touch elevation cannot change behaviour by accident.
type CostWeights struct {
    // AscentW is the search-cost surcharge, in pseudo-meters, charged per
    // meter of climb. MUST be >= 0. 0 = climbing is free.
    AscentW float64
    // DescentW is the same for descending, normally much smaller than
    // AscentW. This is the knob that makes "keep going down" worth choosing
    // over "go up and over". MUST be >= 0 and DescentW*MaxGrade < 1.
    DescentW float64
    // MaxGrade clamps |dz/meters| **per edge**, so no single DEM artifact can
    // dominate a route. Typical roads are <= 0.15. It bounds the influence of
    // ONE edge, not the total climb of a path: a path of n steep edges still
    // accumulates n * meters * (1 + AscentW*MaxGrade). There is no ascent
    // budget in the model; stage 04's p99 distance ceiling is the only guard.
    MaxGrade float64
    // DeadbandM zeroes elevation deltas whose magnitude is <= this, in
    // meters. SRTM-class DEMs carry several meters of vertical error, and
    // this network has a 64 m median edge length (see README): without a
    // deadband, DEM noise reads as grade and reshuffles every flat route.
    // Stage 03's diagnostics say 3 m is far too small for this DEM — the
    // default is PROVISIONAL and stage 04 owns the real number.
    DeadbandM float64
}
```

Directional cost of one edge, traversed `u → v`:

```go
func weightedEdgeCost(meters, dz float64, w CostWeights) float64 {
    dz = deadband(dz, w.DeadbandM)
    g := dz / meters
    g = clamp(g, -w.MaxGrade, w.MaxGrade)
    if g > 0 {
        return meters * (1 + w.AscentW*g)   // == meters + w.AscentW*dz
    }
    return meters * (1 + w.DescentW*g)
}
```

`meters > 0` always (`NewGraph` drops `Cost <= 0`), so `dz/meters` cannot divide by zero.

**Why this is "minimize ascent", not a heuristic hand-wave.** With `DeadbandM = 0` and no clamp
in play, an uphill edge is `cost = meters·(1 + w·Δz/meters) = meters + w·Δz`, so summed over a
path `cost(path) = meters(path) + w·total_ascent`, and total ascent is **additive over edges** —
so "minimize weighted ascent" is an ordinary single-objective shortest-path problem, with no
Pareto front and no state beyond the node.

> **The shipped model is NOT that identity.** With the deadband and the clamp active, the real
> per-edge cost is `meters·(1 + w·g')` where `g' = clamp(deadband(Δz)/meters, ±MaxGrade)`, and
> `g'·meters ≠ Δz`. Measured on the live SJ network with `DeadbandM = 3`, **the deadband zeroes
> 59.5 % of edges and the clamp binds on 5.0 %** (`[elevation]_review.md` §4.1) — so the identity is false
> for roughly two-thirds of edges and the cost is *not* proportional to total ascent. Everything
> downstream (stage 04's ascent-ratio thresholds in particular) must reason about
> `AscentM_flat / AscentM_elev` as a **proxy**, not as the optimized quantity. `Path.AscentM` is
> raw, so the ratio is well-defined and comparable across weight sets — but it is not
> `Cost_flat / Cost_elev`.

### Part 2 — Admissibility and consistency (the obligation this stage exists to discharge)

If `DescentW > 0` and the grade is negative, `cost < meters`. The existing heuristic is plain
haversine, which lower-bounds **distance**, so it stops being a lower bound on the weighted
cost. A\* would then return suboptimal paths and the stage would be a silent correctness
regression. Fix: scale the heuristic by a provable factor.

Let `D := 1 - DescentW·MaxGrade`. Since `dz/meters >= -MaxGrade` after clamping, for every edge

```
cost = meters·(1 + w·g) >= meters·(1 + DescentW·(-MaxGrade)) = D·meters
```

- **Admissible.** For any path `P` from `n` to the goal, `cost(P) >= D·len(P)`, and a road path
  is never shorter than the straight line, so `len(P) >= haversine(n, goal)`. Hence
  `h(n) = D·haversine(n, goal) <= cost(P)`. ✓
- **Consistent.** For an edge `(u,v)`, `haversine(u, goal) <= meters(u,v) + haversine(v, goal)`
  (triangle inequality), so
  `h(u) = D·haversine(u,goal) <= D·meters(u,v) + h(v) <= cost(u,v) + h(v)`. ✓
- **Non-negative costs.** `D > 0` ⟹ every `cost >= D·meters > 0`, so A\* terminates and the
  `closed` set in `Route` is sound (each node expands at most once).

Therefore: **require `D > 0`** — i.e. `DescentW·MaxGrade < 1`. Expose it as

```go
// heuristicScale is the lower-bound factor D. Zero/negative means the weight
// combination is invalid and MUST be rejected by Validate.
func (w CostWeights) heuristicScale() float64 { return 1 - w.DescentW*w.MaxGrade }

// Validate reports whether the weights admit a correct A* search. It MUST
// reject:
//   - AscentW < 0 or DescentW < 0. THE SIGN CHECK IS NOT OPTIONAL: the Part 2
//     proof needs the lower bound on BOTH branches, and a negative weight
//     silently inverts it. With DescentW = -0.3, MaxGrade = 0.15 the scale
//     becomes 1.045, so the heuristic claims cost >= 1.045 * haversine while a
//     descent edge costs LESS than meters — inadmissible AND inconsistent, and
//     A* then returns silently suboptimal paths. With AscentW < 0 the uphill
//     branch breaks the same way. Both are reachable from env config, so this
//     function is the only gate and it must look at the sign of both.
//   - DescentW*MaxGrade >= 1 (D <= 0: costs collapse to zero, the search
//     degenerates and the closed-set argument fails).
//   - MaxGrade < 0.
//   - any of the four being NaN or +/-Inf.
func (w CostWeights) Validate() error
```

`Validate` returning an error is a **caller** concern — stage 02 is where the config layer logs
it and falls back to the zero weights. Do not panic and do not silently clamp inside `Validate`;
return the error. `RouteWithWeights` calls `Validate` itself and treats an invalid set as the
zero weights (belt and braces, never a crash) — so a misconfigured production deploy gets a
flat router plus a log line, never a wrong router.

### Part 2b — What the model does NOT do

- **`MaxGrade` bounds one edge, not a route.** A path of *n* edges at the cap still pays
  `n · meters · (1 + AscentW·MaxGrade)`. There is **no ascent budget, no detour cap and no
  penalty ceiling** anywhere in the model, so a route can be arbitrarily worse on the weighted
  objective and still win. Stage 04's p99 distance ceiling is the only guard, and it is a
  *measurement*, not a mechanism. If the gates show a pathological detour, the fix is a
  bounded second pass (`Meters ≤ (1+cap)·flatMeters`), not a smaller weight.
- **The heuristic weakens with the discount.** `D = 0.955` at the provisional defaults;
  `D = 0.7` is noticeably slower. Recorded, not hidden.
- **The provisional defaults are too weak to move the median trip** — see the banner at the top
  of this file and stage 04's pre-falsified numbers. Stage 01 ships the *mechanism*; stage 04
  owns the constants, and the constants are the hard part.

### Part 3 — Struct and API changes

```go
type Node struct {
    ID   int64
    Lat  float64
    Lng  float64
    EleM float64 // meters above sea level; 0 when unknown. Additive field —
                 // every existing construction site uses keyed literals
                 // (routing_test.go:19-24, benchmark_test.go:28-32) and stays valid.
}

// Edge is UNCHANGED. Cost stays "segment length in meters".
```

**`NewGraph` is UNCHANGED.** This is the important simplification: the graph still symmetrizes
each edge, because the *meters* are direction-independent and the directional search cost is
derived from the node elevations at traversal time. Nothing about adjacency construction,
the grid index, `scanNearest`/`gridNearest`, or `NodeByID` moves.

New result type + methods:

```go
// Path is a weighted-search result. Meters is the true road length (what the
// API must report); Cost is the elevation-weighted search cost (what the
// search minimized); AscentM/DescentM are pre-deadband real metres.
type Path struct {
    Nodes    []int64
    Meters   float64
    Cost     float64
    AscentM  float64
    DescentM float64
}

// RouteWithWeights runs A* under the given weights.
func (g *Graph) RouteWithWeights(fromLat, fromLng, toLat, toLng float64, w CostWeights) (*Path, error)

// Route is unchanged in SIGNATURE and MEANING: shortest path by distance,
// returning (nodeIDs, distance in meters, error). It is now a thin wrapper:
//   p, err := g.RouteWithWeights(..., CostWeights{})
//   return p.Nodes, p.Meters, err
func (g *Graph) Route(fromLat, fromLng, toLat, toLng float64) ([]int64, float64, error)
```

`Route`'s second return value stays **meters**. Today cost == meters, so this is not a change
in value — it is a change in *why* the value is correct, and it is what lets stage 02 turn
elevation on without touching `total_distance_m`. This is invariant #1 in the series README;
do not "optimize" it away.

Preserve the existing edge cases exactly, in `RouteWithWeights` (the wrapper inherits them):

- `NearestNode` miss on either endpoint → `nil, ErrNoRoute` (`routing.go:239-246`).
- `start.ID == goal.ID` → `Nodes = []int64{start.ID}`, `Meters = 0`, no error
  (`routing.go:248-250`).

### Part 4 — The search loop

Add `metersScore map[int64]float64` next to `gScore`, and one branch-local add where the
relaxation improves:

```go
tent := gScore[cur.node] + c          // c = weightedEdgeCost(...)
if prev, ok := gScore[e.to]; !ok || tent < prev {
    cameFrom[e.to] = cur.node
    gScore[e.to] = tent
    metersScore[e.to] = metersScore[cur.node] + e.cost
    heur := w.heuristicScale() * g.haversineTo(e.to, goal.ID)
    heap.Push(open, &item{node: e.to, g: tent, f: tent + heur})
}
```

Keeping `metersScore` rather than recomputing the path length afterwards is deliberate: the
reported metres are then the sum over **the same relaxation sequence that produced the cost**,
so a future change to the cost function cannot make them disagree.

**Two hot-loop notes, both cheap, both required:**

1. Compute the directional cost from **already-loaded node values**. The loop already does
   `g.haversineTo(e.to, goal.ID)` → `g.nodes[from]`, `g.nodes[to]`. Hoist
   `from := g.nodes[cur.node]` **above** the `for _, e := range g.adj[cur.node]` loop and read
   `to := g.nodes[e.to]` once, then use `from.EleM`/`to.EleM` for the delta and the same pair
   for the heuristic. Two `map` lookups per relaxation total instead of four. Do NOT add a
   second `haversineTo`-style helper that re-loads them.
2. The extra work per relaxation is ~1 map-free delta, 1 divide, 2 compares, 1 multiply, 1
   clamp compare. No new allocation. `make benchmark` must show `BenchmarkRoute/{corner,hop}`
   within noise of the plan-01/plan-03 numbers when called through `Route` (zero weights), and
   `BenchmarkRouteElevated` reports the weighted path's cost.

**Do not refactor `Graph` to dense node indices in this stage.** It would be faster, but it
touches `gScore`, `closed`, `cameFrom`, `NodeByID` and `reconstruct` at once — a large diff
that makes the correctness argument above unreviewable. Recorded as a stage-04 follow-up,
gated on a measured need.

### Part 5 — Metrics reconstruction

After the goal is popped, walk the reconstructed `Nodes` (the existing `reconstruct` loop) and
accumulate:

- `Meters += metersScore[goal]` (the map is authoritative; the walk is for ascent/descent).
- For each consecutive pair `(u,v)`: `dz := g.nodes[v].EleM - g.nodes[u].EleM`.
  `AscentM += max(0, dz)`, `DescentM += max(0, -dz)`.

Report `AscentM`/`DescentM` as **raw** metres (no deadband, no clamp) — they are telemetry for
stage 04's acceptance suite and a driver-facing number, not the optimized quantity. Say so in
the doc comment so nobody later assumes `AscentM` is what the search minimized (it is
`w`-weighted and deadbanded; `AscentM` is not).

## Tests to add (append to `routing_test.go`; the existing 11 stay untouched)

- `TestRouteZeroWeightsEqualsDistance` — on `testGraph()` (all elevations 0),
  `RouteWithWeights(..., CostWeights{})` must return the same `Nodes` **and** the same
  `Meters` as the existing integer-cost assertions. This is the "default is off" proof.
- `TestAscentAvoidsRidge` — **the test that encodes the objective.** Two A→B paths of
  *comparable* geometry: `P_short` = 500 m climbing 20 m; `P_flat` = 520 m flat. With
  `AscentW > 0` the flat path must win; with the zero weights the short climbing path must
  win. Assert both directions of the switch, and assert `Meters` of the chosen path is
  520 m (never 500) — i.e. the reported distance tracks the *meters actually walked*.
- `TestDescentCreditPrefersContinuingDown` — a symmetric pair where descending is preferred
  only when `DescentW > 0`; with `DescentW = 0` the flat route wins. Pins the meaning of
  `DescentW` as a knob, not a constant.
- `TestDeadbandSuppressesNoise` — a flat 20 m edge with 1 m of bogus elevation on one endpoint
  must cost 20 m (not 21) with `DeadbandM = 3`; and 5 m of real climb on the same edge must
  still cost more than 20 m.
- `TestGradeCap` — a 100 m edge with 50 m of climb (`grade` 0.5) is priced at
  `100·(1 + AscentW·MaxGrade)`, not at `grade` 0.5.
- `TestWeightsValidate` — `DescentW·MaxGrade >= 1` is rejected; `MaxGrade < 0` rejected; the
  default is valid; `RouteWithWeights` with invalid weights behaves exactly like zero weights
  (no panic, no error).
- `TestHeuristicIsAdmissible` — property test over `grid3x3()` and a seeded random 6×6 graph
  with random elevations: for every `(n, goal)` pair assert
  `D·haversine(n, goal) <= cost of an actual optimal path n→goal`. This is the mechanical
  check of the Part 2 proof; a failure means the weights or the scale factor are wrong.
- `TestWeightedMatchesBruteForceDijkstra` — the decisive test, and the same
  reference-implementation trick plan 01 used for the grid index (`scanNearest` vs
  `gridNearest`, `routing_test.go:133-182`). Write an unexported, obviously-correct
  O(V²) Dijkstra over the same `weightedEdgeCost`, run it on ~20 seeded random graphs with
  random elevations and non-zero weights, and assert identical `Cost` (and identical
  `Meters`) from `RouteWithWeights` for every snapped OD pair. Same trick, same precedent.
- `TestPathMetricsSignConvention` — `AscentM`/`DescentM` are `>= 0`, sum to
  `|z(last) - z(first)| + 2·(wiggle)`, and are raw (a 1 m delta with `DeadbandM = 3` still
  reports 1 m of ascent while costing 0).
- `TestWeightsRejectNegative` — **one sub-case per rejected field** (added after
  `[elevation]_review.md` §2.1 found this a live correctness bug): `AscentW < 0`, `DescentW < 0`,
  `MaxGrade < 0`, and one `NaN` / `+Inf` per field. Each must produce an error from `Validate`
  **and** flat-routing behaviour from `RouteWithWeights`. The `DescentW < 0` case is the
  important one: it makes `heuristicScale() > 1`, which would let A\* return a suboptimal path
  with no error anywhere.

## Benchmark to add (`benchmark_test.go`)

- `benchmarkGridElevated(n int)` — same lattice as `benchmarkGrid`, with
  `EleM = 120*math.Sin(i*step) + 60*math.Cos(j*step)` so every edge has a non-zero,
  non-degenerate delta. Reuse `benchOriginLat/Lng/Step` and `benchGridN`.
- `BenchmarkRouteElevated` with sub-benchmarks `corner` and `hop`, mirroring `BenchmarkRoute`
  but calling `RouteWithWeights` with a documented weight set (e.g. `AscentW 1.5`,
  `DescentW 0.3`, `MaxGrade 0.15`, `DeadbandM 3`). `b.ReportAllocs()` + `b.SetBytes(2)` as in
  the existing file. This is a **measurement, not a gate** — record the numbers in this file
  under a `MEASURED` block; stage 04 uses them.

## Verification

1. `go test -count=1 ./internal/routing/` green — **including the 11 pre-existing tests
   unmodified**. This is the single most important check in the stage.
2. `make test` green (whole module; no DB needed).
3. `gofmt -w internal/routing/*.go && go vet ./internal/routing/`.
4. `make benchmark` — record `BenchmarkRoute/{corner,hop}` (via the zero-weight `Route`) and
   `BenchmarkRouteElevated/{corner,hop}` in the `MEASURED` block below.
   **Expect a small regression, and do not claim otherwise.** The `metersScore` map is
   allocated and written on *every* improving relaxation, including the zero-weight path, and
   `Path` replaces the bare `[]int64` return — so the zero-weight route is
   *behaviourally* identical (same path, same meters, per the existing tests) but not
   *performanceally* identical. `[elevation]_review.md` §4.4 records the current baseline on this machine
   as `Route/hop 1.50 µs`, `Route/corner 326 ms`, `NearestNodeGrid 169 ns`, `NewGraph 150 ms`;
   plan 01's recorded numbers (`~1.4 µs` / `~267 ms`) were taken on different hardware and are
   **not** a valid comparison baseline. Measure before-and-after on the same machine, and if
   the hop regression is more than ~20 %, move `metersScore` to a slice indexed by a dense node
   ordinal (the stage-04 follow-up) rather than declaring it noise.
5. `git diff --stat internal/routing/routing_test.go` must show **additions only**. If any
   existing test line changed, the default path moved — revert and re-derive.

## MEASURED

_(filled in by the executor; plan-01/03 baseline for reference: `Route/hop` ~10.6 µs,
`Route/corner` ~356 ms, `NearestNodeGrid` 160 ns, `NewGraph` ~120 ms — same `benchmarkGridGraph(400)`.)_

## Decisions Recorded

- **Query-time cost, not build-time cost.** The weighted cost is derived per relaxation from
  node elevations rather than baked into `adjEdge` at `NewGraph` time. Consequence: tuning a
  weight does **not** require a graph rebuild, which matters because AGENTS.md env fact 5 says
  the native graph is cached in-process and data changes need a restart. Cost: ~10 flops per
  relaxation. If a future measurement shows that matters, precomputing into `adjEdge` is a
  contained follow-up (it needs the weights at build time, hence a cache-invalidation story).
- **Two separate numbers, always.** `Path.Meters` (reported) and `Path.Cost` (optimized).
  Never let one be written where the other is read; `GetShortestPath` must take `Meters`
  (stage 02, and invariant #1 in the series README).
- **`AscentM` is raw, `Cost` is weighted.** Documented in the struct so stage 04 does not
  assert on the wrong quantity.
- **No `Graph.EleCoverage()` in this stage.** "Is this graph's elevation real?" is a question
  about the *database column*, not the graph — the repo owns it (stage 02). A `EleM != 0`
  counter would be a lie for legitimately sea-level cities.

## Alternatives & Future

- **Energy model** (`∝ length·(Crr + m·g·grade)`) instead of a surcharge: more physically
  grounded, but the constants need a vehicle mass and rolling resistance, and the shape of the
  result is the same `L + w·Δz`. Rejected for v1 as unjustifiable tuning; revisit if drivers
  start reporting fuel use.
- **Turn penalties / slope-dependent speed limits**: a different objective (time, not
  distance), see stage 05. Not mixed into this one.
- **Bidirectional Dijkstra / ALT landmarks**: a real speedup for long routes, orthogonal to
  the cost function, and it composes with the scaled heuristic unchanged. Candidate for the
  stage-04 follow-up that also considers dense node indices.
- **Per-region weights** (a mountain city weighted differently from a coastal one): plan 06
  makes per-region graphs possible, so the weights could become per-region for free at that
  point. Out of scope now; note it there.

## Files to Modify

- `internal/routing/elevation.go` *(new)* — `CostWeights`, `weightedEdgeCost`, `deadband`,
  clamp, `heuristicScale`, `Validate`, `Path`, plus the Part 2 proof as a comment block.
- `internal/routing/routing.go` — `Node.EleM`; `Path`-returning `RouteWithWeights`;
  `Route` becomes a zero-weight wrapper; `metersScore`; the two-lookup hot loop; metrics
  reconstruction. `Edge`, `NewGraph`, the grid index, `scanNearest`/`gridNearest`,
  `NodeByID` **unchanged**.
- `internal/routing/routing_test.go` — append the 10 tests above; existing 11 untouched.
- `internal/routing/benchmark_test.go` — append `benchmarkGridElevated` +
  `BenchmarkRouteElevated`.
