CREATE TABLE road_vertices (
    id            BIGSERIAL PRIMARY KEY,
    geom          GEOMETRY(Point, 4326),
    cnt           INTEGER,
    elevation_m   REAL
);

CREATE INDEX idx_road_vertices_geom ON road_vertices USING GIST (geom);

CREATE TABLE road_edges (
    id              BIGSERIAL PRIMARY KEY,
    source          BIGINT REFERENCES road_vertices(id),
    target          BIGINT REFERENCES road_vertices(id),
    geom            GEOMETRY(LINESTRING, 4326),
    length_m        FLOAT,
    cost            FLOAT,
    reverse_cost    FLOAT,
    name            TEXT,
    highway_type    TEXT,
    max_speed_kmh   INTEGER,
    x1              FLOAT,
    y1              FLOAT,
    x2              FLOAT,
    y2              FLOAT,
    gradient        REAL,
    cost_elev       FLOAT,
    reverse_cost_elev FLOAT
);

CREATE INDEX idx_road_edges_source ON road_edges(source);
CREATE INDEX idx_road_edges_target ON road_edges(target);
CREATE INDEX idx_road_edges_geom   ON road_edges USING GIST (geom);
