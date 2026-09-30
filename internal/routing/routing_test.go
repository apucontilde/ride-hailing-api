package routing

import (
	"errors"
	"math"
	"math/rand"
	"testing"
)

// Test graph geometry:
//
//	A(10.0,10.0) --11132m--> B(10.1,10.0) --11132m--> C(10.1,10.1)
//	                   \
//	                    11132m
//	                     \
//	                      D(10.2,10.0)
//
//	X(20.0,20.0)  -- isolated node, no edges.
func testGraph() *Graph {
	nodes := []Node{
		{ID: 1, Lat: 10.0, Lng: 10.0}, // A
		{ID: 2, Lat: 10.1, Lng: 10.0}, // B
		{ID: 3, Lat: 10.1, Lng: 10.1}, // C
		{ID: 4, Lat: 10.2, Lng: 10.0}, // D
		{ID: 5, Lat: 20.0, Lng: 20.0}, // X
	}
	edges := []Edge{
		{Source: 1, Target: 2, Cost: 11132},
		{Source: 2, Target: 1, Cost: 11132},
		{Source: 2, Target: 3, Cost: 11132},
		{Source: 1, Target: 4, Cost: 22264},
	}
	return NewGraph(nodes, edges)
}

func TestRouteDirectNeighbor(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.1, 10.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 2 || path[0] != 1 || path[1] != 2 {
		t.Fatalf("expected path [1 2], got %v", path)
	}
	if cost != 11132 {
		t.Fatalf("expected cost 11132, got %v", cost)
	}
}

func TestRouteMultiHop(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.1, 10.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 3 || path[0] != 1 || path[1] != 2 || path[2] != 3 {
		t.Fatalf("expected path [1 2 3], got %v", path)
	}
	if cost != 22264 {
		t.Fatalf("expected cost 22264, got %v", cost)
	}
}

func TestRoutePicksCheapestOfTwo(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.2, 10.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 2 || path[0] != 1 || path[1] != 4 {
		t.Fatalf("expected path [1 4], got %v", path)
	}
	if cost != 22264 {
		t.Fatalf("expected cost 22264, got %v", cost)
	}
}

func TestRouteUnreachable(t *testing.T) {
	g := testGraph()
	_, _, err := g.Route(10.0, 10.0, 20.0, 20.0)
	if !errors.Is(err, ErrNoRoute) {
		t.Fatalf("expected ErrNoRoute, got %v", err)
	}
}

func TestRouteSameStartEnd(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.0, 10.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 1 || path[0] != 1 {
		t.Fatalf("expected path [1], got %v", path)
	}
	if cost != 0 {
		t.Fatalf("expected zero cost, got %v", cost)
	}
}

func TestRouteEmptyGraph(t *testing.T) {
	g := NewGraph(nil, nil)
	_, _, err := g.Route(10.0, 10.0, 10.1, 10.1)
	if !errors.Is(err, ErrNoRoute) {
		t.Fatalf("expected ErrNoRoute on empty graph, got %v", err)
	}
}

func TestNearestNode(t *testing.T) {
	g := testGraph()
	n, ok := g.NearestNode(10.05, 10.01)
	if !ok {
		t.Fatal("expected a nearest node")
	}
	if n.ID != 2 {
		t.Fatalf("expected node 2, got %d", n.ID)
	}
}

// grid3x3 returns a 3x3 lattice of nodes with no edges, exercising multiple
// cells and cell boundaries.
func grid3x3() *Graph {
	var nodes []Node
	for i := 0; i < 3; i++ {
		for j := 0; j < 3; j++ {
			nodes = append(nodes, Node{
				ID:  int64(i*3 + j + 1),
				Lat: 10.0 + float64(i)*0.1,
				Lng: 10.0 + float64(j)*0.1,
			})
		}
	}
	return NewGraph(nodes, nil)
}

