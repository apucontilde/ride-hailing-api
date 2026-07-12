CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE driver_positions (
    driver_id    UUID        PRIMARY KEY REFERENCES drivers(user_id) ON DELETE CASCADE,
    location     GEOGRAPHY(Point, 4326) NOT NULL,
    heading      REAL,
    speed        REAL,
    status       TEXT        NOT NULL DEFAULT 'offline'
                              CHECK (status IN ('online', 'busy', 'offline')),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_driver_positions_location
    ON driver_positions USING GIST (location);

CREATE INDEX idx_driver_positions_online
    ON driver_positions USING GIST (location)
    WHERE status = 'online';

CREATE TABLE rider_positions (
    rider_id    UUID        PRIMARY KEY REFERENCES riders(user_id) ON DELETE CASCADE,
    location    GEOGRAPHY(Point, 4326) NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_rider_positions_location
    ON rider_positions USING GIST (location);
