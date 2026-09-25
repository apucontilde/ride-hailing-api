-- 013_region_schema.down.sql
-- DOCUMENTATION ONLY: migrate.go embeds and executes ONLY *.up.sql, so this
-- file is never run. It records the exact reverse of 013_region_schema.up.sql
-- for a manual rollback on a dev database (wrap in BEGIN ... ROLLBACK to dry-run
-- it against a live volume).
--
-- Statement order is load-bearing, and it mirrors the up migration in reverse:
--   1. region-scoped indexes go first (they reference region_id);
--   2. the composite 008 FKs must be dropped BEFORE road_vertices goes back to
--      PRIMARY KEY (id) -- otherwise the re-added single-column FKs would have
--      no unique key to reference and Postgres raises 42830;
--   3. only then can road_vertices restore PRIMARY KEY (id) and the
--      single-column source/target FKs come back;
--   4. region_id columns are dropped last.
-- A region wipe must still delete road_edges rows BEFORE road_vertices rows
-- (the FKs keep their default NO ACTION).

DROP INDEX IF EXISTS rn_edges_tgt_region;
DROP INDEX IF EXISTS rn_edges_src_region;
DROP INDEX IF EXISTS rn_vertices_gist_region;

-- pgr graph back to a single-column id PK. The composite PK kept the original
-- <table>_pkey name, because the up migration dropped and re-added it in one
-- statement.
ALTER TABLE road_network_edges_pgr    DROP CONSTRAINT IF EXISTS road_network_edges_pgr_pkey,
    ADD PRIMARY KEY (id);
ALTER TABLE road_network_vertices_pgr DROP CONSTRAINT IF EXISTS road_network_vertices_pgr_pkey,
    ADD PRIMARY KEY (id);

-- 008 tables: drop the composite FKs, restore the single-column PKs, restore the
-- original single-column FKs.
ALTER TABLE road_edges DROP CONSTRAINT IF EXISTS road_edges_source_fkey;
ALTER TABLE road_edges DROP CONSTRAINT IF EXISTS road_edges_target_fkey;

ALTER TABLE road_vertices DROP CONSTRAINT IF EXISTS road_vertices_pkey,
    ADD PRIMARY KEY (id);
ALTER TABLE road_edges    DROP CONSTRAINT IF EXISTS road_edges_pkey,
    ADD PRIMARY KEY (id);

ALTER TABLE road_edges ADD CONSTRAINT road_edges_source_fkey
    FOREIGN KEY (source) REFERENCES road_vertices (id);
ALTER TABLE road_edges ADD CONSTRAINT road_edges_target_fkey
    FOREIGN KEY (target) REFERENCES road_vertices (id);

ALTER TABLE road_network_edges_pgr   DROP COLUMN IF EXISTS region_id;
ALTER TABLE road_network_vertices_pgr DROP COLUMN IF EXISTS region_id;
ALTER TABLE road_edges                DROP COLUMN IF EXISTS region_id;
ALTER TABLE road_vertices             DROP COLUMN IF EXISTS region_id;

-- Registry (datasource FK first, then the tables themselves).
ALTER TABLE routing_regions DROP COLUMN IF EXISTS datasource;
DROP TABLE IF EXISTS routing_datasources;
DROP TABLE IF EXISTS routing_regions;