func TestNearestNodeGridEquivalent(t *testing.T) {
	grids := map[string]*Graph{
		"testGraph": testGraph(),
		"grid3x3":   grid3x3(),
	}
	points := []struct {
		lat, lng float64
	}{
		{10.05, 10.01},   // interior
		{10.0, 10.0},     // exactly on a node
		{10.055, 10.055}, // near a cell corner
		{10.19, 10.01},   // near the bbox edge
		{10.2, 10.2},     // on bbox max corner
	}
	for name, g := range grids {
		for _, p := range points {
			want, wantOK := g.scanNearest(p.lat, p.lng)
			got, gotOK := g.gridNearest(p.lat, p.lng)
			if wantOK != gotOK {
				t.Fatalf("%s: point (%.4f,%.4f): scan ok=%v grid ok=%v", name, p.lat, p.lng, wantOK, gotOK)
			}
			if wantOK && (got.ID != want.ID) {
				t.Fatalf("%s: point (%.4f,%.4f): scan=%d grid=%d", name, p.lat, p.lng, want.ID, got.ID)
			}
		}
	}
}

func TestNearestNodeGridEquivalentRandom(t *testing.T) {
	grids := map[string]*Graph{
		"testGraph": testGraph(),
		"grid3x3":   grid3x3(),
	}
	// Deterministic sweep across the bbox and beyond, including points that
	// hash to clamped border cells or far outside the grid.
	for name, g := range grids {
		for i := 0; i < 500; i++ {
			lat := 8.0 + float64(i%37)*0.4
			lng := 9.5 + float64(i%29)*0.5
			want, wantOK := g.scanNearest(lat, lng)
			got, gotOK := g.gridNearest(lat, lng)
			if wantOK != gotOK {
				t.Fatalf("%s: point (%.4f,%.4f): scan ok=%v grid ok=%v", name, lat, lng, wantOK, gotOK)
			}
			if wantOK && (got.ID != want.ID) {
				t.Fatalf("%s: point (%.4f,%.4f): scan=%d grid=%d", name, lat, lng, want.ID, got.ID)
			}
		}
	}
}

func TestNearestNodeGridOutOfBounds(t *testing.T) {
	g := testGraph()
	for _, p := range []struct{ lat, lng float64 }{
		{30.0, 30.0},   // far outside the bbox
		{5.0, 5.0},     // below the bbox
		{-10.0, 40.0},  // mixed out-of-bounds
		{10.15, 10.15}, // just outside on one axis
	} {
		n, ok := g.gridNearest(p.lat, p.lng)
		if !ok || n.ID == 0 {
			t.Fatalf("gridNearest(%v) must return a valid node without panicking, got %+v ok=%v", p, n, ok)
		}
	}
}

func TestNearestNodeGridDegenerate(t *testing.T) {
	single := NewGraph([]Node{{ID: 1, Lat: 10.0, Lng: 10.0}}, nil)
	if _, ok := single.NearestNode(10.0, 10.0); !ok {
		t.Fatal("expected single-node graph to snap")
	}
	if _, ok := single.NearestNode(20.0, 30.0); !ok {
		t.Fatal("expected out-of-range query on single-node graph to clamp to the node")
	}

	empty := NewGraph(nil, nil)
	if _, ok := empty.NearestNode(10.0, 10.0); ok {
		t.Fatal("expected empty graph to return no node")
	}
}

// --- Elevation cost model tests (chain head) ---------------------------------
//
// The 11 tests above are the regression proof that the default (zero-weight)
// path is unchanged. Everything below appends without touching them.

