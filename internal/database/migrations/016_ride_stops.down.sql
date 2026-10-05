-- Documentation only: the migration runner executes only *.up.sql (see
-- internal/database/migrate.go). Kept alongside for the record of how to roll
-- back 016 by hand. The rides table is untouched by this migration, so dropping
-- ride_stops removes every stop and leaves the rides rows intact.
DROP INDEX IF EXISTS idx_ride_stops_ride;
DROP TABLE IF EXISTS ride_stops;
