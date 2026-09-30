//go:build integration

package repository

// The coverage band, measured with the REAL PostGIS on a live database.
//
// The unit tests (pin_uncovered_test.go) can only assert that the two
// predicates DISAGREE, using distances measured in each formula's own units.
// This file measures the disagreement itself: for one pin near the 50000 m
// boundary, the region resolver's Snap (PostGIS ST_Distance over ::geography,
// spheroidal) and the engine's own haversine (a great-circle formula on a
// 6371 km sphere) are both run, and the answer both give is asserted.
//
// It needs a live PostGIS+pgRouting DB (`docker compose up -d`) and shadows the
// real tables with TEMP tables on a single-connection handle, so the real SJ
// import is never touched and the test stays fast (a two-vertex graph).

import (
	"testing"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"

	"ride-hailing-api/internal/routing"
)

const (
	bandRegion   = "cr-sj"
	bandRadiusM  = 50000.0
	bandVertexAt = 9.93 // ~San Jose: the latitude a real deployment snaps at
	bandVertexNg = -84.08
)

// seedBandRegion creates a TEMP registry + a two-vertex region network at the
// San Jose latitude, joined by one edge. The vertices are NOT at
// (id*0.001, 0) like the shared fixture: the divergence this test measures is
// latitude-dependent, so the fixture has to sit where a real import does.
func seedBandRegion(t *testing.T) *sqlx.DB {
	t.Helper()
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	dropRegionTables(t, db, "road_network_edges_pgr", "road_network_vertices_pgr", "routing_regions")

	createRegionRegistry(t, db)
	mustExec(t, db, "INSERT INTO routing_regions (region_id, level, name, parent_region, "+
		"bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max, default_region, datasource) VALUES "+
		"('cr-sj', 'state', 'San Jose', NULL, -84.50, 9.00, -83.50, 10.20, TRUE, NULL)")

	createRegionTables(t, db)
	for id, lat := range map[int64]float64{1: bandVertexAt, 2: bandVertexAt + 0.01} {
		mustExec(t, db, "INSERT INTO road_network_vertices_pgr (region_id, id, the_geom, lat, lng) "+
			"VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $4, $3)",
			bandRegion, id, bandVertexNg, lat)
	}
	mustExec(t, db, "INSERT INTO road_network_edges_pgr (region_id, id, source, target, cost) "+
		"VALUES ($1, 1, 1, 2, 1112)", bandRegion)
	return db
}

// pinSouthOf walks a pin south of the band's first vertex until the ENGINE's own
// snap measures targetM to it, then returns it. The distance the test then
// compares is the one the Go gate would have measured.
func pinSouthOfVertex(t *testing.T, targetM float64) (lat, lng float64) {
	t.Helper()
	lo, hi := 0.0, 5.0
	for i := 0; i < 200; i++ {
		mid := (lo + hi) / 2
		if routing.HaversineMeters(bandVertexAt, bandVertexNg, bandVertexAt-mid, bandVertexNg) < targetM {
			lo = mid
		} else {
			hi = mid
		}
	}
	return bandVertexAt - (lo+hi)/2, bandVertexNg
}