// TestRouteZeroWeightsEqualsDistance proves the "default is off" invariant:
// with the zero weight set and all elevations 0, RouteWithWeights returns the
// exact same Nodes and Meters as the pure-distance Route (and the existing
// integer-cost assertions).
func TestRouteZeroWeightsEqualsDistance(t *testing.T) {
	g := testGraph()

	path, meters, err := g.Route(10.0, 10.0, 10.1, 10.1)
	if err != nil {
		t.Fatalf("Route: %v", err)
	}
	p, err := g.RouteWithWeights(10.0, 10.0, 10.1, 10.1, CostWeights{})
	if err != nil {
		t.Fatalf("RouteWithWeights: %v", err)
	}
	if len(p.Nodes) != len(path) {
		t.Fatalf("Nodes length %d != %d", len(p.Nodes), len(path))
	}
	for i := range path {
		if p.Nodes[i] != path[i] {
			t.Fatalf("Nodes[%d]=%d want %d", i, p.Nodes[i], path[i])
		}
	}
	if p.Meters != meters || meters != 22264 {
		t.Fatalf("Meters=%v want %v", p.Meters, meters)
	}
	if p.Cost != meters {
		t.Fatalf("Cost=%v want meters %v", p.Cost, meters)
	}
}

// ridgeGraph models two A→B paths: a short 500 m route that climbs 20 m and
// descends again over a ridge, and a flat 520 m route that contours around.
// Both endpoints are at elevation 100, so the short route's ascent is a real
// "up and over" cost, not a net-gain.
//
// Node coordinates are clustered within ~15 m of each other so every
// haversine between node pairs stays far below the 250+ m edge costs — this
// keeps the straight-line heuristic admissible (the model's triangle-inequality
// assumption), which the plan's own testGraph() also satisfies by using
// haversine-consistent costs.
func ridgeGraph() *Graph {
	nodes := []Node{
		{ID: 1, Lat: 0.0000, Lng: 0.0000, EleM: 100}, // A
		{ID: 2, Lat: 0.0001, Lng: 0.0000, EleM: 120}, // ridge top
		{ID: 3, Lat: 0.0000, Lng: 0.0001, EleM: 100}, // flat mid
		{ID: 4, Lat: 0.0001, Lng: 0.0001, EleM: 100}, // B
	}
	edges := []Edge{
		{Source: 1, Target: 2, Cost: 250}, // A -> ridge, +20 m
		{Source: 2, Target: 4, Cost: 250}, // ridge -> B, -20 m
		{Source: 1, Target: 3, Cost: 510}, // A -> flat mid
		{Source: 3, Target: 4, Cost: 10},  // flat mid -> B
	}
	return NewGraph(nodes, edges)
}

// TestAscentAvoidsRidge encodes the objective: with AscentW > 0 the flat
// route must win (despite being 20 m longer in meters); with the zero weights
// the short climbing route must win. Both directions of the switch are
// asserted, plus that the reported Meters always tracks the path actually
// walked (520 for the flat route, never 500).
func TestAscentAvoidsRidge(t *testing.T) {
	g := ridgeGraph()
	fromLat, fromLng := 0.0, 0.0
	toLat, toLng := 0.0001, 0.0001

	// Zero weights: shortest by meters wins (500 m climbing route).
	p, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, CostWeights{})
	if err != nil {
		t.Fatalf("zero weights: %v", err)
	}
	if p.Meters != 500 {
		t.Fatalf("zero weights: Meters=%v want 500 (short climbing route)", p.Meters)
	}
	if p.AscentM != 20 {
		t.Fatalf("zero weights: AscentM=%v want 20", p.AscentM)
	}

	// AscentW > 0: the flat 520 m route wins.
	p, err = g.RouteWithWeights(fromLat, fromLng, toLat, toLng, CostWeights{AscentW: 2, DescentW: 0, MaxGrade: 0.15})
	if err != nil {
		t.Fatalf("ascent weights: %v", err)
	}
	if p.Meters != 520 {
		t.Fatalf("ascent weights: Meters=%v want 520 (flat contoured route)", p.Meters)
	}
	if p.AscentM != 0 {
		t.Fatalf("ascent weights: AscentM=%v want 0 (flat route climbs nothing)", p.AscentM)
	}
}

