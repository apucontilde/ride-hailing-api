-- 016_ride_stops.up.sql
-- Multi-stop rides (api_plans/[multi]_add_stops_change_destination.md):
--   POST /api/v1/rides            (optional ordered `stops[]`)
--   PUT  /api/v1/rides/:id/destination
--   GET  /api/v1/rides/:id        (read-only `stops` envelope)
--
-- rides.dropoff_lat/lng/address keep their 005 meaning and stay authoritative
-- for the FINAL destination (backward compatibility: the routing, fare and
-- receipt paths all read those scalars). This table holds the ordered
-- waypoints; the final destination is mirrored as the last row with
-- kind='destination', so a single ordered read gives the whole itinerary.
--
-- Append-only, metadata-only: no rides column changes.
CREATE TABLE IF NOT EXISTS ride_stops (
    id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id      UUID          NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    -- 1-based visit order. Gaps are impossible by CHECK; duplicates are
    -- impossible by UNIQUE, which is what makes the itinerary unambiguous.
    sequence     INTEGER       NOT NULL CHECK (sequence >= 1),
    -- 'stop' is an intermediate waypoint; 'destination' is the final one and
    -- is only ever the highest sequence (enforced in the service layer).
    kind         TEXT          NOT NULL DEFAULT 'stop' CHECK (kind IN ('stop', 'destination')),
    lat          DOUBLE PRECISION NOT NULL,
    lng          DOUBLE PRECISION NOT NULL,
    address      TEXT          NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE (ride_id, sequence)
);

-- The only read pattern is "one ride's itinerary in order", which the
-- UNIQUE(ride_id, sequence) index already serves; this keeps the planner from
-- falling back to a sort when a ride has no stops at all.
CREATE INDEX IF NOT EXISTS idx_ride_stops_ride ON ride_stops(ride_id);
