CREATE TABLE rider_favorites (
    id          UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    rider_id    UUID          NOT NULL REFERENCES riders(user_id) ON DELETE CASCADE,
    name        TEXT          NOT NULL,
    lat         DOUBLE PRECISION NOT NULL,
    lng         DOUBLE PRECISION NOT NULL,
    address     TEXT          NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_rider_favorites_rider ON rider_favorites(rider_id);

CREATE TABLE promotions (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    code            TEXT          UNIQUE NOT NULL,
    description     TEXT          NOT NULL DEFAULT '',
    discount_type   TEXT          NOT NULL CHECK (discount_type IN ('fixed', 'percentage', 'free_ride')),
    discount_value  DOUBLE PRECISION NOT NULL,
    max_uses        INTEGER       NOT NULL DEFAULT 1,
    current_uses    INTEGER       NOT NULL DEFAULT 0,
    expires_at      TIMESTAMPTZ   NOT NULL,
    is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TABLE applied_promotions (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    promotion_id    UUID          NOT NULL REFERENCES promotions(id),
    user_id         UUID          NOT NULL REFERENCES users(id),
    ride_id         UUID          REFERENCES rides(id),
    applied_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_applied_promotions_user ON applied_promotions(user_id, promotion_id);

CREATE TABLE device_tokens (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token           TEXT          NOT NULL,
    platform        TEXT          NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
    is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, token)
);

CREATE INDEX idx_device_tokens_user ON device_tokens(user_id);

CREATE TABLE sos_alerts (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID          NOT NULL REFERENCES users(id),
    user_role       TEXT          NOT NULL CHECK (user_role IN ('rider', 'driver')),
    ride_id         UUID          REFERENCES rides(id),
    lat             DOUBLE PRECISION NOT NULL,
    lng             DOUBLE PRECISION NOT NULL,
    status          TEXT          NOT NULL DEFAULT 'active'
                                  CHECK (status IN ('active', 'resolved')),
    resolved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TABLE feedback (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID          NOT NULL REFERENCES users(id),
    ride_id         UUID          REFERENCES rides(id),
    message         TEXT          NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TABLE idempotency_keys (
    key             TEXT          PRIMARY KEY,
    user_id         UUID          NOT NULL REFERENCES users(id),
    response_status INTEGER       NOT NULL,
    response_body   JSONB         NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_idempotency_keys_user ON idempotency_keys(user_id);