// descentGraph models two paths: a longer route that descends into a valley
// and climbs back out (800 m, down/up 60 m each way), and a shorter flat
// 750 m route. With DescentW = 0 the flat route wins on meters; with
// DescentW > 0 the descent credit flips it to the longer descending route.
func descentGraph() *Graph {
	nodes := []Node{
		{ID: 1, Lat: 0.0000, Lng: 0.0000, EleM: 100}, // A (high)
		{ID: 2, Lat: 0.0001, Lng: 0.0000, EleM: 40},  // valley (down 60)
		{ID: 3, Lat: 0.0000, Lng: 0.0001, EleM: 100}, // flat mid
		{ID: 4, Lat: 0.0001, Lng: 0.0001, EleM: 100}, // B
	}
	edges := []Edge{
		{Source: 1, Target: 2, Cost: 400}, // A -> valley, -60 m
		{Source: 2, Target: 4, Cost: 400}, // valley -> B, +60 m
		{Source: 1, Target: 3, Cost: 350}, // A -> flat mid
		{Source: 3, Target: 4, Cost: 400}, // flat mid -> B
	}
	return NewGraph(nodes, edges)
}

func TestDescentCreditPrefersContinuingDown(t *testing.T) {
	g := descentGraph()
	fromLat, fromLng := 0.0, 0.0
	toLat, toLng := 0.0001, 0.0001

	// DescentW = 0: meters decide. Flat route (750) beats descending (800).
	p, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, CostWeights{AscentW: 0, DescentW: 0, MaxGrade: 0.3})
	if err != nil {
		t.Fatalf("no descent credit: %v", err)
	}
	if p.Meters != 750 {
		t.Fatalf("no descent credit: Meters=%v want 750 (flat route)", p.Meters)
	}

	// DescentW > 0: the 800 m descend-then-climb route wins.
	p, err = g.RouteWithWeights(fromLat, fromLng, toLat, toLng, CostWeights{AscentW: 0, DescentW: 1, MaxGrade: 0.3})
	if err != nil {
		t.Fatalf("descent credit: %v", err)
	}
	if p.Meters != 800 {
		t.Fatalf("descent credit: Meters=%v want 800 (descending route)", p.Meters)
	}
}

func TestDeadbandSuppressesNoise(t *testing.T) {
	// One edge of 20 m with 1 m of bogus elevation on one endpoint.
	g := NewGraph(
		[]Node{
			{ID: 1, Lat: 0.0, Lng: 0.0, EleM: 10},
			{ID: 2, Lat: 0.0001, Lng: 0.0, EleM: 11}, // +1 m noise
		},
		[]Edge{{Source: 1, Target: 2, Cost: 20}},
	)

	// With DeadbandM = 3, the 1 m delta is zeroed: cost == 20.
	p, err := g.RouteWithWeights(0.0, 0.0, 0.0001, 0.0, CostWeights{AscentW: 1, DescentW: 0, MaxGrade: 0.15, DeadbandM: 3})
	if err != nil {
		t.Fatalf("deadband: %v", err)
	}
	if p.Cost != 20 {
		t.Fatalf("deadband Cost=%v want 20 (noise suppressed)", p.Cost)
	}

	// 5 m of real climb on the same edge must still cost more than 20.
	g = NewGraph(
		[]Node{
			{ID: 1, Lat: 0.0, Lng: 0.0, EleM: 10},
			{ID: 2, Lat: 0.0001, Lng: 0.0, EleM: 15}, // +5 m real climb
		},
		[]Edge{{Source: 1, Target: 2, Cost: 20}},
	)
	p, err = g.RouteWithWeights(0.0, 0.0, 0.0001, 0.0, CostWeights{AscentW: 1, DescentW: 0, MaxGrade: 0.15, DeadbandM: 3})
	if err != nil {
		t.Fatalf("real climb: %v", err)
	}
	if p.Cost <= 20 {
		t.Fatalf("real climb Cost=%v want > 20", p.Cost)
	}
}

