//go:build integration

package repository

import (
	"errors"
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/routing"
)

// These tests need a live PostGIS+pgRouting DB (`docker compose up -d`). Like
// pgrouting_repo_integration_test.go they shadow the real tables with TEMP
// tables on a single-connection handle, so the registry, KNN and pgr_dijkstra
// queries resolve to a tiny two-region fixture and the real SJ import is never
// touched. (datasources_integration_test.go adds the multi-datasource pools on
// top of the same helpers.)
//
// Fixture: two DISJOINT subnetworks with COLLIDING vertex and edge ids, which
// is exactly what per-extract sequential ids produce in production. Vertex
// (region, id N) sits at (lat = N*0.001, lng = 0) in cr-sj and at
// (lat = N*0.001 + 0.010, lng = 0.030) in cr-lc, so an UNSCOPED query would
// answer with the wrong region's coordinates and every assertion below is
// load-bearing.
//
//	cr-sj: 1-2-3-4 (100 m hops) + lone vertex 30      cr-lc: 1-2 (250 m hop)
const (
	regionSJ = "cr-sj"
	regionLC = "cr-lc"
	// cr-lc's offset from cr-sj's coordinates, in degrees.
	lcLatOffset = 0.010
	lcLngOffset = 0.030
)

// pinFn maps a vertex id to its coordinates inside a region.
type pinFn func(id int64) (lat, lng float64)

// sjPin returns the coordinates of vertex `id` inside cr-sj.
func sjPin(id int64) (lat, lng float64) { return float64(id) * 0.001, 0 }

// lcPin returns the coordinates of vertex `id` inside cr-lc.
func lcPin(id int64) (lat, lng float64) {
	return float64(id)*0.001 + lcLatOffset, lcLngOffset
}

// dropRegionTables removes TEMP fixtures at the end of a test. It is registered
// on t.Cleanup IMMEDIATELY after the connection so it runs BEFORE the close
// cleanup (cleanups are LIFO) while the session — and with it the temp tables —
// is still alive. The drops are pg_temp-qualified so they can never reach a real
// table.
func dropRegionTables(t *testing.T, db *sqlx.DB, tables ...string) {
	t.Helper()
	t.Cleanup(func() {
		for _, table := range tables {
			_, _ = db.Exec("DROP TABLE IF EXISTS pg_temp." + table)
		}
	})
}

// createRegionTables creates the TEMP road-network pair, shaped like plan 04:
// composite (region_id, id) PKs (ids collide across regions by design) and a
// GIST on the vertex geometry for the region-scoped KNN.
func createRegionTables(t *testing.T, db *sqlx.DB) {
	t.Helper()
	mustExec(t, db, "CREATE TEMP TABLE road_network_vertices_pgr ("+
		"region_id TEXT NOT NULL, id BIGINT NOT NULL, the_geom GEOMETRY(Point,4326), "+
		"lat DOUBLE PRECISION NOT NULL, lng DOUBLE PRECISION NOT NULL, "+
		"elevation_m DOUBLE PRECISION, elevation_source TEXT, "+
		"PRIMARY KEY (region_id, id))")
	mustExec(t, db, "CREATE TEMP TABLE road_network_edges_pgr ("+
		"region_id TEXT NOT NULL, id BIGINT NOT NULL, source BIGINT, target BIGINT, "+
		"cost DOUBLE PRECISION, PRIMARY KEY (region_id, id))")
	mustExec(t, db, "CREATE INDEX ON road_network_vertices_pgr USING GIST (the_geom)")
}

// createRegionRegistry creates the TEMP routing_regions. parent_region and
// datasource are NULL-able by design, so the COALESCE mapping is exercised.
func createRegionRegistry(t *testing.T, db *sqlx.DB) {
	t.Helper()
	mustExec(t, db, "CREATE TEMP TABLE routing_regions ("+
		"region_id TEXT PRIMARY KEY, level TEXT NOT NULL, name TEXT NOT NULL, "+
		"parent_region TEXT, "+
		"bbox_lon_min DOUBLE PRECISION, bbox_lat_min DOUBLE PRECISION, "+
		"bbox_lon_max DOUBLE PRECISION, bbox_lat_max DOUBLE PRECISION, "+
		"default_region BOOLEAN, datasource TEXT)")
}

