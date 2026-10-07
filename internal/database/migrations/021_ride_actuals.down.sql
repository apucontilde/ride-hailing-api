-- 021_ride_actuals.down.sql
-- Documentation only: the runner executes *.up.sql and never *.down.sql
-- (internal/database/migrate.go). Kept for a human rolling a dev volume back.
--
-- Dropping the columns loses the recorded actuals (stage 02 would then fall
-- back to the booked values); dropping ride_track_points loses the raw fixes.
DROP TABLE IF EXISTS ride_track_points;
ALTER TABLE rides
    DROP COLUMN IF EXISTS actual_duration_s,
    DROP COLUMN IF EXISTS actual_distance_m;
