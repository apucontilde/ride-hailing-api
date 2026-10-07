package repository

import (
	"math"
	"sort"
	"testing"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/routing"
)

// DB-free unit tests for the elevation plumbing's pure helpers: the NULL ->
// "unknown" (EleM 0) conversion, the coverage/known accounting, and the
// NULL-endpoint fix-up that keeps an unknown vertex from reading as sea level
// beside a real altitude (Part 3a).

func TestToRoutingNodesNULLvsZero(t *testing.T) {
	ele100 := 100.0
	zero := 0.0
	rows := []roadNode{
		{ID: 1, Lat: 1, Lng: 1, EleM: &ele100}, // real sample
		{ID: 2, Lat: 2, Lng: 2, EleM: &zero},   // sea level
		{ID: 3, Lat: 3, Lng: 3, EleM: nil},     // no sample
	}
	nodes, known := toRoutingNodes(rows)

	if len(nodes) != 3 {
		t.Fatalf("got %d nodes, want 3", len(nodes))
	}
	if nodes[0].EleM != 100 {
		t.Errorf("node 1 EleM = %v, want 100", nodes[0].EleM)
	}
	if nodes[1].EleM != 0 {
		t.Errorf("node 2 EleM = %v, want 0", nodes[1].EleM)
	}
	if nodes[2].EleM != 0 {
		t.Errorf("node 3 EleM = %v, want 0 (unknown)", nodes[2].EleM)
	}
	// Only the two non-NULL rows are "known" — sea level counts, no-sample does not.
	if !known[1] || !known[2] || known[3] {
		t.Errorf("known = %v; want {1:true, 2:true, 3:false}", known)
	}
}

func TestFillUnknownElevationPropagatesKnownNeighbour(t *testing.T) {
	nodes := []routing.Node{
		{ID: 1, EleM: 100}, // known
		{ID: 2, EleM: 0},   // unknown
		{ID: 3, EleM: 50},  // known
	}
	edges := []routing.Edge{
		{Source: 1, Target: 2, Cost: 10},
		{Source: 2, Target: 3, Cost: 10},
	}
	known := map[int64]bool{1: true, 3: true}

	fillUnknownElevation(nodes, edges, known)

	// Node 2's two known neighbours average to 75.
	if nodes[1].EleM != 75 {
		t.Errorf("node 2 EleM = %v, want 75", nodes[1].EleM)
	}
	// Known nodes are untouched.
	if nodes[0].EleM != 100 || nodes[2].EleM != 50 {
		t.Errorf("known nodes mutated: %v", nodes)
	}
}

func TestFillUnknownElevationNoKnownNeighbourKeepsZero(t *testing.T) {
	nodes := []routing.Node{
		{ID: 1, EleM: 0}, // unknown
		{ID: 2, EleM: 0}, // unknown
	}
	edges := []routing.Edge{{Source: 1, Target: 2, Cost: 10}}
	known := map[int64]bool{}

	fillUnknownElevation(nodes, edges, known)

	for i, n := range nodes {
		if n.EleM != 0 {
			t.Errorf("node %d EleM = %v, want 0 (no known neighbour)", i, n.EleM)
		}
	}
}

// TestRoutingElevationDefaultOnAtWiringBoundary pins "ON by default" at the
// production wiring boundary, not just in config.Load(): the engine factory must
// hand the native repo elevation enabled with the measured operating point. The
// audit found this gap — the config default was tested, but nothing asserted the
// factory honoured it. (Lives here, not in config_test.go, because config cannot
// import repository without a cycle.)
func TestRoutingElevationDefaultOnAtWiringBoundary(t *testing.T) {
	for _, k := range []string{
		"ROUTING_ENGINE", "ROUTING_ELEVATION", "ROUTING_ASCENT_WEIGHT",
		"ROUTING_DESCENT_WEIGHT", "ROUTING_MAX_GRADE", "ROUTING_ELEV_DEADBAND_M",
		"ROUTING_ELEV_MIN_COVERAGE",
	} {
		t.Setenv(k, "")
	}

	repo, ok := NewRoutingRepository(nil, config.Load()).(*NativeNavigationRepo)
	if !ok {
		t.Fatalf("factory did not return the native repo for a zero config")
	}
	if !repo.elevOn {
		t.Error("elevOn = false at the wiring boundary, want true (the flip made it the default)")
	}
	want := routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}
	if repo.elev != want {
		t.Errorf("wired weights = %+v, want %+v", repo.elev, want)
	}
}

