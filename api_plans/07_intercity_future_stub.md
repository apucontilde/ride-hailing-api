# Plan: Intercity future stub — DEFERRED, do not build now

Intercity routing (a path BETWEEN cities) is deliberately deferred and will be revisited
later. This file is the single home for that intent. **Nothing here is built by the current
series** (04 region index → 05 position resolution+import → 06 multi-city single-stack); it
must not interfere with, or block, the region abstraction / within-city routing work.

## Status: DEFERRED

- Trips are always WITHIN one region (plan 06). There is **no** cross-city path.
- **Not built, by design:** ports/overlay schema, `component` on pgr edges, any
  `IntercityRouter` interface, ancestor-chain escalation in the resolver, overlay detour
  penalties, the pgRouting↔native hybrid switch.
- **Prep that already exists and cannot interfere** (kept because it is schema-grade and free):
  - `routing_regions.level` (`country/state/city`) + `parent_region` FK (plan 04) — a city
    knows its parent. **No active code path consumes the hierarchy**; resolution returns one
    winning region (plan 05).
  - Plan 05's single-best-region fallback and the no-coverage → HTTP 200 estimate — these
    are the intercity future's graceful-degradation boundary, and they are already tested.
  - Plan 03's pgRouting measurements (per-call cost scales with region edges; contraction
    blocked on pgRouting 4.0.1) — the future intercity plan's engine budget lives there.

## What the active series deliberately does NOT do

- Plan 05's resolver returns the **single winning region** — no parent-chain escalation.
- Plan 06's native graphs are per-region and never chained; no leg tracing exists.
No behavior in 04–06 depends on this stub being implemented in any way.

## Deferred design register (one-liners so the idea survives)

- **Ports**: explicit jump locations between a city layer and its parent, matched by
  coordinates (ids are per-extract sequential, never shared across layers).
- **Leg engine**: per-leg region-local dijkstras `C1 → parent → C2`, with a cost-shifted
  multi-source port selection (deterministic — no pair enumeration).
- **Fallback posture**: single-best-region then estimate; assert-then-fallback on leg seams
  (never fabricate a mid-route straight line).
- **Engine cost model**: pgRouting fixed ~O(region edges) per call (plan 03 numbers);
  contracted-core routing needs a validation gate (component count == 1, neighborhoods in,
  micro-paths out) or a pgRouting upgrade (no `pgr_contract_expand` in 4.0.1).
- **Cross-datasource legs** (plan 06 separate-DB case): the three-phase trace needs BOTH
  layers' port rows in one query — decide a "gateway leg" only if a real intercity route
  ever spans separate datasources.

---

## Appendix — ARCHIVED design detail (overlay ports + intercity planner, 2026-09)

Preserved verbatim-trimmed so the later revisit starts from the prior design rather than
blank. Revisit decision, taste and facts, not authority.

### Archived A — overlay ports schema (was plan 06)

A **city network overlays** a country/state network: shared OSM locations (same node exists
in both layers at identical coords, but with layer-local sequential ids), the city's edges
added on top, and explicit **ports** — the only legal jump points between layers.

- Vertex/edge ids are **per-extract SEQUENTIAL** (verified live in plan 02: SJ fills `1..N`);
  two extracts of the same area number the same locations DIFFERENTLY. Ports match by
  COORDINATES (`abs(dlat) < 1e-6 AND abs(dlng) < 1e-6`), each row storing the location once
  plus the vertex id in EACH layer.
- DDL (migration 014, not created):
  ```sql
  CREATE TABLE IF NOT EXISTS routing_ports (
    port_id           BIGSERIAL PRIMARY KEY,
    overlay_region    TEXT NOT NULL REFERENCES routing_regions(region_id),
    parent_region     TEXT NOT NULL REFERENCES routing_regions(region_id),
    port_lat          DOUBLE PRECISION NOT NULL,
    port_lng          DOUBLE PRECISION NOT NULL,
    overlay_vertex_id BIGINT NOT NULL,
    parent_vertex_id  BIGINT NOT NULL,
    UNIQUE (overlay_region, parent_region, port_lat, port_lng)
  );
  ALTER TABLE road_network_edges_pgr ADD COLUMN IF NOT EXISTS component INTEGER;
  ALTER TABLE road_network_edges_pgr ADD COLUMN IF NOT EXISTS highway_type TEXT;
  ```
- Ports are populated by the importer (`--overlay <parent>`), refreshed on re-import
  (DELETE then INSERT for that overlay). Component (connected-component label, union-find at
  import, per-layer) keeps the planner from crossing disconnected clusters; `highway_type`
  is copied from the `ways` pipeline so edges_sql can weight by road class.
- One-way weighting (`reverse_cost`) deliberately deferred — the pgr layer routes undirected.
- Importer VERIFY: during an overlay import the parent's rows must NOT be dropped (additive).

### Archived B — intercity planner (was plan 07)

Chain region-local `pgr_dijkstra` runs through overlay ports into one polyline. ONE optional
capability interface keeps `MockNavigationRepo` (only `GetShortestPath`) green:

```go
type IntercityRouter interface {
    RouteIntercity(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error)
}
```

- Optional-interface contract: `service` tries `r, ok := repo.(IntercityRouter)`,
  falls back to the plan-05 single-best-region path, then the estimate.
- **Three-phase trace** for pins A (city C1, parent P) / B (city C2, child of P):
  1. snap A→`a_city` (C1 layer); snap B→`b_city` (C2 layer). A/B that fail to snap are "on P".
  2. `PE` = ports of C1, `PN` = ports of C2 (per-layer vertex ids via `overlay_vertex_id` /
     `parent_vertex_id`). Empty either set → estimate.
  3. leg1 = C1 dijkstra `a_city` → all PE (multi-target); leg2 = P **multi-source dijkstra**
     seeded at cost `d1(pe)` per surviving PE member, settle ANY `pn∈PN` — solves
     `min(exit,enter) of d1+dP` exactly in ONE search, winning `pe*` from the predecessor
     chain; leg3 = C2 dijkstra `pn*` → `b_city`. Broken chain → estimate, never fabricate.
  4. stitch: legs share the port LOCATION exactly (both layers store identical coords);
     assert `leg[i].last == leg[i+1].first` within 1e-8; cost = Σ agg_cost, duration = /11,
     polyline flattened, endpoints pinned.
- Config that was proposed: `ROUTING_CROSS_REGION` (bool, default true when ports exist),
  `ROUTING_OVERLAY_DETOUR` (1.2), `ROUTING_ESTIMATE_DETOUR` (1.3) — all `getFloat`.
- Region-scoped `Route(regionID, startVid, endVid)` (`edges_sql WHERE region_id=$1`,
  component-filtered) in `internal/routing`; multi-source = seed set + settle-on-target.
- Tests: integration RESOLUTION/CHAINING/FALLBACK table-driven; service-level fake
  `IntercityRouter` asserting C1→P→C2 phase order + deterministic port selection.
- Live acceptance: `from=9.93,-84.07` → `to=10.0,-84.5` ⇒ polyline with ≥ 3 distinct bends
  (crossed the boundary), endpoints pinned; without overlay data ⇒ 200 estimate.
- Engine cost model for the planner (inherited from plan 03, valid when revisited):
  per-leg cost is O(region edges); contracted core gets 20–27 ms only behind the validation
  gate (component count == 1, neighborhoods in, micro-paths out) or a pgRouting upgrade;
  keep the native↔pgr hybrid `~X km` switch decision there.