// createDatasourceRegistry creates the TEMP routing_datasources that the
// per-datasource pools read their connection coordinates from (api_plans/06).
func createDatasourceRegistry(t *testing.T, db *sqlx.DB) {
	t.Helper()
	mustExec(t, db, "CREATE TEMP TABLE routing_datasources ("+
		"datasource_id TEXT PRIMARY KEY, host TEXT NOT NULL, port INTEGER NOT NULL, "+
		"dbname TEXT NOT NULL, db_user TEXT NOT NULL, label TEXT)")
}

// insertRegionVertices writes one region's vertices at the coordinates pin(id).
func insertRegionVertices(t *testing.T, db *sqlx.DB, regionID string, pin pinFn, ids ...int64) {
	t.Helper()
	for _, id := range ids {
		lat, lng := pin(id)
		mustExec(t, db, "INSERT INTO road_network_vertices_pgr (region_id, id, the_geom, lat, lng) "+
			"VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $4, $3)", regionID, id, lng, lat)
	}
}

// insertChain writes a one-directional hop chain (from -> from+1 -> ... -> to),
// numbering edges the way a per-extract import does.
func insertChain(t *testing.T, db *sqlx.DB, regionID string, from, to int64, hopCost float64) {
	t.Helper()
	for id, edge := from, from; edge < to; id, edge = id+1, edge+1 {
		mustExec(t, db, "INSERT INTO road_network_edges_pgr (region_id, id, source, target, cost) "+
			"VALUES ($1, $2, $2, $3, $4)", regionID, id, edge+1, hopCost)
	}
}

func seedRegionTables(t *testing.T) *sqlx.DB {
	t.Helper()
	db := connectPG(t)
	db.SetMaxOpenConns(1) // temp tables must stay visible to every repo query
	dropRegionTables(t, db, "road_network_edges_pgr", "road_network_vertices_pgr", "routing_regions")

	// Registry, shaped like plan 04's routing_regions. cr-sj is the default
	// region; parent_region/datasource are NULL on one row each so the COALESCE
	// mapping is exercised. Only the two rows these tests read are registered —
	// cr-lc's network exists below without a registry row, which is exactly how
	// an un-registered import behaves.
	createRegionRegistry(t, db)
	mustExec(t, db, "INSERT INTO routing_regions (region_id, level, name, parent_region, "+
		"bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max, default_region, datasource) VALUES "+
		"('cr', 'country', 'Costa Rica', NULL, -85.95, 7.98, -82.55, 11.22, FALSE, NULL), "+
		"('cr-sj', 'state', 'San Jose', 'cr', -0.001, 0.000, 0.001, 0.005, TRUE, NULL)")

	createRegionTables(t, db)
	insertRegionVertices(t, db, regionSJ, sjPin, 1, 2, 3, 4, 30)
	insertChain(t, db, regionSJ, 1, 4, 100)
	insertRegionVertices(t, db, regionLC, lcPin, 1, 2)
	insertChain(t, db, regionLC, 1, 2, 250)
	return db
}

func TestRegisteredRegions(t *testing.T) {
	db := seedRegionTables(t)
	repo := NewNavigationRepo(db)

	got, err := repo.RegisteredRegions()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d regions, want 2: %+v", len(got), got)
	}

	want := []struct {
		id, level, parent string
		isDefault         bool
	}{
		{"cr", "country", "", false},   // NULL parent -> ""
		{"cr-sj", "state", "cr", true}, // NULL datasource -> ""
	}
	for i, w := range want {
		g := got[i]
		if g.RegionID != w.id || g.Level != w.level || g.Parent != w.parent || g.Default != w.isDefault {
			t.Errorf("region[%d] = %+v, want id=%s level=%s parent=%q default=%v",
				i, g, w.id, w.level, w.parent, w.isDefault)
		}
		if g.Datasource != "" {
			t.Errorf("region[%d] datasource = %q, want the local pool (\"\")", i, g.Datasource)
		}
	}

	// The SJ row's bbox must survive the mapping as [lonMin, latMin, lonMax, latMax].
	sj := got[1]
	wantBox := [4]float64{-0.001, 0.000, 0.001, 0.005}
	for i := range wantBox {
		if sj.BBox[i] != wantBox[i] {
			t.Errorf("cr-sj bbox = %v, want %v", sj.BBox, wantBox)
			break
		}
	}
}

