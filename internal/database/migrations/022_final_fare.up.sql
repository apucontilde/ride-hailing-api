-- 022_final_fare.up.sql
-- Quote-vs-final fare split (api_plans/01_[fare]_actuals_recompute_on_completion.md).
-- This is the [fare] chain stage 02: it consumes the actuals recorded by
-- migration 021 and the booked-card snapshot (019/020) and stores the FINAL
-- charge alongside the audit-only quote.
--
-- Product decision (owner, 2026-10-06): the recomputed actual REPLACES the
-- quote with NO tolerance/cap (uncapped in both directions), and the final
-- charge is the only one shown. The quote is retained for audit, never as a
-- displayed line.
--
-- Design: the existing money columns (base_fare, distance_fare, time_fare,
-- surge_multiplier, total_fare) hold the BOOKING QUOTE until the ride is
-- completed, then hold the FINAL charge. On completion the pre-completion
-- values are copied atomically into the quoted_* audit columns below, so:
--
--   * a pending/in_progress ride's `total_fare` is still its quote (unchanged
--     for every reader that already exists);
--   * a completed ride's `total_fare` is the final charge, so every read path
--     (ride JSON, receipt, driver history) resolves to the final with no new
--     field to learn and no rename (the JSON shape is untouched);
--   * `quoted_*` is NULL until completion, then holds the quote. It is audit
--     metadata and is deliberately NOT exposed on the ride JSON (model.Ride
--     tags them `json:"-"`), matching "final only" on the wire.
--
-- NULL (not 0) means "this ride has no captured quote" — a ride that never
-- completed or one booked before this migration. The completion UPDATE guards
-- on `quoted_total_fare IS NULL`, so finalizing is once-only and idempotent:
-- a retry cannot re-snapshot a final charge back into the quote columns.
--
-- Append-only and idempotent: ADD COLUMN IF NOT EXISTS converges on a re-run,
-- which keeps the runner's non-atomic multi-statement exec safe
-- (internal/database/migrate.go).

ALTER TABLE rides
    ADD COLUMN IF NOT EXISTS quoted_base_fare        DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS quoted_distance_fare    DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS quoted_time_fare        DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS quoted_surge_multiplier DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS quoted_total_fare       DOUBLE PRECISION;
