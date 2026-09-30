-- Documentation only: the migration runner executes only *.up.sql (see
-- internal/database/migrate.go). Kept alongside for the record of how to roll
-- back the 014 columns by hand.
ALTER TABLE road_network_vertices_pgr DROP COLUMN IF EXISTS elevation_source, DROP COLUMN IF EXISTS elevation_m;