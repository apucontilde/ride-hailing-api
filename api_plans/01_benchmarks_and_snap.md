# Plan: Benchmarks + spatial snapping for the native engine

`internal/routing` is the in-process A\* engine the API ships today. Two problems this plan
fixes **before** any engine decision (plans 02/03):

1. **No benchmarks.** Nothing measures the engine, so there is no baseline for the pgRouting
   comparison (plan 03) and no regression gate.
2. **`NearestNode` is a linear scan.** `internal/routing/routing.go:82` iterates all ~153k
   San José vertices (≈0.5–2 ms) **twice per request** (`Route` snaps origin *and* goal). It
   is the dominant snapping cost and grows linearly with the network.

Outcome: measured baselines + O(V)→~O(1) snapping. `Graph` stays drop-in compatible with
`NavigationRepository` — nothing outside `internal/routing` changes.

## Current State (verified)

- `internal/routing/routing.go` — `Graph{nodes,list,adj}`; `NewGraph` (drops self-loops,
  unknown endpoints, non-positive costs); `NearestNode` = linear haversine scan over `list`
  (`routing.go:82–95`); `Route` = A\* + haversine heuristic (`routing.go:101–149`);
  `haversineM` (R=6371000, `routing.go:173`).
- `internal/routing/routing_test.go` — seven **plain `func Test*` functions** (not
  table-driven) over the hand-built graph in `testGraph()` (5 nodes, `routing_test.go:17–32`);
  `TestRouteEmptyGraph` uses `NewGraph(nil, nil)` — six of the seven use `testGraph()`, not
  all. All seven must stay green.
- `internal/repository/navigation_repo.go:116` — `GetShortestPath` calls `g.Route(...)`.
  Untouched by this plan (native fallback keeps working through plans 02–06).
- Dataset for intuition: San José road-network-only import ≈ 153k vertices / ~183k edges
  (undirected → ~366k adjacency entries; OSM-derived average degree ≈2.4).
- WSL harness: `gofmt -w <files>` + `go vet ./...` only (golangci-lint absent, AGENTS.md env
  fact 2). `Makefile` is NOT gofmt-able.

## Solution

### Part 1 — Benchmarks (`BenchmarkRoute` + friends)

New file `internal/routing/benchmark_test.go` (same package, no DB, no build tag):

- **`benchmarkGridGraph(n int)`** — synthetic `n×n` grid of nodes (e.g. `n = 400` → 160k
  nodes, ~0.0005° spacing to mimic city density) + edges to orthogonal neighbours. NOTE: an
  interior node has degree **4**, not SJ's ~2.4 — state this when reporting; do not claim
  the grid reproduces SJ topology, it is a stable synthetic baseline. Add `b.ReportAllocs()`
  + `b.SetBytes(2)` in the route benchmarks.
- **`BenchmarkRoute`** — two sub-benchmarks via `b.Run("corner",...)` (corner→corner, the
  long-path case) and `b.Run("hop",...)` (one block apart).
- **`BenchmarkNearestNodeLinear`** — the retained linear scan helper `scanNearest` (Part 2)
  on the same grid; `BenchmarkNearestNodeGrid` — the new grid snap. Keep BOTH: `scanNearest`
  stays exported-as-unexported so the benchmark is honest and the grid can be cross-checked
  for identical results.
- **`BenchmarkNewGraph`** — full graph build cost (plan 04 cold starts).

Record numbers; don't pre-commit to a number. Measurement instructions, not assertions:
report snap (linear vs grid) and full `Route` corner/hop for the native engine — these are
the baseline plan 03 compares `BenchmarkRoutePGRouting` against and the input to plan 03's
decision gate.

Makefile additions (also add `benchmark` and `bench-integration` to `.PHONY`, Makefile:1):

```make
benchmark:
	go test -count=1 -bench=. -benchmem ./internal/routing/
```

### Part 2 — Spatial grid index for `NearestNode`

