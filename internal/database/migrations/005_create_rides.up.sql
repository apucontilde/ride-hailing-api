CREATE TABLE rides (
    id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    rider_id          UUID          NOT NULL REFERENCES riders(user_id),
    driver_id         UUID          REFERENCES drivers(user_id),
    status            TEXT          NOT NULL DEFAULT 'pending'
                                    CHECK (status IN (
                                        'pending', 'accepted', 'driver_arrived',
                                        'in_progress', 'completed', 'cancelled',
                                        'no_driver_available'
                                    )),
    pickup_lat        DOUBLE PRECISION NOT NULL,
    pickup_lng        DOUBLE PRECISION NOT NULL,
    dropoff_lat       DOUBLE PRECISION NOT NULL,
    dropoff_lng       DOUBLE PRECISION NOT NULL,
    pickup_address    TEXT          NOT NULL DEFAULT '',
    dropoff_address   TEXT          NOT NULL DEFAULT '',
    vehicle_type      TEXT          NOT NULL DEFAULT 'sedan',
    cancellation_fee  DOUBLE PRECISION NOT NULL DEFAULT 0,
    idempotency_key   TEXT          NOT NULL DEFAULT '',

    -- Fare fields
    base_fare         DOUBLE PRECISION NOT NULL DEFAULT 0,
    distance_fare     DOUBLE PRECISION NOT NULL DEFAULT 0,
    time_fare         DOUBLE PRECISION NOT NULL DEFAULT 0,
    surge_multiplier  DOUBLE PRECISION NOT NULL DEFAULT 1.0,
    total_fare        DOUBLE PRECISION NOT NULL DEFAULT 0,

    -- Timestamps for lifecycle
    requested_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    accepted_at       TIMESTAMPTZ,
    driver_arrived_at TIMESTAMPTZ,
    started_at        TIMESTAMPTZ,
    completed_at      TIMESTAMPTZ,
    cancelled_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_rides_rider ON rides(rider_id);
CREATE INDEX idx_rides_driver ON rides(driver_id);
CREATE INDEX idx_rides_status ON rides(status);
CREATE INDEX idx_rides_idempotency ON rides(idempotency_key);
CREATE INDEX idx_rides_rider_active ON rides(rider_id) WHERE status IN ('pending', 'accepted', 'driver_arrived', 'in_progress');

CREATE TABLE ride_events (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id         UUID          NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    from_status     TEXT          NOT NULL,
    to_status       TEXT          NOT NULL,
    actor           TEXT          NOT NULL CHECK (actor IN ('rider', 'driver', 'system')),
    reason          TEXT          NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ride_events_ride ON ride_events(ride_id);

CREATE TABLE ratings (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    ride_id         UUID          NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    rater_role      TEXT          NOT NULL CHECK (rater_role IN ('rider', 'driver')),
    rater_id        UUID          NOT NULL,
    ratee_id        UUID          NOT NULL,
    score           INTEGER       NOT NULL CHECK (score >= 1 AND score <= 5),
    comment         TEXT          NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE(ride_id, rater_role)
);

CREATE INDEX idx_ratings_ratee ON ratings(ratee_id);