func TestGradeCap(t *testing.T) {
	// A 100 m edge with 50 m climb has grade 0.5; MaxGrade caps the price at
	// 100·(1 + AscentW·MaxGrade), not at grade 0.5.
	g := NewGraph(
		[]Node{
			{ID: 1, Lat: 0.0, Lng: 0.0, EleM: 0},
			{ID: 2, Lat: 0.0001, Lng: 0.0, EleM: 50},
		},
		[]Edge{{Source: 1, Target: 2, Cost: 100}},
	)
	const ascentW, maxGrade = 1.0, 0.15
	p, err := g.RouteWithWeights(0.0, 0.0, 0.0001, 0.0, CostWeights{AscentW: ascentW, DescentW: 0, MaxGrade: maxGrade})
	if err != nil {
		t.Fatalf("grade cap: %v", err)
	}
	want := 100 * (1 + ascentW*maxGrade)
	if math.Abs(p.Cost-want) > 1e-9 {
		t.Fatalf("Cost=%v want %v (grade capped at MaxGrade)", p.Cost, want)
	}
}

func TestWeightsValidate(t *testing.T) {
	// The zero value is valid.
	if err := (CostWeights{}).Validate(); err != nil {
		t.Fatalf("zero weights should be valid: %v", err)
	}
	// DescentW*MaxGrade >= 1 rejected.
	if err := (CostWeights{DescentW: 10, MaxGrade: 0.15}).Validate(); err == nil {
		t.Fatal("DescentW*MaxGrade >= 1 must be rejected")
	}
	// MaxGrade < 0 rejected.
	if err := (CostWeights{DescentW: 0.3, MaxGrade: -0.1}).Validate(); err == nil {
		t.Fatal("MaxGrade < 0 must be rejected")
	}

	// RouteWithWeights with invalid weights behaves exactly like zero weights:
	// no panic, no error, and the same distance-optimal result.
	g := testGraph()
	p, err := g.RouteWithWeights(10.0, 10.0, 10.1, 10.1, CostWeights{DescentW: 10, MaxGrade: 0.15})
	if err != nil {
		t.Fatalf("invalid weights must not error: %v", err)
	}
	if p.Meters != 22264 {
		t.Fatalf("invalid weights Meters=%v want 22264 (flat fallback)", p.Meters)
	}
}

func TestWeightsRejectNegative(t *testing.T) {
	cases := []struct {
		name string
		w    CostWeights
	}{
		{"AscentW negative", CostWeights{AscentW: -0.1}},
		{"DescentW negative", CostWeights{DescentW: -0.1, MaxGrade: 0.15}},
		{"MaxGrade negative", CostWeights{MaxGrade: -0.1}},
		{"AscentW NaN", CostWeights{AscentW: math.NaN()}},
		{"DescentW NaN", CostWeights{DescentW: math.NaN()}},
		{"MaxGrade NaN", CostWeights{MaxGrade: math.NaN()}},
		{"DeadbandM NaN", CostWeights{DeadbandM: math.NaN()}},
		{"AscentW +Inf", CostWeights{AscentW: math.Inf(1)}},
		{"DescentW +Inf", CostWeights{DescentW: math.Inf(1)}},
		{"MaxGrade +Inf", CostWeights{MaxGrade: math.Inf(1)}},
		{"DeadbandM +Inf", CostWeights{DeadbandM: math.Inf(1)}},
		{"AscentW -Inf", CostWeights{AscentW: math.Inf(-1)}},
		{"DescentW -Inf", CostWeights{DescentW: math.Inf(-1)}},
		{"MaxGrade -Inf", CostWeights{MaxGrade: math.Inf(-1)}},
		{"DeadbandM -Inf", CostWeights{DeadbandM: math.Inf(-1)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.w.Validate(); err == nil {
				t.Fatalf("Validate() must reject %v", tc.w)
			}
			// And RouteWithWeights must fall back to flat routing, no panic.
			g := testGraph()
			p, err := g.RouteWithWeights(10.0, 10.0, 10.1, 10.1, tc.w)
			if err != nil {
				t.Fatalf("RouteWithWeights must not error on invalid weights: %v", err)
			}
			if p.Meters != 22264 {
				t.Fatalf("invalid weights Meters=%v want 22264 (flat fallback)", p.Meters)
			}
		})
	}
}