func TestSnapIsRegionScoped(t *testing.T) {
	db := seedRegionTables(t)
	// Radius 0 (the default): always snap, so a miss can only mean "no vertex
	// in that region". The snapshot's Lat/Lng — not its id, which is identical
	// in both regions — is what proves the WHERE region_id filter ran.
	repo := NewNavigationRepo(db)

	t.Run("pin_in_cr_sj", func(t *testing.T) {
		lat, lng := sjPin(2)
		snap, ok := repo.Snap(lat, lng, "", regionSJ)
		if !ok {
			t.Fatal("a pin on a cr-sj vertex must snap")
		}
		if snap.VertexID != 2 || snap.Lat != lat || snap.Lng != lng {
			t.Fatalf("snap = %+v, want cr-sj's v2 at (%v,%v)", snap, lat, lng)
		}
		if snap.DistanceM > 0.01 {
			t.Errorf("distance = %v m, want ~0 for a pin on the vertex", snap.DistanceM)
		}
	})

	t.Run("same_pin_in_cr_lc_never_reads_cr_sj", func(t *testing.T) {
		lat, lng := sjPin(2)
		snap, ok := repo.Snap(lat, lng, "", regionLC)
		if !ok {
			t.Fatal("cr-lc has vertices, so the pin must snap somewhere in it")
		}
		// Unscoped, this would answer with cr-sj's v2 at the pinned coords.
		if snap.Lat == lat && snap.Lng == lng {
			t.Fatalf("snap = %+v, read cr-sj's vertex from a cr-lc query", snap)
		}
		if snap.Lat < lcLatOffset || snap.Lng != lcLngOffset {
			t.Fatalf("snap = %+v, want a cr-lc vertex (lat >= %v, lng %v)", snap, lcLatOffset, lcLngOffset)
		}
		if snap.DistanceM < 3000 {
			t.Errorf("distance = %v m, want the kilometers across to cr-lc", snap.DistanceM)
		}
	})

	t.Run("unknown_region_is_not_covered", func(t *testing.T) {
		lat, lng := sjPin(1)
		if _, ok := repo.Snap(lat, lng, "", "no-such-region"); ok {
			t.Error("a region with no vertices must not report coverage")
		}
	})

	t.Run("unprovisioned_datasource_is_not_covered", func(t *testing.T) {
		lat, lng := sjPin(1)
		// With api_plans/06 a non-local region is no longer rejected on sight:
		// it is looked up in routing_datasources, and "d1" is not provisioned
		// here, so there is no pool to query and the region cannot cover a pin.
		// Same answer, new reason — see datasources_integration_test.go for the
		// provisioned case.
		if _, ok := repo.Snap(lat, lng, "d1", regionSJ); ok {
			t.Error("a region whose datasource has no pool must not report coverage")
		}
	})

	t.Run("radius_rejects_far_pin", func(t *testing.T) {
		lat, lng := sjPin(2)
		limited := NewNavigationRepo(db, 100)
		if _, ok := limited.Snap(lat+0.010, lng, "", regionSJ); ok {
			t.Error("a snap beyond ROUTING_SNAP_RADIUS_M must read as not covered")
		}
		// ... and the same repo still snaps the pin that sits on the vertex.
		if _, ok := limited.Snap(lat, lng, "", regionSJ); !ok {
			t.Error("an on-vertex pin must snap even with a radius configured")
		}
	})
}

func TestRouteInRegionNative(t *testing.T) {
	db := seedRegionTables(t)
	repo := NewNavigationRepo(db)

	t.Run("routes_the_region_topology", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := sjPin(4)
		got, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 4 {
			t.Fatalf("got %+v, want the 4-node cr-sj chain", got)
		}
		for i, id := range []int{1, 2, 3, 4} {
			if got[i].NodeID != id || got[i].NodeSeq != i {
				t.Errorf("node[%d] = %d (seq %d), want %d (seq %d)", i, got[i].NodeID, got[i].NodeSeq, id, i)
			}
		}
		if got[3].AggCost != 300 {
			t.Errorf("total cost = %v, want 300 m", got[3].AggCost)
		}
	})

	t.Run("routes_cr_lc_not_cr_sj", func(t *testing.T) {
		// Identical vertex ids, different topology and coordinates: the result
		// must be cr-lc's 1-2 edge (250 m), never cr-sj's 1-2-3-4 chain.
		fLat, fLng := lcPin(1)
		tLat, tLng := lcPin(2)
		got, err := repo.RouteInRegion(regionLC, "", fLat, fLng, tLat, tLng)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 2 || got[1].AggCost != 250 {
			t.Fatalf("got %+v, want cr-lc's single 250 m hop", got)
		}
		if got[0].Lat != fLat || got[0].Lng != fLng {
			t.Errorf("node coords = (%v,%v), want cr-lc's (%v,%v)", got[0].Lat, got[0].Lng, fLat, fLng)
		}
	})

	t.Run("unreachable_lone_vertex", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := sjPin(30)
		if _, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng); err != routing.ErrNoRoute {
			t.Fatalf("got %v, want %v", err, routing.ErrNoRoute)
		}
	})

	t.Run("unknown_region_errors", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := sjPin(2)
		_, err := repo.RouteInRegion("no-such-region", "", fLat, fLng, tLat, tLng)
		if err == nil {
			t.Fatal("a region with no imported network must error")
		}
	})
}

