-- Routing topology tables used by internal/repository/navigation_repo.go.
-- The pgr_dijkstra overload below is a demo stub (no real pgRouting graph in
-- the dev DB); guard every branch with explicit ::float8 casts because an
-- uncast numeric literal in a double precision column raises error 42804
-- ("structure of query does not match function result type").

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

-- Demo graph so routing works out of the box on a fresh database.
INSERT INTO road_network_vertices_pgr (id, the_geom, lat, lng)
SELECT g.id, ST_SetSRID(ST_MakePoint(g.lng, g.lat), 4326), g.lat, g.lng
FROM (VALUES
    (1::bigint, 40.7128::float8, -74.006::float8),
    (2::bigint, 40.7580::float8, -73.9855::float8)
) AS g(id, lat, lng)
WHERE NOT EXISTS (SELECT 1 FROM road_network_vertices_pgr);

INSERT INTO road_network_edges_pgr (id, source, target, cost)
SELECT 100::bigint, 1::bigint, 2::bigint, 10000::float8
WHERE NOT EXISTS (SELECT 1 FROM road_network_edges_pgr);

DROP FUNCTION IF EXISTS public.pgr_dijkstra(text, bigint, bigint, boolean);

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