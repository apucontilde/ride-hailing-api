-- 012_enable_pgrouting.up.sql
-- One-time convergence for ALL existing volumes + fresh DBs after the image
-- swap to pgrouting/pgrouting:16-3.5-4.0 (api_plans/02).
--
-- Why not just rewrite 011? schema_migrations skips already-applied versions,
-- so a rewritten 011 never re-runs on an existing volume. This migration is
-- the mechanism that converges those volumes (and is a no-op-ish pass on
-- fresh ones).
--
-- Each statement is idempotent and valid in every reachable state (011 stub
-- present, real function present, mixed, none), so the runner's non-atomic
-- multi-statement exec (migrate.go) is SAFE: an interrupted run re-converges.
-- Do NOT wrap in BEGIN — an atomic failure here would brick the DB.

-- (1) purge the demo NYC seed — GEO-GUARDED. After a real import the vertex
-- ids are SEQUENTIAL osm2pgrouting ids (verified: the SJ import fills 1..N), so
-- an id-range purge would DELETE REAL ROWS. The seed's two vertices are the
-- only rows anywhere near NYC, so purge by location ACL; with a real import the
-- DELETE matches nothing. Note: 012 originally purged by id (rev 1) and it
-- deleted two real SJ vertices + one edge on the dev volume — restored by hand,
-- `make import-osm-force` regenerates pristine data.
DELETE FROM road_network_vertices_pgr
WHERE id IN (1, 2)
  AND the_geom IS NOT NULL
  AND ST_DWithin(the_geom::geography,
                 ST_SetSRID(ST_MakePoint(-74.006, 40.7128), 4326)::geography,
                 50000);

-- the demo edge connected the two seed vertices; purge it ONLY when those seed
-- vertices were actually present (removed by the geo-guarded delete above, so no
-- 1/2 remain). A real sequential import keeps ids 1,2 -> this skips, leaving the
-- real edge 100 untouched.
DELETE FROM road_network_edges_pgr
WHERE id = 100
  AND NOT EXISTS (SELECT 1 FROM road_network_vertices_pgr WHERE id IN (1, 2));

-- (2) converge to the REAL extension regardless of state:
--     - a live server did not have pgrouting, so 011's guarded stub may exist -> drop it;
--     - a stale/healthy extension may exist -> drop+recreate restores members;
--     - nothing present -> IF EXISTS / DO as no-op, then create when available.
DROP FUNCTION IF EXISTS public.pgr_dijkstra(text, bigint, bigint, boolean);
DROP EXTENSION IF EXISTS pgrouting CASCADE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pgrouting') THEN
    EXECUTE 'CREATE EXTENSION pgrouting';
  END IF;
END $$;

-- (3) postgis catalog vs new 3.5 libraries on a reused volume: align versions.
-- ALTER EXTENSION ... UPDATE has NO `IF EXISTS` keyword, so guard each one in
-- a DO block (absent extension = no-op; the runner sends the file as one
-- multi-statement string and this is SAFE because the statements are
-- idempotent and independent).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
    ALTER EXTENSION postgis UPDATE;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis_topology') THEN
    ALTER EXTENSION postgis_topology UPDATE;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis_raster') THEN
    ALTER EXTENSION postgis_raster UPDATE;
  END IF;
END $$;