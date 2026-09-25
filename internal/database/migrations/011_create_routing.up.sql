-- Routing topology tables used by internal/repository/navigation_repo.go.
-- pgr_dijkstra is provided by the REAL pgRouting extension (created by the
-- image's init script on a fresh volume, or by migration 012 on a reused
-- one — api_plans/02). The function overload below is only a demo stub for
-- dev DBs WITHOUT pgRouting; it and the demo seed are guarded so a database
-- that has the real extension NEVER shadows it and NEVER gets seed rows.
-- Keep the ::float8 casts explicit: an uncast numeric literal in a double
-- precision column raises error 42804.

CREATE TABLE IF NOT EXISTS road_network_vertices_pgr (
    id       BIGINT PRIMARY KEY,
    the_geom GEOMETRY(Point, 4326),
    lat      DOUBLE PRECISION,
    lng      DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS road_network_edges_pgr (
    id     BIGINT PRIMARY KEY,
    source BIGINT,
    target BIGINT,
    cost   DOUBLE PRECISION
);

CREATE INDEX IF NOT EXISTS idx_road_network_vert_geom ON road_network_vertices_pgr USING GIST (the_geom);
CREATE INDEX IF NOT EXISTS idx_road_network_edges_source ON road_network_edges_pgr (source);
CREATE INDEX IF NOT EXISTS idx_road_network_edges_target ON road_network_edges_pgr (target);

-- Demo graph so routing works out of the box on a fresh database WITHOUT the
-- real pgRouting extension. Guarded: with pgRouting installed the seed would
-- poison KNN snapping (every snap lands on NYC) and trip the import gate.
INSERT INTO road_network_vertices_pgr (id, the_geom, lat, lng)
SELECT g.id, ST_SetSRID(ST_MakePoint(g.lng, g.lat), 4326), g.lat, g.lng
FROM (VALUES
    (1::bigint, 40.7128::float8, -74.006::float8),
    (2::bigint, 40.7580::float8, -73.9855::float8)
) AS g(id, lat, lng)
WHERE NOT EXISTS (SELECT 1 FROM road_network_vertices_pgr)
  AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgrouting');

INSERT INTO road_network_edges_pgr (id, source, target, cost)
SELECT 100::bigint, 1::bigint, 2::bigint, 10000::float8
WHERE NOT EXISTS (SELECT 1 FROM road_network_edges_pgr)
  AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgrouting');

-- Demo stub ONLY when the real pgRouting extension is absent (pre-02 image
-- volumes or a fail-degraded dev DB without pgRouting). With the extension
-- installed, its own pgr_dijkstra implementation is used instead.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgrouting') THEN
        CREATE OR REPLACE FUNCTION public.pgr_dijkstra(
            edge_sql   text,
            start_vid  bigint,
            end_vid    bigint,
            directed   boolean DEFAULT true
        )
        RETURNS TABLE(seq bigint, node bigint, edge bigint, cost double precision, agg_cost double precision)
        LANGUAGE plpgsql
        AS $function$
        DECLARE
            direct_edge RECORD;
            straight_m  double precision;
        BEGIN
            -- No usable road network / vertices: return an empty path, never raise.
            IF start_vid IS NULL OR end_vid IS NULL THEN
                RETURN;
            END IF;

            IF start_vid = end_vid THEN
                RETURN QUERY SELECT 0::bigint, start_vid, -1::bigint, 0.0::float8, 0.0::float8;
                RETURN;
            END IF;

            SELECT e.id, e.cost INTO direct_edge FROM road_network_edges_pgr e
                WHERE (e.source = start_vid AND e.target = end_vid)
                   OR (e.source = end_vid AND e.target = start_vid)
                LIMIT 1;

            IF FOUND THEN
                RETURN QUERY SELECT 0::bigint, start_vid, direct_edge.id::bigint, 0.0::float8, 0.0::float8;
                RETURN QUERY SELECT 1::bigint, end_vid, direct_edge.id::bigint,
                                    direct_edge.cost::float8, direct_edge.cost::float8;
                RETURN;
            END IF;

            -- No stored edge between the vertices: approximate with the geodesic
            -- distance between them (meters) instead of fabricating a constant.
            SELECT ST_Distance(s.the_geom::geography, e.the_geom::geography)
              INTO straight_m
              FROM road_network_vertices_pgr s, road_network_vertices_pgr e
              WHERE s.id = start_vid AND e.id = end_vid;

            RETURN QUERY SELECT 0::bigint, start_vid, -1::bigint, 0.0::float8, 0.0::float8
                UNION ALL
                SELECT 1::bigint, end_vid, -1::bigint, COALESCE(straight_m, 0.0)::float8, COALESCE(straight_m, 0.0)::float8;
        END;
        $function$;
    END IF;
END $$;