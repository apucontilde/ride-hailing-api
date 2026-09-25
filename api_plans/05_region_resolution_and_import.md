# Plan: Region resolution + region-scoped import

Give `NavigationRepository` the ability to answer "which region owns this pin?" and teach
the importer to load/refresh ONE region at a time. The resolver is the **position → region
loader**: a rider's or driver's coordinates select the region (and, with plan 06, the
datasource pool) that serves their request — stateless, one endpoint, no app change. The
resolver keeps working through plan 06 (multi-city single-stack); this plan alone delivers
the first two-region setup (city vs country) with an honest fallback when a pin has no
coverage. Intercity is deferred (plan 07 stub).

## Problem

- Today the endpoint is single-region-by-construction: pins go straight to the graph (native)
  or to the naked pgr tables (plan 03). No notion of "pin not covered by any region" — bad
  UX and soon wrong when a second city is imported.
- `scripts/import-road-network.sh` is a global gate + global TRUNCATE, so loading a second
  region would wipe the first. Must become region-scoped.

## Current State (verified)

- Resolver location: none today. `service/navigation.go` imports `internal/repository` and
  calls `repo.GetShortestPath(...)` directly (`service/navigation.go:25`); `NavigationRepository`
  is defined in `internal/repository` (`navigation_repo.go:22`). Wiring for a resolver goes
  through `internal/router/router.go:32` (plan 03 factory).
- `internal/config/config.go` has `getEnv`, `getInt`, `getDuration` — **no `getFloat`**.
  `PlacesMaxRadiusM` is shoehorned as `float64(getInt(...))`. Plans 05/07 need real float
  envs → add `getFloat(key string, def float64) float64` here (default on empty/invalid).
- `service` has no lng/lat helper. `internal/routing.haversineM` is unexported; **DECIDED**:
  add one exported wrapper `routing.HaversineMeters(lat1, lng1, lat2, lng2) float64` (same
  `R = 6371000.0` constant) so the estimate path and the engine share ONE implementation —
  no copy-paste of the 3-line formula in `service`.
- Import bbox: `download-osm.sh` clips with `-84.50,9.00,-83.50,10.20` (province) and
  `import-road-network.sh` expects the SAME numbers (`:35`). Registry `cr-sj` bbox (plan 04)
  already matches these province values — good, they must stay in sync.
- Import wipes globally: `TRUNCATE road_network_vertices_pgr, road_network_edges_pgr
  RESTART IDENTITY CASCADE` (`import-road-network.sh:314`) and the `COUNT(*) > 0` skip gate
  (`:184`). Neither can survive a second region.

## Solution

### Part 1 — Resolver (Go)

Put resolution in `internal/service` (it is the handler-facing layer and already imports
`internal/repository`; there is NO import cycle — repository does not import service).
`service` defines a narrow interface so unit tests never touch the DB:

```go
type RegionRef struct {
    RegionID    string // registry id, e.g. "cr-sj"
    Level       string // country / state / city
    Parent      string // "" for a country; else parent region id (future intercity seam, plan 07; unused here)
    Default     bool   // registry default_region
    BBox        [4]float64
    Datasource  string // "" = this DB; else a plan-06 datasource_id (separate-DB city)
}
type RegionSource interface {
    RegisteredRegions() ([]RegionRef, error) // registry rows (bbox, level, parent, default, datasource)
    Snap(lat, lng float64, datasource, regionID string) (SnapResult, bool) // KNN within SNAP_RADIUS_M
}
```

`internal/repository` implements both methods WITHOUT importing `service` (Go interfaces are
structural — a repo type just needs matching methods; `var _ service.RegionSource = (*NavigationRepo)(nil)` in the repo file is optional, service-side assertion in `router.go` is enough). Give the resolver an order of operations — **snap-first, then the default-region fallback**:

