# Plan: Region schema + routing regions registry (013 migration)

Add a region dimension to the routing tables so the API can serve ANY place in the world:
the same DB (or, with plan 06, a cluster of DBs) holds multiple disjoint city/small-country
road networks, and a registry names, bounds and locates them. This is the schema foundation
plans 05 (position resolution) and 06 (multi-city single-stack) build on; intercity is
deferred (plan 07 stub). No Go code changes beyond the migration; the engine (plan 03) keeps
routing on the single legacy region.

## Problem

- `road_network_edges_pgr` / `road_network_vertices_pgr` (011) hold ONE network; `id` is a
  plain `BIGINT PRIMARY KEY` **with no sequence** (`011:8,15`). Vertex ids are copied from
  `ways_vertices_pgr.id` = **per-extract SEQUENTIAL ids** (verified live in plan 02: SJ fills
  `1..152665`; edge `gid` fills `1..183372`; 008 `road_vertices` re-sequences identically) —
  so BOTH vertex and edge ids **collide across extracts** of the same area. The import
  gate/truncate (`scripts/import-road-network.sh`, below) operate globally.
- 008 tables (`road_vertices`, `road_edges`) are the OSM-derived source of truth the importer
  writes (`road_vertices.id` BIGSERIAL, `road_edges.id` BIGSERIAL + `source`/`target` FKs to
  `road_vertices(id)`). They too need region identity so pgr tables can be rebuilt from a
  region's own data without clobbering others.
- pgRouting has no table-level "dataset" concept: the only clean way to scope queries is a
  `region_id` column on every routing table + index prefixes. Plan 03's naked
  `pgr_dijkstra('SELECT ... road_network_edges_pgr ...')` must become region-scoped.

## Current State (verified)

- `scripts/import-road-network.sh` — global gate (`COUNT(*) > 0` skip, `:184`), global
  `TRUNCATE road_network_vertices_pgr, road_network_edges_pgr RESTART IDENTITY CASCADE`
  (`:314`), single-city bbox (`-84.50,9.00,-83.50,10.20`, the **province** clip, `:35`).
  Copies vertices from `ways_vertices_pgr` (id, the_geom) and edges from `ways` (`gid,
  source, target, length_m`) — edge cost is the road length in **meters**.
- `internal/database/migrations/008_create_road_network.up.sql` — `road_vertices(id BIGSERIAL
  PK, geom, cnt, elevation_m)`, `road_edges(id BIGSERIAL PK, source BIGINT REFERENCES
  road_vertices(id), target BIGINT REFERENCES road_vertices(id), geom, length_m, cost,
  reverse_cost, name, highway_type, ...)`. **`road_edges` has FKs referencing single-column
  `road_vertices(id)`**; `highway_type` lives only here (reserved for the deferred intercity
  seam, plan 07). No region column anywhere.
- `road_network_edges_pgr` (011) columns: `id, source, target, cost` only — **no
  `the_geom`**, so no GIST index is possible on it (the plan-03 KNN is vertices-only). The
  vertices GIST is `idx_road_network_vert_geom` (`011:21`).