Keep the public surface (`NearestNode(lat, lng) (Node, bool)`, `Route(...)` untouched). A
**uniform grid** (stdlib only — no new dependencies). IMPLEMENTED exactly as below
(2026-09); deviations from the draft ("expanding rings + AABB stop") are noted and are the
result of bugs the draft's wording would have introduced.

- Fields on `Graph`: `gridRows, gridCols int; gridMinLat, gridMinLng, gridCellLat, gridCellLng
  float64; cells [][]int64` — `cells` is a **flat row-major** bucket array (`index =
  row*gridCols + col`). Do NOT use a ragged `[][]*[]int64`; the flat layout is one
  allocation, cheap to index, and avoids pointer-chasing in the hot path.
- Build in `NewGraph` after assembling `nodes/list`:
  - bbox over `list`; cells per axis `c = int(math.Ceil(math.Sqrt(float64(len(nodes)))))`;
    **degenerate span guard**: `spanX = max(maxLng-minLng, 1e-9)` and same for lat, so a
    1-node or same-latitude graph never divides by zero;
  - hash each node into its bucket via `rowFor`/`colFor`.
- **`rowFor`/`colFor` MUST clamp in FLOAT space BEFORE the `int()` conversion.** This is the
  bug found during implementation: converting an out-of-range float to `int` in Go is
  implementation-defined (returns `MinInt64` on amd64), so the draft's
  "convert `int((lat-min)/cell)`, then `if r<0 → 0`" corrupted the clamp whenever the input
  was huge. That happens on the FIRST grid query (`bestD = MaxFloat64` → `candidateBounds`
  yields ~1.6e308°), which silently made `NearestNode` return not-found for an otherwise
  queryable graph. Correct form:
  ```go
  f := (lat - g.gridMinLat) / g.gridCellLat
  if f <= 0 { return 0 }
  if f >= float64(g.gridRows-1) { return g.gridRows - 1 }
  return int(f)
  ```
- Rewrite `NearestNode` to delegate to **`scanNearest`** (the current linear loop, moved to
  an unexported helper, kept so the benchmark/tests can cross-check) and **`gridNearest`**:
  - seed `bestD` from the query's **own cell** only (1 bucket, typically 0–few nodes);
  - convert `bestD` meters → a **candidate rectangle** in degrees via `candidateBounds`
    (below), map it to cell-index ranges `[rLo..rHi] × [cLo..cHi]`, and scan ONLY those
    cells. The rectangle is derived conservatively (see below) so every node that could
    beat `bestD` is guaranteed to be inside → the result is never worse than `scanNearest`'s.
