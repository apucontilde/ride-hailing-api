-- 014_vertex_elevation.up.sql
-- Elevation for the NATIVE engine's cost model (api_plans/[elevation]_elevation_column_and_repo_plumb.md).
--
-- - Units: METERS, orthometric height above the EGM96 geoid (what SRTM-class
--   DEMs publish). A constant datum offset cancels in every per-edge delta
--   (cost depends only on dz), but MIXING DEM vintages inside one region
--   creates a real step artifact -- so elevation_source records provenance
--   per vertex and stage 01 (DEM ingest) backfills region-scoped, one DEM at
--   a time.
-- - NULL means "no sample for this vertex" and is NOT the same as 0 (sea
--   level). The repository counts NULLs and falls back to flat routing below
--   the coverage threshold; never coalesce to 0 at write time.
-- - The pgr layer (pgrouting_repo.go) does NOT read this column: pgRouting
--   keeps using road_network_edges_pgr.cost, which stays in meters.
--
-- Idempotent and metadata-only (PostgreSQL >= 11): no table rewrite, no lock
-- beyond a brief ACCESS EXCLUSIVE, safe on the live road_network_vertices_pgr
-- table.

ALTER TABLE road_network_vertices_pgr
  ADD COLUMN IF NOT EXISTS elevation_m    DOUBLE PRECISION;
ALTER TABLE road_network_vertices_pgr
  ADD COLUMN IF NOT EXISTS elevation_source TEXT;

COMMENT ON COLUMN road_network_vertices_pgr.elevation_m IS
  'Meters, EGM96 orthometric. NULL = no sample. Feeds the native engine cost model.';
COMMENT ON COLUMN road_network_vertices_pgr.elevation_source IS
  'Provenance of the sample (e.g. skadi:N09W085). Constant within a region; mixing sources creates a step artifact.';