func TestRouteInRegionPGRouting(t *testing.T) {
	db := seedRegionTables(t)
	if !pgHasExtension(t, db) {
		t.Skip("pgRouting extension absent")
	}
	// Radius 1000 m: a dropoff that only exists in the other region is out of
	// snap range there, which is the cross-region rejection.
	repo := NewPGRoutingRepo(db, 1000)

	t.Run("routes_the_region_topology", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := sjPin(4)
		got, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		assertChain(t, got, []int64{1, 2, 3, 4}, 300)
		for i, n := range got {
			wantLat, wantLng := sjPin(int64(n.NodeID))
			if n.Lat != wantLat || n.Lng != wantLng {
				t.Errorf("node[%d] coords = (%v,%v), want cr-sj's (%v,%v)", i, n.Lat, n.Lng, wantLat, wantLng)
			}
		}
	})

	t.Run("routes_cr_lc_topology", func(t *testing.T) {
		fLat, fLng := lcPin(1)
		tLat, tLng := lcPin(2)
		got, err := repo.RouteInRegion(regionLC, "", fLat, fLng, tLat, tLng)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 2 || got[1].AggCost != 250 {
			t.Fatalf("got %+v, want cr-lc's single 250 m hop", got)
		}
		if got[0].Lat != fLat {
			t.Errorf("node coords = %v, want cr-lc's %v (ids collide across regions)", got[0].Lat, fLat)
		}
	})

	t.Run("dropoff_only_in_another_region", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := lcPin(2) // exists only in cr-lc, ~4.4 km from any cr-sj vertex
		_, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng)
		if !errors.Is(err, ErrPinUncovered) {
			t.Fatalf("got %v, want %v", err, ErrPinUncovered)
		}
	})

	t.Run("unreachable_lone_vertex", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := sjPin(30)
		if _, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng); err != routing.ErrNoRoute {
			t.Fatalf("got %v, want %v", err, routing.ErrNoRoute)
		}
	})

	t.Run("invalid_region_id_is_rejected_not_interpolated", func(t *testing.T) {
		fLat, fLng := sjPin(1)
		tLat, tLng := sjPin(2)
		// pgr_dijkstra takes the edges as a STATEMENT TEXT, so the region id is
		// interpolated. A hostile id must be refused before it reaches SQL.
		hostile := []string{
			"cr-sj'; DROP TABLE road_network_vertices_pgr; --",
			"' OR '1'='1",
			"",
			"cr sj",
			"cr-sj;",
		}
		for _, id := range hostile {
			if _, err := repo.RouteInRegion(id, "", fLat, fLng, tLat, tLng); err == nil {
				t.Errorf("region id %q was accepted", id)
			}
		}
		// The fixture is still there, so nothing above executed.
		if _, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng); err != nil {
			t.Fatalf("fixture broken after rejected ids: %v", err)
		}
	})
}

func TestValidRegionID(t *testing.T) {
	valid := []string{"cr", "cr-sj", "cr_lc", "us-ny-5", "A1"}
	for _, id := range valid {
		if !ValidRegionID(id) {
			t.Errorf("%q should be valid", id)
		}
	}
	invalid := []string{"", " ", "cr sj", "cr-sj'", "cr-sj;--", "cr/sj", "cr\"sj", "cr-sj;DROP TABLE x", "ñ"}
	for _, id := range invalid {
		if ValidRegionID(id) {
			t.Errorf("%q should be invalid", id)
		}
	}
}

// The two optional capabilities are what the service keys its region behavior
// on; assert both repos still satisfy the plain repository contract too.
func TestReposStillSatisfyNavigationRepository(t *testing.T) {
	db := seedRegionTables(t)
	var repos = []struct {
		name string
		repo NavigationRepository
	}{
		{"native", NewNavigationRepo(db, 0)},
		{"pgrouting", NewPGRoutingRepo(db, 0)},
	}
	for _, r := range repos {
		if _, err := r.repo.GetShortestPath(0.001, 0, 0.004, 0); err != nil {
			t.Errorf("%s: legacy GetShortestPath broke: %v", r.name, err)
		}
	}
}
