UPDATE road_edges SET gradient = NULL, cost_elev = NULL, reverse_cost_elev = NULL;
UPDATE road_vertices SET elevation_m = NULL;
DROP FUNCTION IF EXISTS sample_elevation;