func TestResolveElevationGate(t *testing.T) {
	// A repo with elevation configured but inactive config must resolve to flat.
	r := &NativeNavigationRepo{
		elevOn:   false,
		elev:     routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		minCover: 0.99,
	}
	nodes := []routing.Node{{ID: 1, EleM: 100}, {ID: 2, EleM: 110}}
	edges := []routing.Edge{{Source: 1, Target: 2, Cost: 10}}
	known := map[int64]bool{1: true, 2: true}

	if w := r.resolveElevation(nodes, edges, known); w != (routing.CostWeights{}) {
		t.Errorf("disabled config resolved to non-flat weights %+v", w)
	}

	// Enabled + full coverage -> the configured weights.
	r.elevOn = true
	if w := r.resolveElevation(nodes, edges, known); w != r.elev {
		t.Errorf("enabled full coverage resolved to %+v, want %+v", w, r.elev)
	}

	// Enabled but zero coverage -> flat.
	if w := r.resolveElevation(nodes, edges, map[int64]bool{}); w != (routing.CostWeights{}) {
		t.Errorf("zero coverage resolved to non-flat weights %+v", w)
	}
}

// The certified-flat-street deadband estimator (gate G6) is a pure statistic,
// so every property below is asserted with no database.

func TestFlatEdgeDeadbandEmptyFallsBack(t *testing.T) {
	for _, in := range [][]float64{nil, {}, {math.NaN()}, {math.Inf(1), math.Inf(-1)}} {
		got := flatEdgeDeadbandM(in)
		if got != flatEdgeDeadbandFallbackM {
			t.Errorf("flatEdgeDeadbandM(%v) = %v, want fallback %v", in, got, flatEdgeDeadbandFallbackM)
		}
		if math.IsNaN(got) || math.IsInf(got, 0) {
			t.Fatalf("fallback is non-finite: %v", got)
		}
	}
}

func TestFlatEdgeDeadbandIsP95(t *testing.T) {
	// 1..20 => nearest-rank p95 index int(0.95*19)=18 => value 19.
	vals := make([]float64, 20)
	for i := range vals {
		vals[i] = float64(i + 1)
	}
	if got := flatEdgeDeadbandM(vals); got != 19 {
		t.Errorf("flatEdgeDeadbandM(1..20) = %v, want 19 (p95)", got)
	}
}

func TestFlatEdgeDeadbandCleanVsNoisy(t *testing.T) {
	clean := make([]float64, 100)
	for i := range clean {
		clean[i] = 0.05 * float64(i%10) // 0..0.45, a clean flat street
	}
	noisy := append([]float64(nil), clean...)
	for i := 0; i < 20; i++ {
		noisy[i] = 5 + float64(i) // a fat noise tail on the same set
	}

	cd := flatEdgeDeadbandM(clean)
	nd := flatEdgeDeadbandM(noisy)
	if cd <= 0 {
		t.Errorf("clean deadband = %v, want > 0", cd)
	}
	if nd < cd {
		t.Errorf("noisy deadband %v < clean %v (monotonicity violated)", nd, cd)
	}
}

