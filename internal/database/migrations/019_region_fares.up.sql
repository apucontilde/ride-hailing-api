-- 019_region_fares.up.sql
-- Region-scoped, versioned, DB-backed pricing (api_plans/STATUS.md [fare]).
-- This is the chain head: it builds the
-- tables, the region plumbing and the variable model. The climb uplift
-- (stage 01) and the actuals recompute (stage 02) are NOT built here; only the
-- seams they need land (rides.grade_uplift_pct and fare_rate_id).
--
-- Pricing is a LOCAL operation (decision 2): a region's card is read from THIS
-- database, even when that region's road network lives in another Postgres
-- (routing_regions.datasource). The routing_regions registry itself stays free
-- of money columns; commercial attributes live in fare_regions.
--
-- Append-only and idempotent, valid in every reachable state, so the runner's
-- non-atomic multi-statement exec (migrate.go) is SAFE. CREATE TABLE IF NOT
-- EXISTS / ADD COLUMN IF NOT EXISTS keep a re-run converging.

-- ---------------------------------------------------------------------------
-- (a) Pricing-owned extension of the region dimension.
-- ---------------------------------------------------------------------------
-- Routing stays untouched: currency and timezone have no business in
-- routing_regions. One row per region that may be priced.
CREATE TABLE IF NOT EXISTS fare_regions (
    region_id  TEXT PRIMARY KEY REFERENCES routing_regions(region_id),
    currency   TEXT NOT NULL DEFAULT 'USD',   -- ISO-4217, the region's pricing currency
    timezone   TEXT NOT NULL,                 -- IANA, e.g. 'America/Costa_Rica'; never guessed
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- (b) The versioned, per-region rate card.
-- ---------------------------------------------------------------------------
-- Amounts are integer CENTS, never floating major units. `per_km_cents`
-- INCLUDES the fuel cost (decision 4): the fuel consumption/fuel-price
-- derivation happens when the card is authored (make seed-fares or an admin
-- write), never per request.
--
-- A rate change is a NEW effective-dated row, never an in-place UPDATE: the
-- partial unique index allows exactly one active (effective_to IS NULL) row
-- per (region, vehicle_type), and closing a card plus inserting its successor
-- is the only way to change a price.
CREATE TABLE IF NOT EXISTS fare_rates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    region_id       TEXT NOT NULL REFERENCES fare_regions(region_id),
    vehicle_type    TEXT NOT NULL CHECK (vehicle_type IN ('sedan', 'suv', 'luxury')),
    currency        TEXT NOT NULL,             -- immutable audit of what the card was authored in
    base_fare_cents INTEGER NOT NULL CHECK (base_fare_cents >= 0),
    per_km_cents    INTEGER NOT NULL CHECK (per_km_cents >= 0),
    per_min_cents   INTEGER NOT NULL CHECK (per_min_cents >= 0),
    effective_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    effective_to    TIMESTAMPTZ,               -- NULL = active
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fare_rates_active
    ON fare_rates(region_id, vehicle_type) WHERE effective_to IS NULL;
CREATE INDEX IF NOT EXISTS idx_fare_rates_region_type
    ON fare_rates(region_id, vehicle_type);

-- ---------------------------------------------------------------------------
-- (c) Demand windows, evaluated in the region's LOCAL time.
-- ---------------------------------------------------------------------------
-- start_minute/end_minute are minutes from LOCAL midnight, resolved through
-- fare_regions.timezone. day_mask is a 7-bit mask, bit 0 = Sunday. A window is
-- half-open [start, end); a start > end window wraps past midnight.
CREATE TABLE IF NOT EXISTS fare_demand_windows (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    region_id    TEXT NOT NULL REFERENCES fare_regions(region_id),
    name         TEXT NOT NULL,                       -- e.g. 'am_peak'
    day_mask     SMALLINT NOT NULL DEFAULT 127 CHECK (day_mask BETWEEN 0 AND 127),
    start_minute INTEGER NOT NULL CHECK (start_minute >= 0 AND start_minute < 1440),
    end_minute   INTEGER NOT NULL CHECK (end_minute >= 0 AND end_minute < 1440),
    multiplier   NUMERIC(4,2) NOT NULL DEFAULT 1.0 CHECK (multiplier >= 1.0),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fare_demand_windows_region ON fare_demand_windows(region_id);

-- ---------------------------------------------------------------------------
-- (d) Audit: which region's card priced this ride, and which card version.
-- ---------------------------------------------------------------------------
-- No FK on purpose: the registry / fare row may be retired or superseded
-- later, and the audit must survive that. fare_rate_id is the seam stage 02
-- reuses so a recompute is deterministic against the BOOKED card.
ALTER TABLE rides
    ADD COLUMN IF NOT EXISTS fare_region_id   TEXT,
    ADD COLUMN IF NOT EXISTS fare_rate_id     UUID,
    ADD COLUMN IF NOT EXISTS fare_currency    TEXT,
    ADD COLUMN IF NOT EXISTS grade_uplift_pct NUMERIC(6,4);  -- applied climb uplift (stage 01)