// TestPathMetricsSignConvention checks AscentM/DescentM are >= 0, sum to
// |z(last)-z(first)| + 2·(wiggle), and are RAW (a deadbanded delta still
// reports its full climb).
func TestPathMetricsSignConvention(t *testing.T) {
	// Path: 0 -> 10 (up 10), 10 -> 8 (down 2), 8 -> 12 (up 4).
	// Total ascent = 14, descent = 2. Net = +12.
	g := NewGraph(
		[]Node{
			{ID: 1, Lat: 0.0, Lng: 0.0, EleM: 0},
			{ID: 2, Lat: 0.0001, Lng: 0.0, EleM: 10},
			{ID: 3, Lat: 0.0002, Lng: 0.0, EleM: 8},
			{ID: 4, Lat: 0.0003, Lng: 0.0, EleM: 12},
		},
		[]Edge{
			{Source: 1, Target: 2, Cost: 100},
			{Source: 2, Target: 3, Cost: 100},
			{Source: 3, Target: 4, Cost: 100},
		},
	)
	p, err := g.RouteWithWeights(0.0, 0.0, 0.0003, 0.0, CostWeights{AscentW: 1, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if p.AscentM < 0 || p.DescentM < 0 {
		t.Fatalf("AscentM/DescentM must be >= 0: ascent=%v descent=%v", p.AscentM, p.DescentM)
	}
	// |z(last)-z(first)| = 12; wiggle = descent 2. Ascent = 12 + 2 = 14.
	if p.AscentM != 14 {
		t.Fatalf("AscentM=%v want 14 (raw, includes deadbanded deltas)", p.AscentM)
	}
	if p.DescentM != 2 {
		t.Fatalf("DescentM=%v want 2", p.DescentM)
	}
}

// gridGraph builds a connected L×L lattice (4-neighbor) with haversine edge
// costs and deterministic pseudo-random elevations, for property tests.
func gridGraph(n int, seed int64) *Graph {
	step := 0.001
	rng := rand.New(rand.NewSource(seed))
	var nodes []Node
	var edges []Edge
	idAt := make([][]int64, n)
	for i := 0; i < n; i++ {
		idAt[i] = make([]int64, n)
	}
	var next int64 = 1
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			id := next
			next++
			idAt[i][j] = id
			nodes = append(nodes, Node{
				ID:   id,
				Lat:  float64(i) * step,
				Lng:  float64(j) * step,
				EleM: rng.Float64()*200 - 100, // -100..100 m
			})
		}
	}
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			if j+1 < n {
				u, v := idAt[i][j], idAt[i][j+1]
				edges = append(edges, Edge{Source: u, Target: v, Cost: HaversineMeters(nodes[u-1].Lat, nodes[u-1].Lng, nodes[v-1].Lat, nodes[v-1].Lng)})
			}
			if i+1 < n {
				u, v := idAt[i][j], idAt[i+1][j]
				edges = append(edges, Edge{Source: u, Target: v, Cost: HaversineMeters(nodes[u-1].Lat, nodes[u-1].Lng, nodes[v-1].Lat, nodes[v-1].Lng)})
			}
		}
	}
	return NewGraph(nodes, edges)
}

