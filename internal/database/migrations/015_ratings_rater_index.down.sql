-- Documentation only: the migration runner executes only *.up.sql (see
-- internal/database/migrate.go). Kept alongside for the record of how to roll
-- back 015 by hand.
DROP INDEX IF EXISTS idx_ratings_rater;