// The regression, reproduced against a real database. A pin the resolver covers
// is routed on the region path; the gate must not be able to contradict that
// decision afterwards, whatever it measures.
func TestRealSnapAndEngineGateDisagreeNearTheRadius(t *testing.T) {
	db := seedBandRegion(t)
	repo := NewNavigationRepo(db, bandRadiusM)

	// Build the band pin: the engine measures 50113 m to the first vertex, which
	// is what the engine measured for a pin PostGIS called 49850 m.
	lat, lng := pinSouthOfVertex(t, 50113)
	goM := routing.HaversineMeters(lat, lng, bandVertexAt, bandVertexNg)

	snap, covered := repo.Snap(lat, lng, "", bandRegion)
	if !covered {
		t.Fatalf("PostGIS measured the pin at %.1f m; under a %.0f m radius it must be covered "+
			"(this is the resolver's answer, the one the service acts on)", snap.DistanceM, bandRadiusM)
	}
	if snap.DistanceM >= bandRadiusM {
		t.Fatalf("fixture drifted: resolver distance %.1f m is not inside the %.0f m radius", snap.DistanceM, bandRadiusM)
	}

	// The engine's own measurement of the SAME pin, from the same graph.
	if goM <= bandRadiusM {
		t.Skipf("this PostGIS build measures %.1f m where the Go haversine measures %.1f m — "+
			"the two formulas agree here, so there is no band to pin", snap.DistanceM, goM)
	}
	divergence := (goM/snap.DistanceM - 1) * 100
	t.Logf("band pin: postgis=%.1f m goHaversine=%.1f m (Go reads %+.2f%%, a %.0f m band at a %.0f m radius)",
		snap.DistanceM, goM, divergence, goM-snap.DistanceM, bandRadiusM)
	if goM-snap.DistanceM < 100 {
		t.Errorf("measured divergence is only %.0f m; the ~265 m band this fix is about is not present", goM-snap.DistanceM)
	}
	// The gate's own verdict on the resolver's own accepted pin.
	if WithinSnapRadius(goM, bandRadiusM) {
		t.Fatalf("fixture drifted: the gate now agrees at %.1f m, so this pin is not in the band", goM)
	}

	// THE GUARANTEE, on the real code path: the service accepted this pin, so
	// routing it must not fail. Before the fix this returned routing.ErrNoRoute
	// and the handler answered 500.
	nodes, err := repo.RouteInRegion(bandRegion, "", lat, lng, bandVertexAt+0.01, bandVertexNg)
	if err != nil {
		t.Fatalf("a pin the resolver covered must route: %v", err)
	}
	if len(nodes) == 0 {
		t.Fatal("expected the road route, got no nodes")
	}
	if last := nodes[len(nodes)-1]; last.AggCost != 1112 {
		t.Errorf("AggCost = %v, want 1112 (the route length in meters)", last.AggCost)
	}

	// The same pin on the unscoped path, where nothing resolved it first and the
	// gate IS the authority: it reports its own sentinel for the service to
	// degrade to an estimate.
	legacy := NewNavigationRepo(db, bandRadiusM)
	legacy.graph, legacy.graphAttempted = routing.NewGraph(
		[]routing.Node{{ID: 1, Lat: bandVertexAt, Lng: bandVertexNg}, {ID: 2, Lat: bandVertexAt + 0.01, Lng: bandVertexNg}},
		[]routing.Edge{{Source: 1, Target: 2, Cost: 1112}},
	), true
	if _, err := legacy.GetShortestPath(lat, lng, bandVertexAt+0.01, bandVertexNg); err == nil {
		t.Error("the unscoped path must still refuse to invent a route from an uncovered pin")
	}
}

// A pin PostGIS also calls uncovered is not covered for either path: the
// resolver walks past the region and the service answers an estimate. This is
// the case the shipped 50000 m default exists for, and it must not have become
// a 500 anywhere along the way.
func TestRealUncoveredPinIsUncoveredForBothPaths(t *testing.T) {
	db := seedBandRegion(t)
	repo := NewNavigationRepo(db, bandRadiusM)

	lat, lng := pinSouthOfVertex(t, 60000)
	if _, covered := repo.Snap(lat, lng, "", bandRegion); covered {
		t.Fatal("a 60 km pin must be uncovered under the 50000 m radius")
	}

	nodes, err := repo.RouteInRegion(bandRegion, "", lat, lng, bandVertexAt+0.01, bandVertexNg)
	if err != nil {
		t.Fatalf("a pin no region covers must not reach the region router as an error the service cannot degrade: %v", err)
	}
	if len(nodes) == 0 {
		t.Fatal("expected the road route for a covered destination, got no nodes")
	}
}
