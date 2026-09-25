-- 013_region_schema.up.sql
-- Region dimension for the routing tables (api_plans/04). The same database
-- (or, from plan 06, a CLUSTER of databases) can hold several disjoint city /
-- small-country road networks; the registry below names, bounds and locates
-- them. Plans 05 (position -> region resolution) and 06 (many cities, one
-- stack) build on this; intercity stays deferred (plan 07).
--
-- Append-only: 011/012 are never rewritten. Every statement is idempotent and
-- valid in every reachable state, so the runner's non-atomic multi-statement
-- exec (migrate.go) is SAFE -- an interrupted run re-converges. Do NOT wrap in
-- BEGIN: an atomic failure here would brick the DB.
--
-- No data loss on existing volumes: legacy rows get region_id = 'cr-sj', the
-- region every existing deploy already operates as (default_region). The
-- constant DEFAULT makes the column add a metadata-only operation, so the live
-- SJ import (152k vertices / 183k edges) is preserved as-is.

-- ---------------------------------------------------------------------------
-- Region registry
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS routing_regions (
    region_id       TEXT PRIMARY KEY,
    level           TEXT NOT NULL CHECK (level IN ('country', 'state', 'city')),
    name            TEXT NOT NULL,
    parent_region   TEXT REFERENCES routing_regions(region_id),
    bbox_lon_min    DOUBLE PRECISION NOT NULL,
    bbox_lat_min    DOUBLE PRECISION NOT NULL,
    bbox_lon_max    DOUBLE PRECISION NOT NULL,
    bbox_lat_max    DOUBLE PRECISION NOT NULL,
    default_region  BOOLEAN NOT NULL DEFAULT FALSE,   -- resolver fallback (plan 05)
    CHECK (bbox_lon_min <= bbox_lon_max AND bbox_lat_min <= bbox_lat_max)
);

-- Seed: the country box plus the legacy region. cr-sj's bbox is the PROVINCE
-- clip (-84.50,9.00,-83.50,10.20), NOT a hand-drawn metro box -- it must match
-- what scripts/import-road-network.sh actually imports (plan 04 spec).
INSERT INTO routing_regions
    (region_id, level, name, parent_region, bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max, default_region)
VALUES
    ('cr',   'country', 'Costa Rica', NULL, -85.95, 7.98, -82.55, 11.22, FALSE),  -- rough national box
    ('cr-sj', 'state',  'San José', 'cr', -84.50, 9.00, -83.50, 10.20, TRUE)
ON CONFLICT (region_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Datasources (multi-city single-stack, plan 06)
-- ---------------------------------------------------------------------------
-- A region's NETWORK DATA may live in a different Postgres than the one this
-- registry lives in. NULL datasource = "this database" (the default, which
-- keeps the plan-04/05 mechanics intact); a value points at a
-- routing_datasources row and the CLI/API routes THAT region's queries to that
-- pool. The bbox always stays local: it drives position -> region candidacy
-- without ever querying the remote datasource.
--
-- The (region_id, id) PK dimension below and this datasource dimension are
-- ORTHOGONAL: same-DB regions (the default) and separate-DB regions keep the
-- same tables; the only difference is which pool the repo queries for that
-- region's region_id.
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

COMMENT ON COLUMN routing_regions.datasource IS
    'NULL = this database; a routing_datasources.datasource_id means the region''s road network lives in that remote Postgres (api_plans/06). Passwords are never stored -- env / pgpass only.';

-- ---------------------------------------------------------------------------
-- Region-scope the pgr graph (011). Composite PK: (region_id, id).
-- ---------------------------------------------------------------------------
-- BOTH vertex and edge ids are per-extract SEQUENTIAL (plan 02 verified: SJ
-- vertices fill 1..152665, edges 1..183372) and therefore collide ACROSS
-- extracts of the same area -- region scoping is required on both sides.
ALTER TABLE road_network_vertices_pgr
    ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';
ALTER TABLE road_network_edges_pgr
    ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';

-- Each PK swap is a SINGLE statement so there is no partial-failure window.
-- Constraint names are the Postgres defaults (<table>_pkey) created by 011/008.
ALTER TABLE road_network_vertices_pgr DROP CONSTRAINT IF EXISTS road_network_vertices_pgr_pkey,
    ADD PRIMARY KEY (region_id, id);
ALTER TABLE road_network_edges_pgr DROP CONSTRAINT IF EXISTS road_network_edges_pgr_pkey,
    ADD PRIMARY KEY (region_id, id);

-- Per-region partial GIST on VERTICES only (the_geom exists only there). The
-- 011 full index idx_road_network_vert_geom remains; the partial one wins for
-- region-scoped KNN. Plan 05's importer creates the equivalent partial GIST for
-- EVERY region it registers.
CREATE INDEX IF NOT EXISTS rn_vertices_gist_region ON road_network_vertices_pgr
    USING gist (the_geom) WHERE region_id = 'cr-sj';

-- source/target lookups become region-scoped: (region_id, source) / (region_id, target).
CREATE INDEX IF NOT EXISTS rn_edges_src_region ON road_network_edges_pgr (region_id, source);
CREATE INDEX IF NOT EXISTS rn_edges_tgt_region ON road_network_edges_pgr (region_id, target);

-- ---------------------------------------------------------------------------
-- Region-scope the 008 source-of-truth tables (what the importer writes)
-- ---------------------------------------------------------------------------
ALTER TABLE road_vertices ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';
ALTER TABLE road_edges    ADD COLUMN IF NOT EXISTS region_id TEXT NOT NULL DEFAULT 'cr-sj';

-- The two 008 FKs referenced single-column road_vertices(id). Once that PK is
-- composite, `id` alone is no longer a unique key an FK may target and Postgres
-- rejects the reference -- so both FKs must be rebuilt against the composite
-- key. They are dropped HERE, before the PK swaps: Postgres refuses to drop
-- road_vertices_pkey while road_edges_source_fkey/road_edges_target_fkey still
-- depend on it (error 2BP01), so drop-then-recreate is the only legal order.
ALTER TABLE road_edges DROP CONSTRAINT IF EXISTS road_edges_source_fkey;
ALTER TABLE road_edges DROP CONSTRAINT IF EXISTS road_edges_target_fkey;

-- Still one statement per table, so there is no partial-failure window.
ALTER TABLE road_vertices DROP CONSTRAINT IF EXISTS road_vertices_pkey,
    ADD PRIMARY KEY (region_id, id);
ALTER TABLE road_edges    DROP CONSTRAINT IF EXISTS road_edges_pkey,
    ADD PRIMARY KEY (region_id, id);

-- Scoped equivalents of the dropped FKs. Postgres reuses the same names (the
-- first column of the constraint names the FK: source / target), so the next
-- pass through this file drops and re-adds them again -- idempotent.
ALTER TABLE road_edges ADD CONSTRAINT road_edges_source_fkey
    FOREIGN KEY (region_id, source) REFERENCES road_vertices (region_id, id);
ALTER TABLE road_edges ADD CONSTRAINT road_edges_target_fkey
    FOREIGN KEY (region_id, target) REFERENCES road_vertices (region_id, id);

-- NOTE for plan 05's region-scoped DELETE: the composite FKs keep the default
-- NO ACTION, so a region wipe must DELETE road_edges rows BEFORE road_vertices
-- rows of the same region.
