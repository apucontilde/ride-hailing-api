//go:build integration

package repository

import (
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/routing"
)

// seedElevationTestGraph creates a temp vertices/edges pair with the 014
// elevation columns, so the repo's load path reads real samples without touching
// the live SJ import (same technique as seedPGRTestGraph).
//
//	vertices: 1 (elev 100), 2 (elev 0 = sea level), 3 (elev NULL = no sample)
//	edges:    1-2 (100 m), 2-3 (100 m) — a plain chain
func seedElevationTestGraph(t *testing.T) *sqlx.DB {
	t.Helper()
	db := connectPG(t)
	db.SetMaxOpenConns(1)
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

	mustExec(t, db, "INSERT INTO road_network_vertices_pgr (id, the_geom, lat, lng, elevation_m, elevation_source) VALUES "+
		"(1, ST_SetSRID(ST_MakePoint(0, 0.001), 4326), 0.001, 0, 100, 'skadi:N09W085'), "+
		"(2, ST_SetSRID(ST_MakePoint(0, 0.002), 4326), 0.002, 0, 0,    'skadi:N09W085'), "+
		"(3, ST_SetSRID(ST_MakePoint(0, 0.003), 4326), 0.003, 0, NULL,  NULL)")
	mustExec(t, db, "INSERT INTO road_network_edges_pgr (id, source, target, cost) VALUES "+
		"(1, 1, 2, 100), (2, 2, 3, 100)")
	return db
}

// TestNativeRepoElevationLoaded verifies the graph builder reads elevation_m:
// the two non-NULL samples are "known", the NULL vertex is "unknown" (EleM 0 and
// excluded from coverage). At MinCoverage 0.99, 2-of-3 coverage is BELOW the
// gate, so routing falls back to flat.
func TestNativeRepoElevationLoaded(t *testing.T) {
	db := seedElevationTestGraph(t)

	// Default: elevation off (zero config) -> weights resolve flat.
	flat := newNativeRepo(db, nil, 0)
	got, err := flat.GetShortestPath(0.001, 0, 0.003, 0)
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("flat route length = %d, want 3", len(got))
	}
	// Flat: total meters = 200 (two 100 m hops), and AggCost == meters.
	if got[len(got)-1].AggCost != 200 {
		t.Errorf("flat AggCost = %v, want 200", got[len(got)-1].AggCost)
	}

	// Enabled but 2-of-3 = 0.67 < 0.99: still flat (degrade, never garbage).
	gated := newNativeRepo(db, nil, 0).configureElevation(
		routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		true, 0.99,
	)
	got, err = gated.GetShortestPath(0.001, 0, 0.003, 0)
	if err != nil {
		t.Fatalf("gated route: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("gated route length = %d, want 3", len(got))
	}
	if got[len(got)-1].AggCost != 200 {
		t.Errorf("gated (below coverage) AggCost = %v, want 200", got[len(got)-1].AggCost)
	}
}

// TestNativeRepoAggCostIsMeters is the invariant test: even when elevation is
// active, the reported AggCost is the true road METERS, never the weighted cost.
func TestNativeRepoAggCostIsMeters(t *testing.T) {
	db := seedElevationTestGraph(t)
	// Full coverage (all three known) lets the gate pass.
	mustExec(t, db, "UPDATE road_network_vertices_pgr SET elevation_m = 0 WHERE id = 3")

	repo := newNativeRepo(db, nil, 0).configureElevation(
		routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 0},
		true, 0.99,
	)
	got, err := repo.GetShortestPath(0.001, 0, 0.003, 0)
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	// Two 100 m hops = 200 meters regardless of the elevation cost model.
	if got[len(got)-1].AggCost != 200 {
		t.Errorf("AggCost = %v, want 200 (true meters, never weighted cost)", got[len(got)-1].AggCost)
	}
	// Additive elevation totals ride on the last row (stage 01): the route drops
	// from 100 m to 0 m, so it descends 100 m and climbs nothing.
	last := got[len(got)-1]
	if !last.ElevationAware {
		t.Error("ElevationAware = false, want true (full coverage, elevation on)")
	}
	if last.AscentM != 0 || last.DescentM != 100 {
		t.Errorf("ascent/descent = %v/%v, want 0/100", last.AscentM, last.DescentM)
	}
}

// TestNativeRepoFlatWhenElevationOff pins the default-off contract: a fully
// populated elevation column changes nothing when Enabled=false.
func TestNativeRepoFlatWhenElevationOff(t *testing.T) {
	db := seedElevationTestGraph(t)

	off := newNativeRepo(db, nil, 0) // no configureElevation -> elevOn false
	got, err := off.GetShortestPath(0.001, 0, 0.003, 0)
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if got[len(got)-1].AggCost != 200 {
		t.Errorf("default-off AggCost = %v, want 200", got[len(got)-1].AggCost)
	}
	// Default off: the additive fields must not claim elevation awareness.
	last := got[len(got)-1]
	if last.ElevationAware || last.AscentM != 0 || last.DescentM != 0 {
		t.Errorf("default-off elevation totals = aware=%v ascent=%v descent=%v, want false/0/0",
			last.ElevationAware, last.AscentM, last.DescentM)
	}
}
