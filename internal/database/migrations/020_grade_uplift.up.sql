-- 020_grade_uplift.up.sql
-- Capped climb uplift on the distance leg (api_plans/[fare]_grade_fuel_cost.md).
-- This is the [fare] chain stage 01: it consumes the RAW total_ascent_m the
-- landed elevation flip now reports and turns it into a bounded money term.
--
-- Two knobs live on the rate card, PER REGION *AND* PER VEHICLE CLASS (an SUV
-- burns more per climb and a mountainous region must not be priced like a flat
-- coastal one):
--
--   grade_uplift_factor -- uplift FRACTION added per (metre climbed / km driven)
--   grade_uplift_cap    -- hard ceiling on the fraction; the rider's hill
--                          exposure is bounded, never open-ended
--
-- The applied uplift is:
--   ascent_per_km = ascent_m / max(km, epsilon)
--   uplift        = min(ascent_per_km * grade_uplift_factor, grade_uplift_cap)
--   distance_fare = km * per_km_cents * (1 + uplift)
--
-- DEFAULT 0 = the feature is OFF for that card. 0 is honest (no uplift) and
-- must never crash; a region migrated from 019 starts flat until seeded.
--
-- rides.grade_ascent_m snapshots the RAW ascent the uplift was derived from
-- (NULL when the uplift was 0), so a disputed fare can be re-derived. It is
-- the optional audit companion to grade_uplift_pct (019).
--
-- Append-only and idempotent: ADD COLUMN IF NOT EXISTS converges on a re-run,
-- which is what keeps the runner's non-atomic multi-statement exec safe
-- (internal/database/migrate.go).

-- ---------------------------------------------------------------------------
-- (a) Per-(region, vehicle class) uplift knobs.
-- ---------------------------------------------------------------------------
-- NUMERIC, not money: these are dimensionless fractions. The factor resolves to
-- 6 decimals (a card authoring tool derives it from a fuel/energy model); the
-- cap at 4 matches grade_uplift_pct's precision.
ALTER TABLE fare_rates
    ADD COLUMN IF NOT EXISTS grade_uplift_factor NUMERIC(10,6) NOT NULL DEFAULT 0;
ALTER TABLE fare_rates
    ADD COLUMN IF NOT EXISTS grade_uplift_cap NUMERIC(6,4) NOT NULL DEFAULT 0;

-- ---------------------------------------------------------------------------
-- (b) Audit: the raw ascent the applied uplift was derived from.
-- ---------------------------------------------------------------------------
-- NULL (not 0) means "no uplift was ever applied to this ride" — the fail-flat
-- case. Mirrors the fare_* audit columns' no-FK, metadata-only shape.
ALTER TABLE rides
    ADD COLUMN IF NOT EXISTS grade_ascent_m DOUBLE PRECISION;