func TestFlatEdgeDeadbandMonotonicUnderNoise(t *testing.T) {
	base := make([]float64, 200)
	for i := range base {
		base[i] = 1.0
	}
	prev := flatEdgeDeadbandM(base)
	for _, bump := range []float64{0, 0.5, 1, 2, 4, 8} {
		next := append([]float64(nil), base...)
		for i := range next {
			next[i] += bump
		}
		got := flatEdgeDeadbandM(next)
		if got < prev {
			t.Errorf("deadband fell as noise rose: bump %v -> %v, previous %v", bump, got, prev)
		}
		prev = got
	}
}

func TestFlatEdgeDeadbandIgnoresNonFiniteAndSign(t *testing.T) {
	vals := []float64{-1, 2, math.NaN(), -3, math.Inf(1)}
	// Magnitudes {1,2,3}, nearest-rank p95 index int(0.95*2)=1 => 2.
	if got := flatEdgeDeadbandM(vals); got != 2 {
		t.Errorf("flatEdgeDeadbandM = %v, want 2 (|Δz| p95 of 1,2,3)", got)
	}
}

func TestSampleQuantileNearestRank(t *testing.T) {
	v := []float64{5, 1, 4, 2, 3}
	if got := sampleQuantile(v, 0.5); got != 3 {
		t.Errorf("sampleQuantile(median) = %v, want 3", got)
	}
	if got := sampleQuantile(v, 0); got != 1 {
		t.Errorf("sampleQuantile(0) = %v, want 1", got)
	}
	if got := sampleQuantile(v, 1); got != 5 {
		t.Errorf("sampleQuantile(1) = %v, want 5", got)
	}
}

// flatEdgeAbsDz certifies terrain, not edges: a short edge is a sample only
// when the 3×3-cell (~330 m) local relief around BOTH endpoints is low. The
// steep cluster, the long edge and the unknown-endpoint edge must all be
// rejected — otherwise the estimator would read real relief as DEM noise.
func TestFlatEdgeAbsDzCertifiesFlatTerrain(t *testing.T) {
	e := func(v float64) *float64 { return &v }
	verts := []roadNode{
		{ID: 1, Lat: 10.0000, Lng: -84.0000, EleM: e(100)},
		{ID: 2, Lat: 10.0003, Lng: -84.0000, EleM: e(101)},
		{ID: 3, Lat: 10.0006, Lng: -84.0000, EleM: e(105)},
		// a steep cluster far from the flat one (no 3×3 overlap).
		{ID: 4, Lat: 11.0000, Lng: -84.0000, EleM: e(1000)},
		{ID: 5, Lat: 11.0003, Lng: -84.0000, EleM: e(1100)},
		{ID: 6, Lat: 11.0006, Lng: -84.0000, EleM: e(1300)},
		// a distant vertex in the flat band, only reachable by a long edge.
		{ID: 7, Lat: 10.0000, Lng: -84.0100, EleM: e(100)},
		// an endpoint with no DEM sample.
		{ID: 8, Lat: 10.0000, Lng: -84.0009, EleM: nil},
	}
	edges := []roadEdge{
		{Source: 1, Target: 2, Cost: 33},
		{Source: 2, Target: 3, Cost: 33},
		{Source: 4, Target: 5, Cost: 33},   // steep terrain -> rejected
		{Source: 1, Target: 7, Cost: 1000}, // long edge -> rejected
		{Source: 1, Target: 8, Cost: 30},   // unknown endpoint -> rejected
	}

	got := flatEdgeAbsDz(verts, edges)
	sort.Float64s(got)
	want := []float64{1, 4}
	if len(got) != len(want) {
		t.Fatalf("flatEdgeAbsDz = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("flatEdgeAbsDz[%d] = %v, want %v (full %v)", i, got[i], want[i], got)
		}
	}
}

func TestFlatEdgeAbsDzEmpty(t *testing.T) {
	if got := flatEdgeAbsDz(nil, nil); len(got) != 0 {
		t.Errorf("flatEdgeAbsDz(nil,nil) = %v, want empty", got)
	}
}
