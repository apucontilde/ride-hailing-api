---
tag: routing
depends_on: ["routing region resolution + snap-radius coverage (STATUS.md)"]
status: open
---

# Plan: Routing gate correctness — coverage gates that answer wrong

**Chain head (unnumbered).** `depends_on` names *landed* capability (region resolution +
the snap-radius coverage rule, `STATUS.md` → Landed `[routing]`), **not** an open plan, so this
file carries no `NN_` prefix. `01_[routing]_valle_central.md` depends on this plan (it uses the
A5 elevation-gate fix in its runbook).

> This plan coalesces the two "a coverage gate answers wrong" findings from the post-arrival
> review:
> - **A1** — the native snap gate used to answer **500** for uncovered pins in the ~265 m
>   PostGIS-vs-Go boundary band. **Already landed** (`00b2a5e`, 2026-09-30); §A1 is
>   verification only and specifies **no code change**. It is kept here because
>   `STATUS.md`'s Wave-1 note still (incorrectly) lists it as open.
> - **A5** — the elevation coverage gate (bug #24): ingest gate **0.98** vs runtime gate
>   **0.99**. **Open**; this is the substantive work in this plan.

---

## A1 — native snap gate: an uncovered pin is `200 is_estimate`, never `500` (ALREADY LANDED)

### The regression that was reported

The region resolver decides coverage with PostGIS `ST_Distance(...::geography)` (spheroidal),
while the native engine's own snap uses `routing.HaversineMeters` (great circle on a 6371 km
sphere). At 10° N the Go formula reads **~0.53 % long** (1111.9 m vs 1106.1 m), so under the
shipped `ROUTING_SNAP_RADIUS_M=50000` there is a **~265 m band** of pins the resolver calls
covered and the Go gate calls uncovered. Historically the resolver accepted the pin, the gate
then rejected it, and the error reached the handler as **500 INTERNAL** — which the rider app
draws as a road-less straight line (`rider_app/lib/features/home/presentation/home_screen.dart`,
the fallback branch). That violates the invariant "a pin the service accepted can never 500".

### What is already in the code (no work; evidence)

- One sentinel for a coverage data gap, distinct from "no path":
  `ErrPinUncovered` — `internal/repository/errors.go:26-36`.
- The gate is only the coverage authority when **nothing else has decided**:
  `coverageAuthority` + `gateIsAuthority` / `resolverIsAuthority`
  (`internal/repository/navigation_repo.go:163-194`); `coverPin`
  (`:210-229`); the gate is applied in `routeResults` only for `gateIsAuthority`
  (`:749-757`).
- `RouteInRegion` passes `resolverIsAuthority`, so the region path **never re-decides**
  a coverage answer the resolver already acted on — `navigation_repo.go:725-731`.
  `GetShortestPath` (unscoped/legacy) passes `gateIsAuthority` and reports
  `ErrPinUncovered` — `:707-713`.
- The service maps the data gap to the honest answer: `ErrPinUncovered` → `estimateRoute`
  (`200 is_estimate`) on the region path — `internal/service/navigation.go:175-192`;
  `routingDataGap` (`:348-356`); `legacyRoute` (`:449-465`). A genuine "covered but
  unroutable" pair keeps `routing.ErrNoRoute` and stays 5xx.
- Landed commit: `00b2a5e` (2026-09-30), bug-fix item **B — "Uncovered pins returned 500;
  now 200 estimate (ErrPinUncovered)"**; item **A** restored the snap radius into the native
  constructor.

### Pins that keep it from regressing

- `internal/repository/pin_uncovered_test.go:116-178`
  `TestRadiusBoundaryBandBetweenTheTwoCoveragePredicates` — asserts the band is real
  (49850 m PostGIS vs 50113 m Go) **and** that a band pin on the region path routes instead
  of failing.
- `internal/repository/pin_uncovered_test.go:18-101` — uncovered ≠ `ErrNoRoute`, empty graph
  is not an uncovered pin.
- `internal/service/pin_uncovered_test.go` — service mapping.
- `tests/route_uncovered_estimate_test.go:26` — HTTP 200 + `is_estimate` + 2-point straight
  polyline, and the other side: covered-but-unroutable stays 500.

### Action for this plan

**None in code.** The only action is documentation: close the stale Wave-1 condensed note
that says "Routing regression N1 … remains" (it was `api_plans/STATUS.md:660` before this
correction; the note is now reconciled in place), replacing it with the landed evidence above.
Do **not** re-implement a "residual band" fix — there is no residual path; every native path
(`GetRoute` region, unscoped fallback, legacy) now answers `200 is_estimate` for a coverage gap.

