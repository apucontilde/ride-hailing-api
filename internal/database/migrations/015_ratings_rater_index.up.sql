-- 015_ratings_rater_index.up.sql
-- Rater-scoped read endpoints (api_plans/[ratings]_ratings_list.md):
--   GET /api/v1/rider/ratings
--   GET /api/v1/driver/ratings
-- both filter on (rater_id, rater_role). 005 only indexed ratee_id
-- (idx_ratings_ratee), so those queries would be a sequential scan.
--
-- Append-only, idempotent, metadata-only: adds an index, no schema change to
-- ratings (all needed columns already exist).
CREATE INDEX IF NOT EXISTS idx_ratings_rater ON ratings(rater_id, rater_role);
