-- 023_final_grade_uplift.down.sql
-- Documentation only: the runner executes *.up.sql and never *.down.sql
-- (internal/database/migrate.go). Kept for a human rolling a dev volume back.
--
-- Dropping the booked-uplift audit loses the quote's climb uplift; the applied
-- grade_uplift_pct column keeps whichever of quote/final it currently holds.
-- Only safe while nothing reads the split; roll back the code first.
ALTER TABLE rides
    DROP COLUMN IF EXISTS quoted_grade_uplift_pct;
