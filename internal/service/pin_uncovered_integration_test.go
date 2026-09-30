//go:build integration

package service

// End-to-end proof, on a live database, through the REAL repository and the
// REAL service: the two conditions the fix is about.
//
//   1. A pin the region resolver covered is ROUTED (never an error), even though
//      the engine's own haversine measures it past the radius.
//   2. A pin no region covers is an ESTIMATE (200 + is_estimate), never a 500 —
//      on the region path and on the legacy/unscoped path.
//
// Needs PostGIS (`docker compose up -d`). The tables are TEMP tables on a
// dedicated single-connection handle, so the real import is never touched and
// the graph is two vertices: the whole test runs in milliseconds.

import (
	"math"
	"testing"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/routing"
)

const (
	bandRegionID  = "cr-sj"
	bandRadiusM   = 50000.0
	bandVertexLat = 9.93
	bandVertexLng = -84.08
)

// seedServiceRegion builds a TEMP routing_regions row plus a two-vertex region
// network at the San Jose latitude, joined by one 1112 m edge.
func seedServiceRegion(t *testing.T) *sqlx.DB {
	t.Helper()
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1) // temp tables must stay visible to every repo query

	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(q, args...); err != nil {
			t.Fatalf("exec %q: %v", q, err)
		}
	}
	// Registered on t.Cleanup BEFORE the connection close would run... no: LIFO,
	// so drop first here is not possible. pg_temp tables die with the session.
	exec("CREATE TEMP TABLE road_network_vertices_pgr (" +
		"region_id TEXT NOT NULL, id BIGINT NOT NULL, the_geom GEOMETRY(Point,4326), " +
		"lat DOUBLE PRECISION NOT NULL, lng DOUBLE PRECISION NOT NULL, " +
		"elevation_m DOUBLE PRECISION, elevation_source TEXT, " +
		"PRIMARY KEY (region_id, id))")
	exec("CREATE INDEX ON road_network_vertices_pgr USING GIST (the_geom)")
	exec("CREATE TEMP TABLE road_network_edges_pgr (" +
		"region_id TEXT NOT NULL, id BIGINT NOT NULL, source BIGINT, target BIGINT, " +
		"cost DOUBLE PRECISION, PRIMARY KEY (region_id, id))")
	exec("CREATE TEMP TABLE routing_regions (" +
		"region_id TEXT PRIMARY KEY, level TEXT NOT NULL, name TEXT NOT NULL, " +
		"parent_region TEXT, bbox_lon_min DOUBLE PRECISION, bbox_lat_min DOUBLE PRECISION, " +
		"bbox_lon_max DOUBLE PRECISION, bbox_lat_max DOUBLE PRECISION, " +
		"default_region BOOLEAN, datasource TEXT)")
	exec("INSERT INTO routing_regions (region_id, level, name, parent_region, "+
		"bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max, default_region, datasource) "+
		"VALUES ('cr-sj', 'state', 'San Jose', NULL, -84.50, 9.00, -83.50, 10.20, TRUE, NULL)")

	for id, lat := range map[int64]float64{1: bandVertexLat, 2: bandVertexLat + 0.01} {
		exec("INSERT INTO road_network_vertices_pgr (region_id, id, the_geom, lat, lng) "+
			"VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $4, $3)",
			bandRegionID, id, bandVertexLng, lat)
	}
	exec("INSERT INTO road_network_edges_pgr (region_id, id, source, target, cost) "+
		"VALUES ($1, 1, 1, 2, 1112)", bandRegionID)
	return db
}

// pinSouthOfBandVertex builds a pin the ENGINE measures targetM from the region's
// first vertex (bisection on the haversine distance).
func pinSouthOfBandVertex(targetM float64) (lat, lng float64) {
	lo, hi := 0.0, 5.0
	for i := 0; i < 200; i++ {
		mid := (lo + hi) / 2
		if routing.HaversineMeters(bandVertexLat, bandVertexLng, bandVertexLat-mid, bandVertexLng) < targetM {
			lo = mid
		} else {
			hi = mid
		}
	}
	return bandVertexLat - (lo+hi)/2, bandVertexLng
}

// A pin PostGIS calls covered must come back as a ROUTE through the whole real
// stack. This is the pin that answered 500 before the fix.
func TestRealCoveredBandPinRoutesInsteadOfFailing(t *testing.T) {
	db := seedServiceRegion(t)
	svc := NewNavigationService(repository.NewNavigationRepo(db, bandRadiusM))

	lat, lng := pinSouthOfBandVertex(50113)
	dropLat, dropLng := bandVertexLat+0.01, bandVertexLng

	got, err := svc.GetRoute(lat, lng, dropLat, dropLng)
	if err != nil {
		t.Fatalf("a pin the region resolver covered answered %v; it must be a route, not a 500", err)
	}
	if got.IsEstimate {
		t.Error("the resolver covered this pin, so it must not degrade to an estimate")
	}
	if got.DistanceMeters <= 0 {
		t.Errorf("distance = %d m, want the road route", got.DistanceMeters)
	}
	t.Logf("covered band pin routed: %d m in %d s over %d polyline points",
		got.DistanceMeters, got.DurationSecs, len(got.Polyline))
}

// A pin 60 km from the road is not covered by anything: the honest answer is the
// straight-line estimate, on BOTH paths. Not a 500, and not a snapped route
// 60 km away.
func TestRealUncoveredPinIsAnEstimateOnBothPaths(t *testing.T) {
	db := seedServiceRegion(t)
	repo := repository.NewNavigationRepo(db, bandRadiusM)
	svc := NewNavigationService(repo)

	lat, lng := pinSouthOfBandVertex(60000)
	dropLat, dropLng := lat+0.01, lng+0.01

	// Region path: the resolver finds nothing, so the router is never reached.
	got, err := svc.GetRoute(lat, lng, dropLat, dropLng)
	if err != nil {
		t.Fatalf("an uncovered pin answered %v, not an estimate", err)
	}
	if !got.IsEstimate {
		t.Error("a pin no region covers must answer is_estimate")
	}
	if want := int(math.Round(routing.HaversineMeters(lat, lng, dropLat, dropLng))); got.DistanceMeters != want {
		t.Errorf("distance = %d m, want the straight line %d m", got.DistanceMeters, want)
	}

	// Legacy path: nothing resolved these pins, so the repository's own snap
	// gate decides — and its answer is a data gap, which is an estimate here
	// too (this is the path that had no estimate branch at all).
	legacy, err := svc.legacyRoute(lat, lng, dropLat, dropLng)
	if err != nil {
		t.Fatalf("an uncovered pin on the unscoped path answered %v, not an estimate", err)
	}
	if !legacy.IsEstimate {
		t.Error("the unscoped path must answer is_estimate for an uncovered pin")
	}
	if legacy.DistanceMeters != got.DistanceMeters {
		t.Errorf("unscoped distance = %d m, want the same straight line %d m", legacy.DistanceMeters, got.DistanceMeters)
	}
}
