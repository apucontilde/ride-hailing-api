CREATE TABLE riders (
    user_id       UUID        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    first_name    TEXT        NOT NULL DEFAULT '',
    last_name     TEXT        NOT NULL DEFAULT '',
    photo_url     TEXT        NOT NULL DEFAULT '',
    status        TEXT        NOT NULL DEFAULT 'idle'
                            CHECK (status IN ('idle', 'looking', 'busy')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE drivers (
    user_id           UUID        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    first_name        TEXT        NOT NULL DEFAULT '',
    last_name         TEXT        NOT NULL DEFAULT '',
    photo_url         TEXT        NOT NULL DEFAULT '',
    status            TEXT        NOT NULL DEFAULT 'offline'
                                CHECK (status IN ('offline', 'online', 'busy')),
    onboarding_status TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (onboarding_status IN (
                                    'pending', 'documents_submitted',
                                    'verification_in_progress', 'approved', 'rejected'
                                )),
    rating_summary    JSONB       NOT NULL DEFAULT '{"average": 0.0, "count": 0}',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE driver_documents (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    driver_id       UUID        NOT NULL REFERENCES drivers(user_id) ON DELETE CASCADE,
    document_type   TEXT        NOT NULL CHECK (document_type IN (
                        'drivers_license', 'vehicle_insurance', 'vehicle_registration',
                        'background_check', 'profile_photo'
                    )),
    file_url        TEXT        NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending', 'approved', 'rejected')),
    rejection_reason TEXT       NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_driver_documents_driver ON driver_documents(driver_id);

CREATE TABLE driver_vehicles (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    driver_id       UUID        NOT NULL REFERENCES drivers(user_id) ON DELETE CASCADE,
    make            TEXT        NOT NULL,
    model           TEXT        NOT NULL,
    color           TEXT        NOT NULL,
    year            INTEGER     NOT NULL,
    plate_number    TEXT        NOT NULL,
    vehicle_type    TEXT        NOT NULL DEFAULT 'sedan'
                                CHECK (vehicle_type IN (
                                    'sedan', 'suv', 'hatchback', 'van',
                                    'premium', 'motorcycle', 'bicycle'
                                )),
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_driver_vehicles_driver ON driver_vehicles(driver_id);
