-- 021_ride_actuals.up.sql
-- Per-ride ACTUALS captured from status transitions and the driver's location
-- stream (api_plans/[tracking]_actual_trip_distance.md). This stage is
-- deliberately FARE-AGNOSTIC: it records what actually happened and never
-- reprices. api_plans/01_[fare]_actuals_recompute_on_completion.md consumes these
-- columns later.
--
--   actual_duration_s -- completed_at - started_at, computed server-side on the
--                        completed transition. NULL when either timestamp is
--                        missing (never a fabricated 0).
--   actual_distance_m -- summed haversine over the driver's accepted location
--                        fixes between started_at and completed_at, with a
--                        noise/teleport gate. NULL when no usable trace exists
--                        (no fixes, a single fix, or every segment gated out);
--                        stage 02 falls back to the booked route distance.
--
-- ride_track_points is the append-only raw fix trace the distance is summed
-- from. It is the driven polyline seam as well, but is NOT exposed on the ride
-- JSON in this stage. Append-only inserts keep the hot location endpoint free
-- of read-modify-write races on rides.actual_distance_m.
--
-- Append-only and idempotent: ADD COLUMN IF NOT EXISTS / CREATE TABLE IF NOT
-- EXISTS converge on a re-run, which keeps the runner's non-atomic
-- multi-statement exec safe (internal/database/migrate.go).

ALTER TABLE rides
    ADD COLUMN IF NOT EXISTS actual_duration_s INTEGER,
    ADD COLUMN IF NOT EXISTS actual_distance_m DOUBLE PRECISION;

CREATE TABLE IF NOT EXISTS ride_track_points (
    id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id     UUID        NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    lat         DOUBLE PRECISION NOT NULL,
    lng         DOUBLE PRECISION NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fixes are always read back for ONE ride in time order, so the index leads
-- with ride_id and carries recorded_at for a cheap ordered scan.
CREATE INDEX IF NOT EXISTS idx_ride_track_points_ride
    ON ride_track_points(ride_id, recorded_at);
