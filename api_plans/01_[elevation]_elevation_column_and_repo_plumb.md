---
tag: elevation
depends_on: ["[elevation]_directional_cost_model.md"]
status: open
---

# Stage 01 — Elevation column (migration 015) + repository/config plumbing

> **Numbering note.** This chain was renumbered so that its head is unnumbered — a `NN_`
> prefix is earned only by a `depends_on` that names an *open* plan
> (`.opencode/skills/plan-management/SKILL.md`). **Filenames and `depends_on` are
> authoritative.** Body prose below may still say "stage N" in the
> pre-renumbering scheme, where old stage 01 = the unnumbered head `[elevation]_directional_cost_model.md`, old 02 = `01_[elevation]_elevation_column_and_repo_plumb.md`, old 03 = `02_[elevation]_dem_ingest_and_noise_control.md`, old 04 = `03_[elevation]_calibration_and_rollout_gate.md`, old 05 = `04_[elevation]_duration_and_api_surface.md`.
> Translating that prose is a tracked follow-up; do not renumber it piecemeal.


**Goal.** Give the routing vertex table a real elevation column, load it into the native graph,
and expose the whole feature behind configuration that **defaults to off**. When this stage
lands, `make import-elevation` does not exist yet, so there is no data — and the API must
behave exactly as before. This stage is about the *wiring being correct and safe*, not about
the feature being visible.

Depends on: `01_directional_cost_model.md` (`routing.CostWeights`, `routing.Path`,
`RouteWithWeights`).

## Context

> ⚠ **Corrected after review (`[elevation]_review.md` §1.5, §1.6, §2.1, §5.1, §5.3, §5.4).** Line refs
> fixed; the **NULL-endpoint edge rule is now specified** (it was a real spec gap with two
> plausible bad implementations); the import/elevation interaction is corrected — the import
> never populates `elevation_m` *at all*, so a re-import yields a zero-coverage graph by
> construction, not a stale one; and the engine precondition for enabling the flag is now part
> of the definition, not just a log line.

**Read (nothing else):**

- `api_plans/STATUS.md` — invariants 1–7 and the numbering note. Non-negotiable.
- `internal/routing/elevation.go` + `internal/routing/routing.go` — as landed by stage 01
  (only `RouteWithWeights`, `Path`, `CostWeights`, `Validate` matter here).
- `internal/repository/navigation_repo.go` — the whole file (148 lines).
- `internal/repository/pgrouting_repo.go:70-79` — the engine factory.
- `internal/config/config.go` — the whole file (136 lines); note `getFloat` already exists
  (`config.go:129-136`), added by plan 05.
- `internal/database/migrate.go` — confirm the runner semantics (sorted `*.up.sql`, numeric
  version prefix).
- `internal/database/migrations/012_enable_pgrouting.up.sql` — the migration *style* to copy
  (idempotent, explicit casts, comments explaining the non-obvious).

**Write:**

- `internal/database/migrations/015_vertex_elevation.up.sql` *(new)*
- `internal/database/migrations/015_vertex_elevation.down.sql` *(new — documentation only; the
  runner never executes `.down.sql`)*
- `internal/config/config.go` (edited)
- `internal/repository/navigation_repo.go` (edited)
- `internal/repository/pgrouting_repo.go` (edited — one line: pass `cfg` down)
- `internal/repository/navigation_elevation_integration_test.go` *(new)*
- `.env.example` (edited)
- `AGENTS.md` (edited — one row in the config table)

**Do NOT touch:** `internal/routing/*` (stage 01 owns it), `internal/service/*` (the service is
elevation-agnostic by design — it only ever reads `AggCost`), `internal/handler/*`, the Flutter
apps, `scripts/import-road-network.sh` (stage 03 owns DEM tooling; only a note about
re-import ordering is recorded below), migrations 001–012.

**Needs a DB?** Yes — the migration must apply and load against the live dev DB.

## Problem

Stage 01 gives the engine the ability; nothing supplies elevations or turns the ability on.
Three specific hazards make this more than a `SELECT` and a flag:

1. **The reported distance would silently become the search cost.** `GetShortestPath` currently
   writes the search's accumulated cost into `RouteResult.AggCost`
   (`navigation_repo.go:145`), and `service/navigation.go:41` turns that into `DistanceMeters`,
   which `FareService.CalculateEstimate` prices from (`fare.go:33-41`). Once costs are
   elevation-weighted, that line must take the **meters** value instead. Getting it wrong
   inflates every fare by the ascent surcharge with no error anywhere.
