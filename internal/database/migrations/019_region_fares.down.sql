-- 019_region_fares.down.sql
-- Documentation only: the runner executes *.up.sql and never *.down.sql
-- (internal/database/migrate.go). Kept for a human rolling a dev volume back.
--
-- NOTE: dropping the tables loses every authored fare card. Re-running
-- `make seed-fares` restores the shipped default cards, but any operator
-- tuning is gone.
DROP TABLE IF EXISTS fare_demand_windows;
DROP TABLE IF EXISTS fare_rates;
DROP TABLE IF EXISTS fare_regions;
ALTER TABLE rides
    DROP COLUMN IF EXISTS fare_region_id,
    DROP COLUMN IF EXISTS fare_rate_id,
    DROP COLUMN IF EXISTS fare_currency,
    DROP COLUMN IF EXISTS grade_uplift_pct;