---

## A5 — elevation coverage-gate mismatch (bug #24) — OPEN

### Problem

A region whose elevation backfill lands between the two gates passes **ingest** but is
silently degraded to **flat routing at runtime** on the now-default elevation path:

| Gate | Value | Location |
| --- | --- | --- |
| Ingest (`elevtool -min-coverage` default) | **0.98** | `cmd/elevtool/main.go:56` (used `:146,:152-153`) |
| Ingest (script default) | **0.98** | `scripts/import-elevation.sh:23` |
| Runtime (`ROUTING_ELEV_MIN_COVERAGE` default) | **0.99** | `internal/config/config.go:181` (wired `:277`) |
| Runtime gate log | — | `internal/repository/navigation_repo.go:439-441` |

A region that imports at 0.98–0.989 satisfies the ingest gate, then the runtime gate
(`resolveElevation`, `navigation_repo.go:423-449`) sees `coverage < 0.99` and returns
`routing.CostWeights{}` — flat routing. Before the elevation flip this only meant "elevation
off"; since the flip it means the **default** path is flat for that region, and the only
signal is one per-graph log line.

### Fix (decided — align ingest UP; do not re-decide)

1. **One shared exported Go constant.** Export `DefaultElevationMinCoverage = 0.99` from
   `internal/config` (replacing the unexported `defaultElevationMinCoverage`,
   `internal/config/config.go:181`) and use it for both:
   - the runtime field default (`config.go:277`), and
   - `cmd/elevtool`'s `-min-coverage` flag default (`cmd/elevtool/main.go:56`), so the
     `cmd/elevtool` package imports `internal/config` as the single source of truth.
   A region backfilled to ≥ 0.99 now satisfies both gates.
2. **Script parity.** `scripts/import-elevation.sh` is bash and cannot import a Go constant;
   its `MIN_COVERAGE` default becomes **0.99** (`:23`) with a comment pointing at
   `config.DefaultElevationMinCoverage`, so the operator can still override both to the
   same value.
3. **Region-scope the post-import assertion.** The current assertion (`:43-45`) computes
   coverage over **all** of `road_network_vertices_pgr`, so a valley backfill is judged
   against other regions' vertices. Parse `--region <id>` (or a `REGION` env) in the script;
   when present, assert
   `... FROM road_network_vertices_pgr WHERE region_id = :'region'`
   (psql `-v region="$REGION"`). When absent, keep the global assertion and warn.

### Tests

- A unit test pinning the shared `DefaultElevationMinCoverage` and asserting
  `config.Load().RoutingElevation.MinCoverage == DefaultElevationMinCoverage` (so ingest and
  runtime cannot drift again). Extend `internal/config/config_test.go`.
- A test that the `cmd/elevtool` default equals the config constant (reference it in the flag
  default; assert via the parsed flag).
- The script's region-scoped assertion is exercised by the `valle_central` backfill
  (`01_[routing]_valle_central.md` runbook step 4); record the manual pass in that plan.
- Preserve the existing elevation invariants: distance stays meters, default **on** for the
  native engine, missing/partial coverage degrades flat (`elevation_aware=false`, totals 0),
  never garbage.

### Verification

```bash
make test                       # unit tests, no DB (must stay green)
make lint                       # golangci-lint v2, 0 issues
gofmt -w internal/config/config.go cmd/elevtool/main.go && go vet ./...

# Manual: a below-gate region must fail ingest loudly, not silently flatten at runtime.
grep -n "DefaultElevationMinCoverage" internal/config/config.go cmd/elevtool/main.go
grep -n "MIN_COVERAGE\|region_id = " scripts/import-elevation.sh
```

---

## Invariants this plan must not break

- A genuine outage answers **5xx or 200+`is_estimate`, never 4xx** (rider app draws a
  straight line on every error status).
- `NavigationRepository.GetShortestPath` signature is frozen; route cost stays **meters**.
- `native` stays the permanent default engine; the native A\* engine stays alive.
- Migration files are append-only.
- `[elevation]`: default **on** for the native engine; missing/partial coverage degrades to
  flat (`elevation_aware=false`, ascent/descent 0), never garbage.

## Open inputs

| Unknown | Resolve with |
| --- | --- |
| Whether the A5 gate should also be surfaced in the `/navigation/route` response as a per-region "elevation degraded" signal | Product call; today it is a log line only. Not required by bug #24 |
| Exact `--region` argument form the script should accept (`--region <id>` vs `REGION=<id>`) | Match `scripts/import-road-network.sh` / `cmd/elevtool -region` conventions |
