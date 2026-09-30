//go:build integration

package repository

// TEMPORARY pre-fix probe: measures the real PostGIS-geography vs Go-haversine
// disagreement on the live cr-sj import. Deleted once the permanent tests are in
// place.

import (
	"testing"

	"ride-hailing-api/internal/routing"
)

func TestPreFixProbeLiveDivergence(t *testing.T) {
	db := connectPG(t)

	// Pick the vertex with the highest degree in cr-sj (a road junction, so the
	// <-> KNN answer is not a random cul-de-sac).
	type row struct {
		ID      int64   `db:"id"`
		Lat     float64 `db:"lat"`
		Lng     float64 `db:"lng"`
		Postgis float64 `db:"postgis_m"`
	}
	var v row
	err := db.Get(&v, `
		SELECT v.id, v.lat, v.lng,
		       ST_Distance(v.the_geom::geography,
		                   ST_SetSRID(ST_MakePoint(v.lng, v.lat + $1), 4326)::geography) AS postgis_m
		FROM road_network_vertices_pgr v
		WHERE v.region_id = 'cr-sj'
		ORDER BY v.id
		LIMIT 1`, 0.01)
	if err != nil {
		t.Fatalf("no cr-sj vertex: %v", err)
	}
	goM := routing.HaversineMeters(v.Lat, v.Lng, v.Lat+0.01, v.Lng)
	t.Logf("vertex %d at (%.5f,%.5f): postgis=%.1f m goHaversine=%.1f m go/postgis=%.5f (go reads %+.2f%%)",
		v.ID, v.Lat, v.Lng, v.Postgis, goM, goM/v.Postgis, (goM/v.Postgis-1)*100)
}
