---
tag: elevation
depends_on: ["pgrouting engine + elevation columns (STATUS.md, landed)"]
status: deferred
---

# pgRouting / native elevation parity (Item C of the retired duration/API-surface plan)

> **Unnumbered** — it depends only on landed capability (the pgRouting engine is wired; the
> `elevation_m` column and cost model are landed), not on any open plan
> (`.opencode/skills/plan-management/SKILL.md`). It replaces Item C of
> `01_[elevation]_duration_and_api_surface.md`, which has been deleted as landed. **Low priority**
> per plan 03's recorded gate: `ROUTING_ENGINE=native` is the permanent production default and
> pgRouting serves only long-haul legs where this divergence does not bite.

## The divergence (already logged, not fixed)

With `ROUTING_ENGINE=pgrouting`, `pgr_dijkstra` reads `road_network_edges_pgr.cost`, which is
**pure meters**, so it returns the flat-optimal route while the native engine returns the
elevation-aware one. Same OD pair, two deployments, two answers. The factory already warns loudly
when `ROUTING_ELEVATION=on` and `ROUTING_ENGINE=pgrouting`
(`internal/repository/pgrouting_repo.go:124-129`) — **keep that warning**; it is the correct action
today.

**Do not** fix this by writing a weighted `cost` into `road_network_edges_pgr`. That column is the
meters contract `total_distance_m`, the fare, and pgRouting's own `agg_cost` all depend on
(STATUS.md invariant: never "fix" `road_network_edges_pgr.cost`).

## The clean fix (when/if parity is wanted)

Costs are computed by a **separate backfill script that is then referenced by `import-osm`** —
not inline in the importer, and not a weighted `cost`.

1. **Migration** (append-only, next free numeric prefix; the `011` table has **no** `reverse_cost`
   — verified `internal/database/migrations/011_create_routing.up.sql:17-22`) adds:
   ```sql
   ALTER TABLE road_network_edges_pgr
     ADD COLUMN IF NOT EXISTS reverse_cost       DOUBLE PRECISION;  -- meters, reverse
   ALTER TABLE road_network_edges_pgr
     ADD COLUMN IF NOT EXISTS cost_ascent        DOUBLE PRECISION;  -- metres + w*ascent, fwd
   ALTER TABLE road_network_edges_pgr
     ADD COLUMN IF NOT EXISTS reverse_cost_ascent DOUBLE PRECISION; -- metres + w*ascent, rev
   ```
   `reverse_cost` and the ascent columns are needed because the reverse direction must be priced
   separately; plan 03 explicitly forbade an `edges_sql` that references a `reverse_cost` that
   does not exist.
2. **Second edges SQL** — an `elevationAwareEdgesSQL` constant beside `edgesSQL`
   (`internal/repository/pgrouting_repo.go:19`), selecting `cost_ascent` / `reverse_cost_ascent`
   with `WHERE cost_ascent IS NOT NULL`, **selected by the same elevation flag** as the native
   path. Add a matching region-scoped variant beside `regionEdgesSQLFmt` (`:52`).
3. **Backfill script** — a new script that computes `reverse_cost` and the ascent costs from the
   vertices' `elevation_m` + the cost weights, idempotent and coverage-gated, **referenced from
   `scripts/import-road-network.sh`** so a fresh import populates it. Run it after
   `make import-elevation` (the importer never writes elevation columns; the graph holds `EleM`
   loaded at boot — restart the API after a backfill).
4. **Verification** — the same OD pair routed through both engines with elevation on, compared,
   and the expected difference documented rather than papered over; a parity tolerance test.

## Why deferred

Plan 03's benchmark gate kept `native` (~163,000× slower on the `hop` workset) and STATUS.md
records native as the permanent default. Parity is therefore a documentation problem now and a
migration problem only if pgRouting ever returns to being a city-hop engine. Until then the
factory warning is the whole deliverable.
