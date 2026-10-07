-- 020_grade_uplift.down.sql
-- Documentation only: the runner executes *.up.sql and never *.down.sql
-- (internal/database/migrate.go). Kept for a human rolling a dev volume back.
--
-- Dropping the knobs leaves every card at the 0/off default on a re-seed;
-- dropping grade_ascent_m only loses the audit of a past uplift snapshot.
ALTER TABLE rides
    DROP COLUMN IF EXISTS grade_ascent_m;
ALTER TABLE fare_rates
    DROP COLUMN IF EXISTS grade_uplift_factor,
    DROP COLUMN IF EXISTS grade_uplift_cap;