2. **`NULL` is not `0`.** A vertex with no DEM sample and a vertex at sea level both have to
   be represented, and only one of them is `0`. `sqlx` scanning a `DOUBLE PRECISION` NULL into
   a `float64` field yields `0` silently. A partially-backfilled column (stage 03 backfills
   per region, and re-imports wipe it) must degrade to flat routing, not to a graph where
   40 % of vertices sit at 0 m and the other 60 % are at real altitude — that fabricates a
   cliff down every un-backfilled edge.
3. **The two engines will disagree.** `PGRoutingRepo` (`pgrouting_repo.go:81-111`) reads the
   `cost` column directly and has no elevation. With `ROUTING_ENGINE=pgrouting`, the same OD
   pair gets a different "shortest" route than on `native`. Not a crash — a silent
   inconsistency between deployments. It must be **logged loudly** and recorded, not papered
   over.

## Current State (verified 2026-09-25)

- `road_network_vertices_pgr(id BIGINT PK, the_geom GEOMETRY(Point,4326), lat, lng)` —
  `011_create_routing.up.sql:10-15`. **No elevation column.** 152,665 rows live.
- `road_network_edges_pgr(id, source, target, cost)` — `011:17-22`. `cost` is meters; the plan
  keeps it that way (STATUS.md invariant: never "fix" it into a weighted value, because
  pgRouting reads the same column).
- Highest migration on disk: `013_region_schema.up.sql` (the region series landed); `schema_migrations`
  shows 001–013 applied. `014` is reserved by `[routing]_intercity.md`'s archived section.
  **This stage claims `015`.** The resulting 014 gap is harmless — the runner sorts what it
  finds and applies pending versions in order.
- `Add column` on this table is metadata-only in PostgreSQL ≥ 11 (no rewrite of 152k rows), so
  the migration is instant and needs no `CONCURRENTLY`, no downtime window.
- `NativeNavigationRepo.loadNodes` (`navigation_repo.go:85-102`) selects
  `id, ST_Y(the_geom) AS lat, ST_X(the_geom) AS lng` into `roadNode{ID, Lat, Lng}`; it
  builds `routing.Node` with keyed literals (`:99`), so a new field is source-compatible.
- `roadGraph()` (`:60-83`) caches the graph once and **retries every call while the network is
  empty** (`graphAttempted` is only set on success, `:81`) — so the elevation decision should be
  made *inside* that same build, not at construction time, or a pre-import boot would latch the
  wrong answer for a DB that gets its network later.
- `NewNavigationRepo(db *sqlx.DB)` (`navigation_repo.go:52`) has exactly **one** caller:
  `NewRoutingRepository` at `pgrouting_repo.go:78`, which itself has one production caller,
  `internal/router/router.go:32`. Changing the signature touches one line.
- `NewRoutingRepository(db, cfg)` already takes `*config.Config` and already handles
  `cfg == nil` correctly (`pgrouting_repo.go:71`), so the nil-config precedent is set.
- `config.go` already has `RoutingEngine` + `RoutingSnapRadiusM` and a `getFloat` helper
  (`config.go:40-48, 82-83, 129-136`); `DEMFilePath` exists at `config.go:32,74` and is wired to
  `DEM_FILE_PATH` in `.env.example:24-25` but is **read by nothing** — a dead knob. Stage 03
  decides its fate; stage 02 only adds a comment saying so.
- `tests/testutil/mock_navigation_repo.go` implements only `GetShortestPath` and asserts
  5000 m / 454 s in several tests. It is **not** touched by this stage — the interface does not
  change (series README invariant 7).

## Solution

### Part 1 — Migration 015

