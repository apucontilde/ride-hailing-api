# api_plans/elevation — elevation-aware routing (native engine)

Make the **native in-process A\* engine** (`internal/routing`) pick routes that are smart about
grade: in a city with abrupt elevation change, a route that *keeps going down* (or contours
along a slope) can beat the shortest-by-meters route, **even if it costs extra meters**. That
is the objective: trade a small amount of distance for materially less climbing.

This is a **sub-series** of `api_plans/`, split into 5 small stages. It is orthogonal to the
region series (plans 04–06) and to the engine-swap plan (03): it changes the *cost function of
the native engine*, not the engine, not the region model, not the endpoint contract.

> ## ⚠ Read this before stage 04: the provisional weights are pre-falsified
>
> This series was reviewed adversarially before any of it was implemented
> (`REVIEW.md`). The review stood up a throwaway implementation against the **real
> `skadi` DEM** and 2,000 random OD pairs, and the headline result is that the code-default
> weights `1.5 / 0.3 / 0.15 / 3` are **too weak to change the median trip**:
>
> | metric at the provisional defaults | measured |
> |---|---|
> | median `AscentM` ratio (elev/flat) | **1.0000** |
> | median `Meters` ratio (elev/flat) | **1.0001** |
> | pairs meeting the climb-avoidance filter | **45 / 2,000** |
> | "top N" filter outcome vs a 0.6 bar | **0.737** |
>
> Two errors in the original draft were also found this way, and both are fixed in place: the
> "flat control area" (`lat 9.90–10.00, lng −84.12…−84.02`) turns out to span **371 m of
> relief**, and the DEM URL chosen for stage 03 (`srtmgl1/…hgt`) **404s** — the bucket serves
> `skadi/…hgt.gz`.
>
> **What this means for an executor:** stages 01–03 are unchanged in intent and are still the
> right next work. Stage 04 has been restructured to be **sweep-first**: the constants are the
> hard part of this feature, they are *not* inherited from the code defaults, and the gate must
> be re-derived from a measured response curve. Do not read the provisional numbers in this
> series as a validated configuration.

## The problem in one paragraph

`internal/routing/routing.go` minimizes `Σ edge cost`, and every edge cost is **road length in
meters** (`road_network_edges_pgr.cost = ways.length_m`, copied by
`scripts/import-road-network.sh:327-334`). Elevation is therefore invisible to the search. The
classic failure this fixes: the distance-optimal path zig-zags over a ridge (climb 60 m, drop
55 m, climb 50 m…) when a 300 m longer path contours the hillside and never climbs.

## Hard invariants this series must not break

These are checked by every stage's verification; a stage that cannot satisfy one does not land.

1. **`total_distance_m` stays TRUE METERS, always.** The search runs on an elevation-weighted
   *pseudo-meter* cost. The number the API reports must be the sum of real edge lengths.
   `NativeNavigationRepo.GetShortestPath` sets `RouteResult.AggCost` from the **meters** value,
   never from the weighted cost. `service/navigation.go:41` turns `AggCost` into
   `DistanceMeters` → `FareService.CalculateEstimate` (`internal/service/fare.go:33-41`) prices
   from it. Inflating it silently inflates every fare.
2. **A\* stays correct (optimal + terminating).** The heuristic must remain an admissible AND
   consistent lower bound once costs stop being pure distance. Proof obligation in stage 01.
3. **Default is OFF.** `ROUTING_ELEVATION=off` reproduces today's engine bit-for-bit. Nothing
   changes for any deploy that does not opt in.
4. **Missing / partial elevation degrades to flat, never to garbage.** No DEM, a NULL column,
   or coverage below the threshold ⇒ the weights collapse to zero ⇒ identical to today.
   **Strengthened after review:** a whole-graph coverage threshold is not sufficient on its own,
   because a graph that *passes* it can still contain NULL endpoint pairs. Those edges must
   contribute **zero** elevation delta (never a coalesce-to-zero, which turns a missing value
   into a 1,164 m cliff). The exact rule is specified in stage 02 Part 3a.
5. **No new module dependencies.** stdlib only (matches the plan-01 grid decision).
6. **Migrations are append-only**, `*.up.sql` only, version = numeric prefix
   (`internal/database/migrate.go`). This series takes **015** — see the numbering note below.
7. **`NavigationRepository.GetShortestPath` signature stays frozen** (`api_plans/README.md`
   golden rule 1). The richer result travels on a *routing-package* type, not the interface.

## Stages

Read them in order. Each is sized so a **fresh model context** can execute it reading only
**that file** plus the files it explicitly names.

