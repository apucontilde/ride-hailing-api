-- Helper: sample elevation from lon/lat (placeholder — returns 0 without DEM)
CREATE OR REPLACE FUNCTION sample_elevation(lon double precision, lat double precision)
RETURNS double precision
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN 0;
END;
$$;

-- Populate elevation on vertices
UPDATE road_vertices
SET elevation_m = sample_elevation(ST_X(geom), ST_Y(geom));

-- Compute gradient and elevation-sensitive costs
UPDATE road_edges e
SET
  gradient = (vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0),
  cost_elev = CASE
    WHEN vt.elevation_m > vs.elevation_m
      THEN e.cost * (1 + 0.05 * ABS((vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0)))
    ELSE e.cost * (1 + 0.025 * ABS((vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0)))
  END,
  reverse_cost_elev = CASE
    WHEN vs.elevation_m > vt.elevation_m
      THEN e.reverse_cost * (1 + 0.05 * ABS((vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0)))
    ELSE e.reverse_cost * (1 + 0.025 * ABS((vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0)))
  END
FROM road_vertices vs, road_vertices vt
WHERE e.source = vs.id AND e.target = vt.id;