```sql
-- 015_vertex_elevation.up.sql
-- Elevation for the NATIVE engine's cost model (api_plans/01_[elevation]_elevation_column_and_repo_plumb.md).
--
-- - Units: METERS, orthometric height above the EGM96 geoid (what SRTM-class
--   DEMs publish). A constant datum offset cancels in every per-edge delta
--   (cost depends only on dz), but MIXING DEM vintages inside one region
--   creates a real step artifact -- so elevation_source records provenance
--   per vertex and stage 03 backfills region-scoped, one DEM at a time.
-- - NULL means "no sample for this vertex" and is NOT the same as 0 (sea
--   level). The repository counts NULLs and falls back to flat routing below
--   the coverage threshold; never coalesce to 0 at write time.
-- - The pgr layer (pgrouting_repo.go) does NOT read this column: pgRouting
--   keeps using road_network_edges_pgr.cost, which stays in meters.
--
-- Idempotent and metadata-only (PostgreSQL >= 11): no table rewrite, no lock
-- beyond a brief ACCESS EXCLUSIVE, safe on the live 152k-row table.

ALTER TABLE road_network_vertices_pgr
  ADD COLUMN IF NOT EXISTS elevation_m    DOUBLE PRECISION;
ALTER TABLE road_network_vertices_pgr
  ADD COLUMN IF NOT EXISTS elevation_source TEXT;

COMMENT ON COLUMN road_network_vertices_pgr.elevation_m IS
  'Meters, EGM96 orthometric. NULL = no sample. Feeds the native engine cost model.';
COMMENT ON COLUMN road_network_vertices_pgr.elevation_source IS
  'Provenance of the sample (e.g. skadi:N09W085). Constant within a region; mixing sources creates a step artifact.';
```

Explicit `DOUBLE PRECISION`, not `REAL`: stage 01's per-edge `dz/meters` divide on 20 m edges
turns a 3.8 m quantization (REAL's float32 epsilon at SJ's ~1,000 m elevation) into a ~19 %
grade error. This is the same class of bug the deadband exists to damp, and picking the wider
type costs nothing (8 bytes × 152k = 1.2 MB).

`015_...down.sql` — for the documentation-only convention:
`ALTER TABLE road_network_vertices_pgr DROP COLUMN IF EXISTS elevation_source, DROP COLUMN IF EXISTS elevation_m;`

**Do not** add a GIST/btree index on `elevation_m` — nothing queries by elevation.

### Part 2 — Config

Add to `Config` (a single `RoutingElevation` sub-struct keeps six new knobs out of the top
level, and keeps the constructor readable):

```go
// RoutingElevation configures the native engine's elevation cost model
// (api_plans/elevation). Off by default: the zero configuration reproduces
// the pre-elevation engine exactly.
type RoutingElevation struct {
    Enabled       bool    // ROUTING_ELEVATION=on|off   (default off)
    AscentWeight  float64 // ROUTING_ASCENT_WEIGHT       (default 1.5)
    DescentWeight float64 // ROUTING_DESCENT_WEIGHT      (default 0.3)
    MaxGrade      float64 // ROUTING_MAX_GRADE           (default 0.15)
    DeadbandM     float64 // ROUTING_ELEV_DEADBAND_M     (default 3.0)
    MinCoverage   float64 // ROUTING_ELEV_MIN_COVERAGE   (default 0.99)
}
```

Defaults are **proposals, not findings**: the real values come out of stage 04's calibration.
They are chosen so that (a) the deadband matches SRTM-class vertical error, (b) `MaxGrade` is
above any real urban road, and (c) `DescentWeight·MaxGrade = 0.045 ≪ 1`, so
`heuristicScale ≈ 0.955` and A\* prunes nearly as well as today. Mark them as such in the code
comment and in the `MEASURED` block below — a reader must not mistake a starting point for a
tuned value.

Parsing follows the existing style: `getEnv(key, "off") == "on"` for the bool (like
`PlacesSeedOnStart`, `config.go:77`), `getFloat` for the rest. Whitelist the bool to
`on`/`off` and treat anything else as `off` — a typo must fail **closed** (flat routing), not
open.

### Part 3 — Repository

`NativeNavigationRepo` gains two fields, set in the constructor from `cfg`:

```go
elev      routing.CostWeights // zero value == flat routing
elevOn    bool               // cfg.RoutingElevation.Enabled
minCover  float64            // coverage fraction required
```

Constructor becomes `NewNavigationRepo(db *sqlx.DB, cfg *config.Config) *NativeNavigationRepo`
— the single call site `pgrouting_repo.go:78` becomes `NewNavigationRepo(db, cfg)`. A `nil`
`cfg` must yield the zero value (the same nil-tolerance `NewRoutingRepository` already has).

`loadNodes` becomes:

```go
type roadNode struct {
    ID  int64   `db:"id"`
    Lat float64 `db:"lat"`
    Lng float64 `db:"lng"`
    // EleM is a POINTER on purpose: NULL (no sample) and 0 (sea level) are
    // different facts and the coverage gate needs to tell them apart.
    EleM *float64 `db:"elevation_m"`
}
```

Scan `elevation_m` and count the samples. `sqlx`/`lib/pq` map a SQL NULL into a nil `*float64`
and a real value into an allocated one — no `sql.NullFloat64` ceremony needed, but if a
scanner error ever appears, prefer `sql.NullFloat64` over assuming the pointer behaviour.