| File | Delivers | Depends on | Needs a DB? |
|---|---|---|---|
| `01_directional_cost_model.md` | The engine can minimize `(meters + w·ascent)`: directional edges, deadband, grade cap, admissible heuristic, `Path{…, Meters, Cost, AscentM}`. Pure Go, synthetic elevations, no schema change. | — | no |
| `02_elevation_column_and_repo_plumb.md` | Migration 015 (`elevation_m`, `elevation_source` on the routing vertex table) + `NativeNavigationRepo` loads it + config knobs + the coverage gate. Feature still OFF at the end. | 01 | yes (migration + repo) |
| `03_dem_ingest_and_noise_control.md` | Actual elevation data: `cmd/elevtool` (stdlib gzipped SRTM `.hgt` reader) + `scripts/import-elevation.sh` + the noise-control rationale (deadband/grade cap are the filter) + the ingest/verification queries. | 02 | yes (DB writes) |
| `04_calibration_and_rollout_gate.md` | The acceptance suite on real data (flat-invariance, climb-avoidance OD pairs found from live data, metric separation), the elevation-aware benchmarks, and the **documented go/no-go** for flipping the default. | 03 | yes |
| `05_duration_and_api_surface.md` | **OPTIONAL, deferred.** Grade-aware `total_duration_s` and additive response fields (`total_ascent_m`, …). Blast radius reaches both Flutter apps and the fare snapshot. | 04 | yes |

### Numbering note (why 015, not 013)

- `013_region_schema.up.sql` is claimed by `api_plans/04_region_schema_and_registry.md:56`.
- `014` (routing_ports) appears only in `api_plans/07`'s **archived** section
  (`07_intercity_future_stub.md:61-75`) — reserved so that if intercity is ever revived it
  cannot collide.
- The highest migration that exists on disk today is `012_enable_pgrouting.up.sql`. Claiming
  015 leaves a **gap (013, 014 absent)**. A gap is harmless: the runner sorts the files it finds
  and applies each pending version in order (`internal/database/migrate.go`); it does not
  require contiguity.

### Relationship to the other api_plans series

- **Plan 03 (pgRouting swap)**: the gate was NOT met, so `native` is production and pgRouting
  serves long-haul only. **This series changes the native engine's cost function, so
  `ROUTING_ENGINE=native` and `ROUTING_ENGINE=pgrouting` will disagree on which route is
  "shortest" for the same OD pair.** That divergence is accepted and logged for v1 (stage 02);
  pgr parity is a named follow-up, not a silent gap. Re-read plan 03's decision-gate block
  before touching `pgrouting_repo.go`.
- **Plan 04/05 (regions)**: `elevation_m` lands on `road_network_vertices_pgr` as a plain
  column, no region dependency — stage 03's backfill is written region-agnostic and plan 05's
  region-scoped DELETE wipes it with the vertices. Stage 03 states the re-import ordering.
  **One coupling to be aware of:** stage 03's `-region` flag is specified against a
  `region_id` column that **does not exist until plan 04 lands** — the tool is required to
  probe `information_schema` and error rather than silently process every region. Before plan
  04, the flag is simply unavailable; that is the intended behaviour, not a gap, but do not
  "fix" the probe by hardcoding the province bbox.
- **Plan 06 (per-region graphs)**: the elevation-aware adjacency build cost multiplies by the
  number of cached regions. Stage 04's benchmark numbers are the input to plan 06's memory
  budget (currently ~150–200 MB/city).
- **Migration 009 (`009_compute_elevation_costs.up.sql`) is DEAD, not reusable.** Its
  `sample_elevation()` is a placeholder returning `0` (`009:2-8`), and its `UPDATE`s ran at
  migration time — i.e. against an **empty** `road_vertices` (imports happen later, by script).
  Verified live: `road_vertices` has 152,665 rows and **0** non-null `elevation_m`;
  `road_edges` has 0 rows and 0 non-null `gradient`/`cost_elev`. It is also the wrong tables:
  routing reads `road_network_*_pgr` (011), not `road_*` (008). This series writes a new column
  on the 011 vertex table and does not touch 008/009.

## Verified facts every stage may rely on (measured 2026-09-25 on the live dev DB)

| Fact | Value | How to re-check |
|---|---|---|
| Routing vertices / edges (SJ province import) | 152,665 / 183,371 | `SELECT count(*) FROM road_network_vertices_pgr;` |
| Vertex bbox | lat 8.9884899…10.2369185, lng −84.5361388…−83.3904684 | `ST_Extent(the_geom)` |
| Edge length: median | **64.4 m** | `percentile_disc(0.5) WITHIN GROUP (ORDER BY cost)` |
| Edges shorter than 20 m | **27,834 (15.2 %)** | `count(*) FILTER (WHERE cost < 20)` |
| Edges shorter than 40 m | **55,907 (30.5 %)** | `count(*) FILTER (WHERE cost < 40)` |
| Edges shorter than 80 m | 106,771 (58.2 %) | `count(*) FILTER (WHERE cost < 80)` |
| PostGIS raster extension | **present** (`postgis_raster 3.5.2`) | `SELECT * FROM pg_extension` |
| `road_vertices.elevation_m` | 100 % NULL | `SELECT count(elevation_m) FROM road_vertices` |
| `road_edges` row count | **0** (see warning below) | `SELECT count(*) FROM road_edges` |
| Routing vertices per DEM tile | `N08W084` 7 · `N09W084` 38,141 · `N09W085` 79,731 · `N10W084` 3,096 · `N10W085` 31,690 · `N08W085` **0** | bucket live vertices by `floor(ST_Y)`, `floor(ST_X)` |
| DEM source that works | `https://elevation-tiles-prod.s3.amazonaws.com/skadi/N09/N09W085.hgt.gz` → `200 application/x-gzip`, 7,798,473 B, `3601²` after gunzip | `curl -sI` + size check |
| DEM source that 404s | `.../srtmgl1/N09W085.hgt` — the bucket has **no `srtmgl1` prefix** (it has `skadi`, `geotiff`, `terrarium`, `normal`, `docs`, `lib`, `logs`, `v2`) | `curl -sI` |

