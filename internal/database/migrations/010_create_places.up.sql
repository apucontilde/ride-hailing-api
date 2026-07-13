CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE places (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    osm_type   TEXT NOT NULL,
    osm_id     BIGINT NOT NULL,
    name       TEXT NOT NULL,
    category   TEXT NOT NULL DEFAULT 'poi',
    address    TEXT,
    location   GEOGRAPHY(Point, 4326) NOT NULL,
    search_tsv TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple', coalesce(name,'') || ' ' || coalesce(address,''))
    ) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (osm_type, osm_id)
);

CREATE INDEX idx_places_location ON places USING GIST (location);
CREATE INDEX idx_places_search_tsv ON places USING GIN (search_tsv);
CREATE INDEX idx_places_name_trgm ON places USING GIN (name gin_trgm_ops);
