//go:build integration

package repository

import (
	"testing"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/routing"
)

// These tests need a live PostGIS+pgRouting DB (`docker compose up -d`). They
// seed the SAME-NAMED tables as TEMP tables on a dedicated single-connection
// handle, so the session's unqualified table references (snap, route, and the
// static edges_sql inside pgr_dijkstra) resolve to the tiny fixture instead of
// the real import. A real SJ graph is never touched.

func connectPG(t *testing.T) *sqlx.DB {
	t.Helper()
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func mustExec(t *testing.T, db *sqlx.DB, q string, args ...any) {
	t.Helper()
	if _, err := db.Exec(q, args...); err != nil {
		t.Fatalf("exec error: %v (query: %s)", err, q)
	}
}

func pgHasExtension(t *testing.T, db *sqlx.DB) bool {
	t.Helper()
	var present bool
	if err := db.Get(&present, "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pgrouting')"); err != nil {
		t.Fatalf("extension check failed: %v", err)
	}
	return present
}

// seedPGRTestGraph creates temp pgr tables containing:
//
//	component A (chain):   1-2-3-4, 100 m per hop
//	component B (remote):  20-21, 50 m
//	lone vertex:           30 (no edges)
//
// Vertex id N sits at (lat = N*0.001, lng = 0), so pinning a query exactly on
// a vertex coordinate snaps with zero distance and no index-tie ambiguity.
func seedPGRTestGraph(t *testing.T) *sqlx.DB {
	t.Helper()
	db := connectPG(t)
	db.SetMaxOpenConns(1) // temp tables must stay visible to every repo query
	t.Cleanup(func() {
		_, _ = db.Exec("DROP TABLE IF EXISTS road_network_vertices_pgr")
		_, _ = db.Exec("DROP TABLE IF EXISTS road_network_edges_pgr")
	})

	mustExec(t, db, "CREATE TEMP TABLE road_network_vertices_pgr ("+
		"id BIGINT PRIMARY KEY, the_geom GEOMETRY(Point,4326), "+
		"lat DOUBLE PRECISION NOT NULL, lng DOUBLE PRECISION NOT NULL, "+
		"elevation_m DOUBLE PRECISION, elevation_source TEXT)")
	mustExec(t, db, "CREATE TEMP TABLE road_network_edges_pgr ("+
		"id BIGINT PRIMARY KEY, source BIGINT, target BIGINT, cost DOUBLE PRECISION)")
	mustExec(t, db, "CREATE INDEX ON road_network_vertices_pgr USING GIST (the_geom)")

	for _, id := range []int64{1, 2, 3, 4, 20, 21, 30} {
		lat := float64(id) * 0.001
		mustExec(t, db, "INSERT INTO road_network_vertices_pgr (id, the_geom, lat, lng) "+
			"VALUES ($1, ST_SetSRID(ST_MakePoint(0, $2), 4326), $2, 0)", id, lat)
	}
	edges := []struct {
		id, s, t int64
		cost     float64
	}{
		{1, 1, 2, 100}, {2, 2, 3, 100}, {3, 3, 4, 100},
		{4, 20, 21, 50},
	}
	for _, e := range edges {
		mustExec(t, db, "INSERT INTO road_network_edges_pgr (id, source, target, cost) "+
			"VALUES ($1, $2, $3, $4)", e.id, e.s, e.t, e.cost)
	}
	return db
}

func TestPGRoutingRepoGetShortestPath(t *testing.T) {
	db := seedPGRTestGraph(t)
	repo := NewPGRoutingRepo(db, 0)

	// v1 at lat 0.001, v4 at lat 0.004.
	pin := func(v int64) (lat, lng float64) { return float64(v) * 0.001, 0 }

	t.Run("same_vid", func(t *testing.T) {
		lat, lng := pin(2)
		got, err := repo.GetShortestPath(lat, lng, lat, lng)
		if err != nil {
			t.Fatalf("same-vid must not error: %v", err)
		}
		if len(got) != 1 || got[0].NodeID != 2 || got[0].AggCost != 0 {
			t.Fatalf("got %+v, want single 0-cost v2 point", got)
		}
	})

	t.Run("one_hop", func(t *testing.T) {
		fLat, fLng := pin(1)
		tLat, tLng := pin(2)
		got, err := repo.GetShortestPath(fLat, fLng, tLat, tLng)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		assertChain(t, got, []int64{1, 2}, 100)
	})

	t.Run("multi_hop", func(t *testing.T) {
		fLat, fLng := pin(1)
		tLat, tLng := pin(4)
		got, err := repo.GetShortestPath(fLat, fLng, tLat, tLng)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		assertChain(t, got, []int64{1, 2, 3, 4}, 300)
	})

	t.Run("no_route_across_components", func(t *testing.T) {
		fLat, fLng := pin(1)
		tLat, tLng := pin(20)
		_, err := repo.GetShortestPath(fLat, fLng, tLat, tLng)
		if err != routing.ErrNoRoute {
			t.Fatalf("want %v, got %v", routing.ErrNoRoute, err)
		}
	})

	t.Run("empty_dijkstra_lone_vertex", func(t *testing.T) {
		fLat, fLng := pin(1)
		tLat, tLng := pin(30)
		_, err := repo.GetShortestPath(fLat, fLng, tLat, tLng)
		if err != routing.ErrNoRoute {
			t.Fatalf("want %v, got %v", routing.ErrNoRoute, err)
		}
	})
}

// assertChain asserts an exact node sequence whose total cost is wantAgg
// (hop-cost 100 in the fixture).
func assertChain(t *testing.T, got []RouteResult, wantNodes []int64, wantAgg float64) {
	t.Helper()
	if len(got) != len(wantNodes) {
		t.Fatalf("length %d != %d: %+v", len(got), len(wantNodes), got)
	}
	for i, id := range wantNodes {
		if got[i].NodeID != int(id) {
			t.Errorf("node[%d] = %d, want %d", i, got[i].NodeID, id)
		}
		if got[i].NodeSeq != i {
			t.Errorf("nodeseq[%d] = %d, want %d", i, got[i].NodeSeq, i)
		}
		if got[i].AggCost > 0 && i == 0 {
			t.Errorf("first node of a non-trivial route should have agg_cost 0, got %v", got[i].AggCost)
		}
	}
	if got[len(got)-1].AggCost != wantAgg {
		t.Errorf("total agg_cost = %v, want %v", got[len(got)-1].AggCost, wantAgg)
	}
}

func TestPGRoutingRepoSnapRadius(t *testing.T) {
	db := seedPGRTestGraph(t)

	// A pin ~1 degree from every vertex is "not covered" when a radius is set.
	covered := NewPGRoutingRepo(db, 0)
	uncovered := NewPGRoutingRepo(db, 1000)

	if _, err := uncovered.GetShortestPath(1.0, 1.0, 2.0, 2.0); err != routing.ErrNoRoute {
		t.Fatalf("far pin with radius 1000: want %v, got %v", routing.ErrNoRoute, err)
	}

	// With the radius disabled the same far pins still snap (to the nearest,
	// which happens to be the same vertex -> the 0-length path), matching the
	// native engine's always-snap behavior.
	got, err := covered.GetShortestPath(1.0, 1.0, 2.0, 2.0)
	if err != nil {
		t.Fatalf("radius disabled should snap, got error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want a single 0-length point from the shared nearest snap, got %+v", got)
	}
}

func TestNewRoutingRepository(t *testing.T) {
	db := connectPG(t)
	hasPGR := pgHasExtension(t, db)

	cases := []struct {
		name string
		cfg  *config.Config
		want any
	}{
		{"default_native", &config.Config{}, (*NativeNavigationRepo)(nil)},
		{"bogus_engine_native", &config.Config{RoutingEngine: "bogus"}, (*NativeNavigationRepo)(nil)},
		{"explicit_native", &config.Config{RoutingEngine: "native"}, (*NativeNavigationRepo)(nil)},
	}
	if hasPGR {
		cases = append(cases, struct {
			name string
			cfg  *config.Config
			want any
		}{"pgrouting_when_present", &config.Config{RoutingEngine: "pgrouting"}, (*PGRoutingRepo)(nil)})
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := NewRoutingRepository(db, tc.cfg)
			if repo == nil {
				t.Fatal("factory returned nil repo")
			}
			if _, ok := repo.(*NativeNavigationRepo); tc.want == (*NativeNavigationRepo)(nil) && !ok {
				t.Errorf("want native repo, got %T", repo)
			}
			if _, ok := repo.(*PGRoutingRepo); tc.want == (*PGRoutingRepo)(nil) && !ok {
				t.Errorf("want pgrouting repo, got %T", repo)
			}
		})
	}
}