1. `ResolveRegion(lat, lng)`:
   - Ask `RegionSource.RegisteredRegions` for candidates ordered by nearness of the
     registry bbox (cheapest; covers the country+city case).
   - **Snap-first**: for each candidate in that order, `RegionSource.Snap` (region-scoped
     KNN on THAT candidate's datasource — local pool for `datasource=""`, the plan-06 pool
     otherwise; reject when `distance_m > ROUTING_SNAP_RADIUS_M`) — first candidate with a
     real snap wins. If the pin is outside every region (no candidate, or all snaps miss),
     escalate to the `default_region=TRUE` registry row, then re-snap; if still no snap →
     no coverage.
   - Return the **single winning region**: `{regionID, datasource, snapVertexID,
     snapDistanceM}` — the position → region → datasource load, resolved in ONE lookup
     (plan 06 Part 1 only adds the graph/pool indirection; resolution logic is unchanged).
   - This is strictly better than raw pin-in-bbox containment: a pin a few meters outside
     SJ's bbox still routes (SJ's snap covers it) instead of appearing "not covered".
   - (No parent-chain escalation: the ancestor hierarchy is the DEFERRED intercity seam —
     plan 07. Resolution deliberately returns exactly one region.)

`ROUTING_DEFAULT_REGION` env (new, `config.go`, `getEnv`): override which registry row is
"default" for the no-coverage fallback (a country row when a city import replaces SJ as
default).

### Part 1b — Single-stack dispatch (position-loads the region AND its pool)

This plan keeps ONE `*sqlx.DB` (local registry + local regions). Plan 06 adds separate-DB
cities; the ONLY resolver change is that `RegisteredRegions()` already carries
`RegionRef.Datasource`, and the repo/router holds `map[datasourceID]*sqlx.DB` pools (default
= local DB). Nothing in `service` or the endpoint changes — position-driven loading is the
same code path whether the region is in the local DB or across a pool boundary (verified by
plan 06's integration test: two datasources on one stack, pins on each side resolve to their
own pool).

### Part 2 — Fallback semantics (service, NOT handler)

`service/navigation.go` — when `ResolveRegion` yields no covered region AND no snap:

- **Do NOT return HTTP 422.** That status is reserved for malformed/missing params
  (`handler/platform.go` 422 path; GET non-numeric 422). No-coverage is a *data* gap, not a
  parse error.
- Return an **estimate**: HTTP 200 straight-line haversine between pins, `total_duration_s =
  distance / 11` (same constant the engine uses), plus a new additive response field
  `is_estimate: true` (Dart `RideEstimatesResponse`-compatible JSON object gains a bool; the
  two apps keep their existing fallback-to-straight-line for `500`).

### Part 3 — Region-scoped import (shell + psql)

Rewrite `scripts/import-road-network.sh`:

- `--region <registry_id>` (default `cr-sj`): the ONLY importable unit. Global `TRUNCATE
  ... RESTART IDENTITY CASCADE` (`:314`, `:346`) becomes **region-scoped DELETE**
  `WHERE region_id = :region`, and the eight-table global wipe is GONE. FK delete order on
  the 008 tables (composite FK from plan 04): `DELETE FROM road_edges WHERE region_id = ...`
  BEFORE `DELETE FROM road_vertices WHERE region_id = ...`. The pgr tables have no FKs so
  their order is free; do them first for symmetry.
- `--datasource <id>` (default "", local DB): target ANOTHER Postgres for this region's
  rows (plan 06). The pipeline connects to that datasource for the region's tables, then
  upserts the registry (bbox + datasource) in the LOCAL DB. Passwords via env/pgpass, and
  the datasource row must already exist (ops provisioning). Every wipe/insert for the region
  is scoped to THAT datasource — a separate-DB city's import never touches the local DB's
  routing tables.