Then, **inside `roadGraph()`** (not the constructor — see the `graphAttempted` note above):

```go
covered := count of non-nil EleM
if !r.elevOn || covered == 0 || float64(covered)/float64(len(rows)) < r.minCover {
    // flat routing; log ONCE (this runs once per successful graph build)
    weights = routing.CostWeights{}
} else {
    weights = r.elev
    if err := weights.Validate(); err != nil {
        log.Printf("invalid elevation weights (%v); falling back to flat routing", err)
        weights = routing.CostWeights{}
    } else {
        log.Printf("elevation-aware routing on: %d/%d vertices (%.2f%%), ascent=%.2f descent=%.2f maxGrade=%.2f deadband=%.1fm",
            covered, len(rows), 100*frac, weights.AscentW, weights.DescentW, weights.MaxGrade, weights.DeadbandM)
    }
}
```

**The log must name the reason** ("disabled" / "no samples" / "coverage 0.62 < 0.99" /
"invalid weights"). A silently-flat deployment is indistinguishable from a bug until you know
which of the four happened; this is the one place in the whole series where a log line saves
an afternoon.

`GetShortestPath` becomes:

```go
p, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, r.weights)
...
results := make([]RouteResult, 0, len(p.Nodes))
for i, id := range p.Nodes { /* unchanged: NodeByID + Lat/Lng */ }
if len(results) > 0 {
    // METERS, never p.Cost. This single line is series invariant #1: fare,
    // duration and total_distance_m all derive from it (service/navigation.go:41
    // -> fare.go:33-41).
    results[len(results)-1].AggCost = p.Meters
}
```

Also log `p.AscentM` at debug level when `DEBUG_LOGGING` is on — stage 04 needs it and the
repo has no other way to see it. Do **not** put `AscentM` in the `RouteResult` or the API
response here; that is stage 05, and its blast radius reaches both apps.

### Part 3a — The NULL-endpoint edge rule (specified here; it was a gap)

The coverage gate answers a whole-graph question ("is this graph's elevation usable?"). It does
**not** answer "what does the cost function do with the ~1 % of edges that have a NULL
endpoint?" At `MinCoverage = 0.99` on this network that is ~1,500 NULL vertices and ~1,800
edges — a state that *passes* the gate and still reaches the hot loop. The two plausible
implementations are a nil-pointer dereference and a coalesce-to-zero, and the second is worse
than a crash: a vertex at 1,164 m beside a `NULL` vertex becomes a 1,164 m grade clamped to
`MaxGrade` — a permanent 22.5 % uphill penalty on a road that is flat.

**Rule, fixed before implementation:**

> An edge with **any unknown endpoint contributes zero elevation delta** — no surcharge and no
> credit. It is still traversed and still costs its true `meters`. The count of such edges is
> reported at graph-build time and logged next to the coverage line.

`Node.EleM` therefore cannot stay a plain `float64` in which 0 means both "unknown" and "sea
level". Two options, and the implementer must **pick one explicitly and record it here**:

- **(a) a per-node known-bit** carried on `Node` (or a `[]bool` beside the elevations in the
  repo's load path), with a `dz = 0` branch where the delta is computed. Local, cheap, keeps
  `Graph` immutable. **Recommended.**
- **(b) a two-pass fix-up in the repo** that propagates known elevations over the built graph
  before the first query. Mutates a structure documented as immutable (`routing.go:37`),
  and the propagation order is itself a source of bugs.

Either way, `TestNativeRepoPartialCoverage` at coverage **0.995** must exist. The originally
proposed cases only exercise coverage *below* the gate (2-of-3 = 0.67, 98/100 = 0.98) — the
state that never reaches the hot loop.

### Part 4 — The engine divergence, stated and logged

`NewRoutingRepository` (`pgrouting_repo.go:70-79`) must warn when the two facts are combined:

```go
if cfg != nil && cfg.RoutingElevation.Enabled && cfg.RoutingEngine == "pgrouting" {
    log.Println("WARNING: ROUTING_ELEVATION=on with ROUTING_ENGINE=pgrouting has NO EFFECT " +
        "(pgr_dijkstra reads road_network_edges_pgr.cost, which is still pure meters). " +
        "Routes will differ from the native engine's. Use ROUTING_ENGINE=native, or see " +
        "api_plans/04_[elevation]_duration_and_api_surface.md for the parity follow-up.")
}
```

Warn, do not refuse: refusing would break a deployment that set the flag in anticipation, and
the flag's default is off anyway. The warning must fire on the **fallback** path too — the one
at `pgrouting_repo.go:76`, where `pgrouting` is requested on a DB without the extension and
the native repo is used instead (there elevation *would* work, and the operator should know it
did). Restructure the factory so the warning is emitted once, after the engine is settled.

**A log line is not a control.** `ROUTING_ENGINE` is a deployment-wide, boot-time choice, so
the flag combination is knowable at boot — make it *knowable*, not just warned about:

- The settled engine and the settled elevation mode must both be reported in **one** boot line
  (`routing engine=native elevation=on coverage=99.8% weights=...`), so a `docker logs | grep`
  answers "is elevation actually live here?" in one shot.
- Stage 04's flip decision must state the engine precondition explicitly
  (`ROUTING_ENGINE=native` required). **The default stays off if either condition is not met**,
  and the gate must fail rather than flip a flag that is inert on the configured engine.

### Part 5 — Re-import ordering (recorded, not implemented)

**The framing in the first draft of this section was wrong and is corrected here.** It said the
import "truncates the tables, so elevation is wiped". The stronger and more accurate statement:

> `scripts/import-road-network.sh:318` runs
> `TRUNCATE road_network_vertices_pgr, road_network_edges_pgr RESTART IDENTITY CASCADE` inside
> `copy_data()`, which runs on **every** import path (not only `--force`) — and the importer
> **never writes `elevation_m` at all**. So a graph built after any import has
> **zero elevation coverage by construction**, not stale or partial coverage. Ordering is not
> a race that a careful operator can win; the coverage gate is the *only* thing standing
> between a routine re-import and silently-flat routing, and the boot log is the only signal.

Consequences, all of which must be written into stage 03's runbook and `AGENTS.md`:

- **Post-import assertion.** Stage 03's script must end with a coverage query and a non-zero
  exit when coverage is below the gate. A successful import that silently un-enables the
  feature is a regression nobody would notice.
- **Restart is mandatory** after both the import and the elevation backfill (AGENTS.md env
  fact 5: the graph is cached in-process, and it holds the `EleM` values loaded at boot).
  Until plan 06 makes the graph import-fresh, the only correct sequence is
  **import → elevation → restart**.
- **Do not try to fix this in the importer heredoc.** It has no `ON_ERROR_STOP`
  (`import-road-network.sh:117`), so a failure inside it is invisible; the 008-table FK
  ordering bug in the series README is the proof. Keep the elevation write in its own tool.

## Tests to add (`navigation_elevation_integration_test.go`, `//go:build integration`)

Follow the existing pattern in `pgrouting_repo_integration_test.go`: seed TEMP tables named
like the real ones on a single connection so the real SJ import is never touched.

- `TestNativeRepoElevationLoaded` — 3 vertices: one with `elevation_m = 100`, one `= 0`, one
  **NULL**. Assert the repo's coverage accounting classifies them as 2-of-3 covered and
  (at `MinCoverage = 0.99`) falls back to flat.
- `TestNativeRepoCoverageGate` — 100 vertices, 100 covered → elevation on; 98 covered → off;
  0 covered → off. Assert the *route shape*, not just the flag, using a two-path fixture where
  the climbing path is shorter.
- `TestNativeRepoAggCostIsMeters` — **the invariant test.** Build a fixture whose chosen route
  has `Meters = 800` and a weighted `Cost` of 1100; assert
  `results[last].AggCost == 800`. This fails loudly if anyone ever swaps in `p.Cost`.
- `TestNativeRepoFlatWhenElevationOff` — with `Enabled=false` and a fully-populated elevation
  column, the route must equal the `AscentW=0` route.
- `TestNewRoutingRepositoryElevationWarning` — extend the existing
  `TestNewRoutingRepository` table (`pgrouting_repo_integration_test.go:193`) with the
  on+pgrouting case; assert the factory still returns a working repo (warn, not refuse).
- Unit test (no tag, in the same package): `config.Load()` picks up
  `ROUTING_ELEVATION=on`, `ROUTING_ASCENT_WEIGHT=2`, an unknown `ROUTING_ELEVATION=maybe`
  (→ off), and a nil-cfg constructor call. Keep these out of the tagged file so `make test`
  covers them without a DB.

## Verification

1. `make test` green (no DB) — the config/unit tests above ran.
2. `make test-integration` green; the output must list the new test names.
3. `docker exec ride-hailing-db psql -U ridehail -d ridehailing -c "\d road_network_vertices_pgr"`
   → the two new columns, `schema_migrations` shows `015`.
4. **Default-off proof**: with no elevation data, the live route endpoint returns the exact
   polyline and `total_distance_m` it returned before this stage. Capture the "before" first
   (curl, `.opencode/skills/road-routing/SKILL.md` has the register/login snippet), diff after.
5. **Degrade proof**: `UPDATE road_network_vertices_pgr SET elevation_m = 0` on 10 % of rows,
   restart, confirm the boot log says coverage fell below the threshold and the route is
   unchanged; `ROLLBACK`/restore. This is the only way to see Part 3's gate actually fire.
6. `gofmt -w internal/config/config.go internal/repository/*.go && go vet ./...`.
7. `.env.example` and `AGENTS.md` updated with the five new env vars and the
   "restart after backfill" note.

## MEASURED

_(empty — this stage changes no algorithm. Fill in the Part-3 boot log line from a real run,
and the before/after `total_distance_m` from verification 4, so stage 04 has a clean baseline.)_

## Decisions Recorded

- **Migration 015, not 013.** 013 is on disk (the landed region series), 014 is reserved by
  `[routing]_intercity.md`'s archive. The gap is harmless; a collision is not recoverable under
  the append-only rule.
- **`DOUBLE PRECISION`, not `REAL`.** `road_vertices.elevation_m` is `REAL` (008:5) and 009
  would have quantised a 1,000 m elevation to ~6 cm — enough to read as grade on short edges.
- **Coverage gate lives in the repository, decided at graph-build time**, not in the
  constructor: the constructor runs before any import on a fresh DB and would latch the wrong
  answer.
- **Weight validation falls back to flat, never to partial.** A rejected weight set must not
  silently become "ascent on, descent broken".
- **Elevation lives on vertices, not on edges.** Per-edge `dz` is derived in the engine
  (`stage 01`), so a single vertex column is the only data needed and there is no
  backfill-consistency problem between two tables.
- **pgRouting parity is deferred, with a warning.** The alternative — writing a weighted
  `cost` into `road_network_edges_pgr` — would break the meters contract that
  `total_distance_m` and the pgr layer both depend on, and would change routes for engines
  that never asked for elevation. Do not do it implicitly.
- **`DEM_FILE_PATH` stays unwired in this stage.** It is a dead knob; stage 03 either gives it
  a job or removes it. Leaving it silently dead is the one thing not to do.

## Alternatives & Future

- **Per-edge elevation columns** (`dz_fwd`, `dz_rev` on the edges table) would precompute the
  hot loop, but they need the same backfill, a second consistency problem (edge Δz vs vertex
  elevations), and they bake the weights into data. Rejected; the per-relaxation cost is
  ~10 flops.
- **Store the weighted cost in a generated/extra column** and let the repo `SELECT` it: fast,
  but it silently changes the meaning of a column pgRouting also reads, and it makes weight
  tuning a data migration. Rejected.
- **Region-scoped elevation tables** (a DEM raster per region, `ST_Value` at query time):
  the right long-term shape for plan 06's multi-city stack, but it puts a raster join in the
  graph-build path for every region. Deferred until a second city exists; note it in plan 06.
- **Real-time elevation lookup** (an external API per pin) — no. Routing is a hot path and
  would inherit an external dependency in the graph build.

## Files to Modify

- `internal/database/migrations/015_vertex_elevation.up.sql` *(new)*
- `internal/database/migrations/015_vertex_elevation.down.sql` *(new, documentation only)*
- `internal/config/config.go` — `RoutingElevation` struct + 5 env reads via `getFloat`/`getEnv`;
  comment on the dead `DEMFilePath`.
- `internal/repository/navigation_repo.go` — `roadNode.EleM *float64`; coverage accounting;
  `weights` decided in `roadGraph()`; `GetShortestPath` uses `RouteWithWeights` +
  `AggCost = p.Meters`; `NewNavigationRepo(db, cfg)`.
- `internal/repository/pgrouting_repo.go` — one line (`NewNavigationRepo(db, cfg)`) + the
  elevation/pgrouting warning in the factory.
- `internal/repository/navigation_elevation_integration_test.go` *(new, integration-tagged)*
- `internal/config/config_test.go` *(new or extended — untagged env-parsing tests)*
- `.env.example` — the five vars, commented as "off by default, see api_plans/elevation".
- `AGENTS.md` — one row in the server-config table + the "restart after elevation backfill"
  note next to env fact 5.