// bruteForceWeighted is an obviously-correct O(V²) Dijkstra over g.adj using
// the same weightedEdgeCost. It is the reference implementation the A* result
// is checked against.
func bruteForceWeighted(g *Graph, src, dst int64, w CostWeights) (cost, meters float64, reachable bool) {
	dist := map[int64]float64{src: 0}
	met := map[int64]float64{src: 0}
	visited := map[int64]bool{}
	for {
		var cur int64
		curFound := false
		var curD float64
		for id, d := range dist {
			if visited[id] {
				continue
			}
			if !curFound || d < curD {
				cur = id
				curD = d
				curFound = true
			}
		}
		if !curFound {
			break
		}
		if cur == dst {
			return curD, met[dst], true
		}
		visited[cur] = true
		for _, e := range g.adj[cur] {
			if visited[e.to] {
				continue
			}
			c := weightedEdgeCost(e.cost, g.nodes[e.to].EleM-g.nodes[cur].EleM, w)
			nd := curD + c
			if prev, ok := dist[e.to]; !ok || nd < prev {
				dist[e.to] = nd
				met[e.to] = met[cur] + e.cost
			}
		}
	}
	return 0, 0, false
}

// TestWeightedMatchesBruteForceDijkstra runs the A* result against the O(V²)
// reference over many seeded random graphs, asserting identical Cost and
// Meters for every snapped OD pair.
func TestWeightedMatchesBruteForceDijkstra(t *testing.T) {
	weights := []CostWeights{
		{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		{AscentW: 0, DescentW: 0.5, MaxGrade: 0.3, DeadbandM: 0},
	}
	for _, w := range weights {
		for seed := int64(0); seed < 20; seed++ {
			g := gridGraph(6, seed)
			nodes := g.list
			for aIdx := 0; aIdx < len(nodes); aIdx += 7 {
				for bIdx := 0; bIdx < len(nodes); bIdx += 11 {
					a, b := nodes[aIdx], nodes[bIdx]
					if a.ID == b.ID {
						continue
					}
					p, err := g.RouteWithWeights(a.Lat, a.Lng, b.Lat, b.Lng, w)
					wantCost, wantMeters, reachable := bruteForceWeighted(g, a.ID, b.ID, w)
					if err != nil {
						if reachable {
							t.Fatalf("seed %d, %d->%d: A* errored %v but path reachable", seed, a.ID, b.ID, err)
						}
						continue
					}
					if !reachable {
						t.Fatalf("seed %d, %d->%d: A* succeeded but brute-force says unreachable", seed, a.ID, b.ID)
					}
					if math.Abs(p.Cost-wantCost) > 1e-6 {
						t.Fatalf("seed %d, %d->%d: Cost=%v want %v", seed, a.ID, b.ID, p.Cost, wantCost)
					}
					if math.Abs(p.Meters-wantMeters) > 1e-6 {
						t.Fatalf("seed %d, %d->%d: Meters=%v want %v", seed, a.ID, b.ID, p.Meters, wantMeters)
					}
				}
			}
		}
	}
}

// TestHeuristicIsAdmissible mechanically checks the Part 2 proof: for every
// (n, goal) pair the scaled heuristic D·haversine(n, goal) never exceeds the
// actual optimal weighted cost n→goal.
func TestHeuristicIsAdmissible(t *testing.T) {
	weights := []CostWeights{
		{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		{AscentW: 0, DescentW: 0.5, MaxGrade: 0.3, DeadbandM: 0},
		{AscentW: 2, DescentW: 0.1, MaxGrade: 0.2, DeadbandM: 1},
	}
	for _, w := range weights {
		d := w.heuristicScale()
		if d <= 0 {
			t.Fatalf("weights %+v: heuristicScale=%v must be > 0", w, d)
		}
		graphs := map[string]*Graph{"grid": gridGraph(6, 42)}
		graphs["grid3x3"] = gridGraph(3, 7)
		for name, g := range graphs {
			for _, n := range g.list {
				for _, goal := range g.list {
					if n.ID == goal.ID {
						continue
					}
					cost, _, reachable := bruteForceWeighted(g, n.ID, goal.ID, w)
					if !reachable {
						continue
					}
					h := d * HaversineMeters(n.Lat, n.Lng, goal.Lat, goal.Lng)
					if h > cost+1e-9 {
						t.Fatalf("%s weights %+v: h(%d,%d)=%v exceeds cost %v", name, w, n.ID, goal.ID, h, cost)
					}
				}
			}
		}
	}
}