- Global gate (`COUNT(*) > 0` skip, `:184`) becomes per-region: skip a region **only if that
  region already has data AND not `--force`** (`SELECT count(*) FROM road_network_edges_pgr
  WHERE region_id = :region`; an existing global `brute` `--force` flag is the trigger).
  `make import-osm-force` (`make import-osm`'s target runs the script unflagged) already maps
  to `./scripts/import-road-network.sh --force` — the script gains `--region`/`--force`
  together (no `--force-anyway`; keep the existing flag name).
- Register/self-document the region BEFORE importing (upsert into `routing_regions` defaulting
  `bbox_*` from a `ST_Extent` of the incoming data; the admin bbox for a NEW city must be
  given via `--bbox` and is authoritative for clipping; on upsert, refresh bbox from
  `ST_Extent` so registry stays live).
- Emit per-region partial GIST + composite btree indexes (plan 04 left those as cr-sj-only;
  importer creates the same for each new region).
- **Sizing rule** (prevents OOM/slow on big extracts): before import, if the clipped extract
  is a country or larger than ~300 MB, split with `osmium fileinfo` + `osmium extract`
  polygon into per-region chunks and warn (do NOT fail) — scripted note, not a hard gate.

## Verification

1. `docker compose up -d`; `make import-osm` on a fresh DB with plan 04's schema → all rows
   `region_id='cr-sj'`; `routing_regions` shows cr-sj bbox refreshed from ST_Extent (≈
   province box).
2. Import a SECOND synthetic region (`--region cr-lc`, tiny ~1 km² OSM extract or a civil
   generated one) → co-exists next to cr-sj data; `SELECT count(*) ... WHERE region_id` shows
   both; trash the synthetic one via `./scripts/import-road-network.sh --force --region cr-lc`
   (Makefile targets don't forward `--region` args; the script is the arg-bearing entrypoint).
   Optionally repeat with `--datasource <id>` targeting a second PG (plan 06's setting).
3. Resolver behavior:
   - pin inside SJ → resolves `cr-sj`, snap vertex returned.
   - pin 200 m outside SJ bbox but within SJ snap reach... (expected snap) → still `cr-sj`.
   - pin in the Pacific with no region → estimate path, HTTP 200, `is_estimate:true`,
     distance = haversine straight line, duration = /11.
   - malformed `&from_lat=` → still HTTP 422 (parse error, unchanged).
4. `go test ./...` green (resolver is table-driven against a fake `RegionSource`).

## Decisions Recorded

- **Snap-first beats bbox-containment** for both correctness (border pins) and fallback
  (default region).
- **Position is the load key.** Resolution == "which region (+ datasource) serves these
  coords?" — one lookup, stateless, rider/driver app unchanged; far-away cities are separate
  full deploys resolved at the edge, never via a cross-stack DB call (plan 06 Part 2).
- **Single winning region, no ancestor chain.** The parent hierarchy is the deferred
  intercity seam (plan 07); resolution returns one region and nothing else.
- **Estimate ≠ 422.** typeof discussion closed; additive `is_estimate` field, zero handler
  changes required beyond that additions in `service` (handler sees only the repo contract).
- `haversine` helper: prefer exporting tiny wrapper `routing.HaversineMeters(...)`; keep `R =
  6371000` constant identical to the engine's.

## Files to Modify

- `internal/config/config.go` — `getFloat(key string, def float64)`, `ROUTING_DEFAULT_REGION`.
- `internal/service/navigation.go` — `RegionSource` interface (registry + region-scoped snap),
  resolver + estimate fallback + `is_estimate` payload; **imports `internal/routing` for
  `HaversineMeters`** (no cycle: routing imports no internal packages).
- `internal/service/regions_test.go` *(new)* — fake `RegionSource`, default-region fallback,
  no-coverage fallback.
- `internal/routing/routing.go` — exported `HaversineMeters` wrapper (same `R = 6371000.0`).
- `internal/repository/navigation_repo.go` — implement `RegisteredRegions` + `Snap`
  (`routing_regions` + region-scoped KNN; structural, no `service` import).
- `scripts/import-road-network.sh` — region-scoped gate/wipe(`DELETE`)/import/register/
  indexes + `--datasource`.
- `scripts/download-osm.sh` — accept an optional region arg for `--bbox` (default unchanged).
- `Makefile` — keep `import-osm`/`import-osm-force`; document that region flags go to the
  script directly (e.g. `./scripts/import-road-network.sh --region cr-lc`).