> ⚠ **The 008 tables are not a reliable source and the importer hides SQL errors.**
> `scripts/import-road-network.sh:289-314` inserts into `road_edges` (which has FKs to
> `road_vertices(id)`, `008:12-13`) *before* inserting into `road_vertices`, and `psql_run`
> (`:117`) sets no `ON_ERROR_STOP`, so the FK violation aborts only that statement while the
> rest of the heredoc continues. Verified live: `road_edges` is empty, `road_vertices` is full,
> and the FK really does reject an unknown `source`:
> `ERROR: insert or update on table "road_edges" violates foreign key constraint "road_edges_source_fkey"`.
> Any new SQL this series adds to the importer must not rely on that heredoc being atomic —
> stage 03 puts the elevation backfill in its **own** tool, not in that heredoc.

## Why the cost model is shaped the way it is (the one-paragraph version)

The natural knob is "make climbing expensive". Formally, for an edge `u→v` of length `L` and
elevation delta `Δz`, cost becomes `L · (1 + w·grade)` with `grade = Δz/L`, i.e.
`cost = L + w·Δz` for an uphill edge. **In the deadband-free, unclamped case that is exactly a
per-meter price on total ascent** — and total ascent `Σ max(0, Δz)` is *additive over edges*,
which is precisely what a shortest-path search needs. So "minimize weighted ascent" is a
legitimate single-objective A\* problem, not a multi-criteria one that needs Pareto search.
Downhill gets its own (smaller) weight, which is what makes "keep going down instead of going
up and over" expressible. The cost of that choice — a downhill credit makes cost *less than*
distance, which breaks the plain haversine heuristic — is paid explicitly in stage 01 by
scaling the heuristic by a provable lower-bound factor.

**But the shipped model is not that identity, and the series no longer implies that it is.**
With the deadband and the grade cap active the real edge cost is `L·(1 + w·g')` with
`g' = clamp(deadband(Δz)/L, ±MaxGrade)`, and `g'·L ≠ Δz`. Measured on this network with
`DeadbandM = 3`, the deadband zeroes **59.5 %** of edges and the cap binds on **5.0 %**, so the
identity is false for most edges. The deadband is a per-edge function, so A\* optimality is
unaffected; what is affected is the *interpretation*: `AscentM` is a **proxy** for the optimized
quantity, not the optimized quantity. Stage 04's ascent ratios must be read that way, and the
deadband value is an open question rather than a datasheet figure (stage 03 Part 4a). The full
derivation, the admissibility proof, the exact formula, and the corrected caveats are in
`01_directional_cost_model.md`.

## Context-model discipline (how to work these stages)

Each stage file opens with a **Context** block listing the exact files to read and the exact
files to write, and states its own facts inline so they do not have to be re-derived. The rule
for anyone (human or model) executing a stage:

> Read only the files in that stage's Context block. If you need a file that is not listed,
> you are either in the wrong stage or the stage is missing a required fact — fix the stage
> doc before writing code, do not wander.

Environment rules that apply to every stage (from `AGENTS.md`): `golangci-lint` is **not**
installed (use `gofmt -w <files>` + `go vet ./...`); the Flutter/Dart CLI is broken in this WSL
harness (stage 05's Dart work must be reviewed by hand, not by `flutter analyze`); the native
graph is cached **in-process**, so any change to the imported network **requires an API restart**
(plan 06 fixes this properly — until then, state it in every stage that writes data).

## Verification (every stage)

```bash
make test            # unit, no DB — must stay green
make test-integration
gofmt -w <files> && go vet ./...
```

Live check (DB up, token required) — see `.opencode/skills/road-routing/SKILL.md` for the
register/login snippet:

```bash
curl -s "localhost:8080/api/v1/navigation/route?from_lat=9.9333&from_lng=-84.0833&to_lat=9.9433&to_lng=-84.0733" \
  -H "Authorization: Bearer <token>"
```

## Authoritative sources

- Engine internals: `internal/routing/routing.go`, `.opencode/skills/road-routing/SKILL.md`
- Data + import: `scripts/import-road-network.sh`, `internal/database/migrations/011_create_routing.up.sql`
- Engine-selection history: `api_plans/03_swap_engine_to_pgrouting.md`
- Adversarial review of THIS series (missing context / over-broad wording / implementation risk):
  `REVIEW.md`