- **Do NOT implement "search expanding rings; stop when the AABB distance of every
  unexamined cell exceeds best".** Two independent bugs in that draft wording: (a) a
  termination test on a *filled square* centered on the query's own cell is always true
  (the query's cell is inside every ring square), so the loop never terminates early and
  degrades to a full-grid scan — measured **slower** than linear (21 ms vs 12.4 ms); (b)
  "AABB distance in degrees vs best in meters" needs a deg↔meter conversion `per cell`,
  where a naive `cos(lat)` pick can under-widen the bound and prune a true candidate. The
  candidate-rectangle scan (seed cell + bounded rect) is simple, correct, and fast — use it.
- `candidateBounds(lat, bestD)` — convert meters to a lat/lng degree rectangle guaranteed
  to contain every point closer than `bestD` to the query:
  `dLat = bestD/(R·deg2rad)`; the longitude bound divides by the **minimum expected cos(lat)
  inside the rectangle**, `cos(|lat| + dLat)` (clamped `≥ 0.05` for polar safety), so the
  rectangle is never drawn too tight to prune a candidate. Cleaned up and inlined constants
  only — no state on `Graph`.
- Tie-breaking: `scanNearest` and `gridNearest` both use strict `d < bestD`. The grid's
  discovery order is cell-index order, so results can differ from the linear pass ONLY on
  exact-tie equidistant nodes (nonsensical in real data; the equivalence test asserts the
  match). Preserve the strict `<`.

Measured results (this plan's notes, 2026-09, `benchmarkGridGraph(400)`, `benchtime=2s`,
Ryzen 7 3700X):

| Benchmark | result |
| --- | --- |
| `BenchmarkNearestNodeLinear` | 12.36 ms/op, 0 allocs |
| `BenchmarkNearestNodeGrid` | 160 ns/op, 0 allocs — **~77,000× faster** |
| `BenchmarkRoute/hop` | 1.4 µs/op (snap dominates; 11 allocs) |
| `BenchmarkRoute/corner` | ~267 ms/op (A\* dominates; 242k allocs) |
| `BenchmarkNewGraph` | ~120 ms/op (58 MB/641k allocs) |

These ARE the plan 03 decision-gate baseline: pgRouting must be measured on the SAME workset
(synthetic grid imported to the pgr tables) and compared against these numbers + correctness
parity — not a hand-wavy "2×".

### Part 3 — Tests

Extend `internal/routing/routing_test.go`:

- `TestNearestNodeGridEquivalent` — property-style: for a spread of query points (inside,
  on-boundary, just-outside bbox), `gridNearest` must equal `scanNearest` on `testGraph()`
  and on a 3×3-cell graph. IMPLEMENTED as-is + an extra seeded 500-point random equivalence
  sweep (deterministic, covers border and out-of-bbox queries) — keeps the candidate-rect
  bound honest against the reference scan.
- `TestNearestNodeGridOutOfBounds` — queries outside the bbox (e.g. `(30,30)` on
  `testGraph()`) must not panic and must return a node (clamped to border cells).
- `TestNearestNodeGridDegenerate` — `NewGraph([]Node{{ID:1, Lat:10, Lng:10}}, nil)` (single
  node) routes and snaps without division by zero; `NewGraph(nil,nil)` returns `ok=false`.
- Existing 7 tests + `TestNearestNode` unmodified and green.

## Verification

1. `go test -count=1 ./...` → green (routing package first). Done — full suite already green.
2. `make benchmark` prints `BenchmarkRoute/corner`, `BenchmarkRoute/hop`,
   `BenchmarkNearestNodeLinear`, `BenchmarkNearestNodeGrid`, `BenchmarkNewGraph` with
   allocations; the results in Part 2 are the recorded baseline (snap improved >10× —
   actually ~77,000×; a square-root reduction in `NearestNode` was the plan's target).
3. `gofmt -w internal/routing/*.go` (NOT the Makefile); `go vet ./...` clean. Done (scoped
   to `./internal/routing/` — whole-module vet is slow under WSL).
4. Regression smoke (only if the SJ import exists; otherwise skip): route between two SJ
   coords returns the same `total_distance_m` as pre-change (`make run` restart first —
   native engine caches the graph in-process, AGENTS.md env fact 5). SKIPPED here: DB
   containers were not running in this harness; coverage comes from the equivalence tests
   (`gridNearest ≡ scanNearest`) which pin the exact `NearestNode` semantics `Route`
   depends on.

## Alternatives & Future

- **k-d tree / R-tree dependency**: marginal gains, adds a dep; grid is deterministic and
  cache-local. Revisit only for pathological density.
- This index is the in-process analogue of PostGIS GIST KNN (`nearestVid`, plan 03) — both
  are "spatial index for the snap" from each engine's perspective.
- The grid lives under `internal/routing` and survives plans 03–06 as the native engine's
  snap; it is NOT the routing hot path once `ROUTING_ENGINE=pgrouting`.

## Files to Modify

- `internal/routing/routing.go` — grid fields + build (+ degenerate-span guard) in
  `NewGraph`; `scanNearest` (moved linear loop) + `gridNearest`; `NearestNode` = wrapper.
- `internal/routing/routing_test.go` — grid equivalence/OOB/degenerate tests; existing 7
  stay untouched.
- `internal/routing/benchmark_test.go` *(new)* — `BenchmarkRoute`, `BenchmarkNearestNode*`,
  `BenchmarkNewGraph`, `benchmarkGridGraph`.
- `Makefile` — `benchmark` target + `.PHONY` entry.