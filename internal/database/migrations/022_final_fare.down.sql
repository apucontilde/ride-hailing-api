-- 022_final_fare.down.sql
-- Documentation only: the runner executes *.up.sql and never *.down.sql
-- (internal/database/migrate.go). Kept for a human rolling a dev volume back.
--
-- Dropping the quoted_* columns loses the audit quote (the money columns keep
-- whichever of quote/final they currently hold). Only safe while nothing reads
-- the split; roll back the code first.
ALTER TABLE rides
    DROP COLUMN IF EXISTS quoted_base_fare,
    DROP COLUMN IF EXISTS quoted_distance_fare,
    DROP COLUMN IF EXISTS quoted_time_fare,
    DROP COLUMN IF EXISTS quoted_surge_multiplier,
    DROP COLUMN IF EXISTS quoted_total_fare;