- Registry bbox for the seed MUST be the **province** clip (matches repo data), NOT a hand
  metro box (~9.90–9.98 / −84.15..−84.03 which fits only SJ's imported core).
- Imports run as `psql`/`osm2pgrouting` via shell (`scripts/import-road-network.sh`), not the
  Go migration system — migrations only ADD empty region tables/indexes; data flows through
  the importer (plan 05).

## Solution

New migration `internal/database/migrations/013_region_schema.up.sql` (append-only — never
rewrite 011/012). All statements idempotent (`IF NOT EXISTS`), no data loss on existing
volumes (legacy rows get `region_id = 'cr-sj'` — the region every existing deploy operates
as today):

```sql
-- 013_region_schema.up.sql

CREATE TABLE IF NOT EXISTS routing_regions (
  region_id       TEXT PRIMARY KEY,
  level           TEXT NOT NULL CHECK (level IN ('country','state','city')),
  name            TEXT NOT NULL,
  parent_region   TEXT REFERENCES routing_regions(region_id),
  bbox_lon_min    DOUBLE PRECISION NOT NULL,
  bbox_lat_min    DOUBLE PRECISION NOT NULL,
  bbox_lon_max    DOUBLE PRECISION NOT NULL,
  bbox_lat_max    DOUBLE PRECISION NOT NULL,
  default_region  BOOLEAN NOT NULL DEFAULT FALSE,   -- resolver fallback (plan 05)
  CHECK (bbox_lon_min <= bbox_lon_max AND bbox_lat_min <= bbox_lat_max)
);

INSERT INTO routing_regions
  (region_id, level, name, parent_region, bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max, default_region)
VALUES
  ('cr',  'country','Costa Rica', NULL,            -85.95, 7.98,  -82.55, 11.22, FALSE),  -- rough national box
  ('cr-sj','state', 'San José',   'cr',            -84.50, 9.00,  -83.50, 10.20, TRUE)
ON CONFLICT (region_id) DO NOTHING;

-- multi-city single-stack (plan 06): a region's NETWORK DATA may live in a different
-- Postgres than the one this registry lives in. NULL datasource = "this database" (the
-- default, keeps the plan-04/05 mechanics intact); a value points at a routing_datasources
-- row and the CLI/API routes THAT region's queries to that pool. bbox stays local (it drives
-- position->region candidacy without ever querying the remote datasource).
CREATE TABLE IF NOT EXISTS routing_datasources (
  datasource_id TEXT PRIMARY KEY,
  host          TEXT NOT NULL,
  port          INTEGER NOT NULL,
  dbname        TEXT NOT NULL,
  db_user       TEXT NOT NULL,          -- password NEVER stored here (env / pgpass only)
  label         TEXT
);
ALTER TABLE routing_regions ADD COLUMN IF NOT EXISTS datasource TEXT
  REFERENCES routing_datasources(datasource_id);   -- NULL default = local DB
```

Then region-scope the routing graph tables. Each PK swap is a SINGLE `ALTER TABLE ... DROP
CONSTRAINT <real-name>, ADD PRIMARY KEY (...)` — one statement, no partial-failure window.
Real PK constraint names (Postgres default `<table>_pkey`): `road_network_vertices_pgr_pkey`,
`road_network_edges_pgr_pkey`, `road_vertices_pkey`, `road_edges_pkey`.

```sql
ALTER TABLE road_network_vertices_pgr
  ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';
ALTER TABLE road_network_edges_pgr
  ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';

-- composite PK: (region_id, id). BOTH vertex and edge ids are per-extract sequential
-- (plan 02 verified) and collide across extracts, so region scoping is required on both.
ALTER TABLE road_network_vertices_pgr DROP CONSTRAINT IF EXISTS road_network_vertices_pgr_pkey,
  ADD PRIMARY KEY (region_id, id);
ALTER TABLE road_network_edges_pgr DROP CONSTRAINT IF EXISTS road_network_edges_pgr_pkey,
  ADD PRIMARY KEY (region_id, id);

-- per-region partial GIST on VERTICES only (the_geom exists only there). The 011 full
-- index idx_road_network_vert_geom remains; the partial one wins for region-scoped KNN.
CREATE INDEX IF NOT EXISTS rn_vertices_gist_region ON road_network_vertices_pgr
  USING gist (the_geom) WHERE region_id = 'cr-sj';
-- ...and per-region partial GISTs for EVERY region the importer registers (plan 05).

-- source/target indexes become composite (region_id, source)/(region_id, target):
CREATE INDEX IF NOT EXISTS rn_edges_src_region ON road_network_edges_pgr (region_id, source);
CREATE INDEX IF NOT EXISTS rn_edges_tgt_region ON road_network_edges_pgr (region_id, target);
```

008 source-of-truth tables: add `region_id` and swap PKs, and **REBUILD the two FKs** that
single-column `road_vertices(id)` references (once the PK is composite, `id` alone is no
longer a unique key an FK can target — Postgres rejects it):

```sql
ALTER TABLE road_vertices ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';
ALTER TABLE road_edges    ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';

ALTER TABLE road_vertices DROP CONSTRAINT IF EXISTS road_vertices_pkey,
  ADD PRIMARY KEY (region_id, id);
ALTER TABLE road_edges    DROP CONSTRAINT IF EXISTS road_edges_pkey,
  ADD PRIMARY KEY (region_id, id);
-- FK must now reference the composite key; drop old + add scoped equivalents:
ALTER TABLE road_edges DROP CONSTRAINT IF EXISTS road_edges_source_fkey,
  ADD FOREIGN KEY (region_id, source) REFERENCES road_vertices (region_id, id);
ALTER TABLE road_edges DROP CONSTRAINT IF EXISTS road_edges_target_fkey,
  ADD FOREIGN KEY (region_id, target) REFERENCES road_vertices (region_id, id);
```

Region-scoped DELETE in the importer (plan 05) must honour this FK order: delete
`road_edges` rows BEFORE `road_vertices` rows of the same region (or rely on the composite FK
`ON DELETE` default `NO ACTION` and order the statements explicitly).

`routing_regions` level CHECK: country/state/city — disjoint sibling cities today (plan 06);
the `parent_region` hierarchy is retained as the FUTURE intercity seam (plan 07 stub), unused
by any current path. `default_region` marks the legacy region the native engine keeps using
and the resolver's fallback.

## Verification

1. `docker compose up -d` (DB up, migrations 012→013 apply on boot).
2. `psql`:
   `SELECT region_id, level FROM routing_regions ORDER BY 1` → `cr`,`cr-sj` (cr-sj default TRUE).
   `\d road_network_edges_pgr` → composite PK `(region_id,id)` + region_id column present.
   `SELECT count(*) FROM road_network_edges_pgr WHERE region_id='cr-sj'` → pre-import 0;
   after plan 05's region-scoped import: all rows have `region_id='cr-sj'`.
3. `make import-osm` still works end-to-end (importer emits region_id for the legacy region;
   plan 05 rewrites the global gate/truncate).
4. `BenchmarkRoutePGRouting` (plan 03) still runs; region-scoped KNN query returns the same
   nearest vertex as the unscoped pre-013 one (spot-check two coords).
5. `go test ./...` green (no Go changes in this plan).

## Decisions Recorded

- **Collision handling — no `id=NULL` trick.** `id` columns are plain PKs (011) or
  BIGSERIAL (008); a `NULL` insert violates `NOT NULL` either way (sequences only fire when
  the column is OMITTED or uses `DEFAULT`). The composite `(region_id, id)` PK is what makes
  per-extract `gid`s (pgr edges) and sequence ids (008 `road_edges`) safe to collide
  *across regions* — the importer just inserts its ids as usual inside its `region_id`,
  relying on the PK to forbid intra-region dups. Do NOT try to make `id` globally unique.
- **008 FK must be rebuilt for the composite PK** (addressed in the DDL above); the FK
  `source/target → road_vertices(id)` cannot survive a composite PK otherwise.
- **`default_region`** flag not a foreign key to a value in the table itself — it is a soft
  preference (`ROUTING_DEFAULT_REGION` env reads it, plan 05).
- **Region data may be split across databases, not just across rows.** `routing_datasources`
  + `routing_regions.datasource` (above) let ONE stack serve NEARBY cities that live in
  separate Postgres instances (plan 06: position-loads the right datasource + pool). The
  composite `(region_id, id)` PK dimension and the datasource dimension are orthogonal:
  same-DB regions (this plan's default) and separate-DB regions both keep the SAME tables,
  the only change is which pool the repo queries for that region's `region_id`.
- **Far-away cities are separate full deploys** (own API group + PG + Redis), never a remote
  DB call from a foreign stack; the registry/datasource machinery is for the ONE-stack,
  many-cities case. See plan 06 Part 2.
- **Legacy semantics preserved**: existing volumes keep routing perfectly on `cr-sj` with the
  default column value; nothing about the native/nodes paths (plans 01/03) observes regions
  until plan 05's resolver is wired in.

## Alternatives & Future

- `region_id` as a real FK to `routing_regions` — deferred; TRUNCATE/import ordering gets
  awkward with per-region wipe, and `default_region` softness argues against hard FK now.
- **Layered/overlay regions** (a city network on a country network — the DEFERRED intercity
  seam, plan 07) reuse `region_id` with `level='city'` + `parent_region` pointing at the
  country; the schema already supports both disjoint (sibling cities) and layered (parent)
  topologies via the single `parent_region` FK. Only the disjoint topology is exercised by
  plans 05/06.

## Files to Modify

- `internal/database/migrations/013_region_schema.up.sql` *(new)* — everything above.
- (No Go/importer changes here; plan 05 does the importer rewrite + Go resolver repo.)

## EXECUTED (2026-09-25)

Merged into `main` (commit `324925c`); migration `013_region_schema` applied live to the
CR DB (commits `schema_migrations` at 013), re-applied idempotently against the live volume
(all `IF NOT EXISTS` / `DROP IF EXISTS`; NOTICEs only), and the 152,665-vertex / 183,372-edge
SJ import survived with `region_id='cr-sj'` intact.

- **Required statement-order fix vs the schema above**: the 008-table PK swaps must DROP
  `road_edges_source_fkey`/`road_edges_target_fkey` BEFORE `road_vertices_pkey` (Postgres
  `2BP01` refuses to drop a PK that a foreign key depends on), then re-add the composite
  `(region_id, source|target) → road_vertices(region_id, id)` FKs after. The first boot on a
  fresh volume hit `2BP01` and rolled back atomically; the fixed file applied clean.
- Constraint names match the plan's: `road_network_vertices_pgr_pkey`,
  `road_network_edges_pgr_pkey`, `road_vertices_pkey`, `road_edges_pkey`, plus the reused
  `road_edges_source_fkey` / `road_edges_target_fkey` names.
- **Down-file caveat** (docs-only): the composite 008 FKs must be dropped before restoring
  `road_vertices PRIMARY KEY (id)` or Postgres raises `42830`.
- The composite FKs are `IMMEDIATE` (not `DEFERRABLE`) — this forced plan 05's importer to
  insert `road_vertices` before `road_edges`.
- `routing_regions` now seeds `cr` (country, bbox the national box) + `cr-sj` (state, parent
  `cr`, bbox the province clip, `default_region=TRUE`), and `routing_datasources` + the
  `routing_regions.datasource` column exist for plan 06 — both exercised by plan 05's tests.