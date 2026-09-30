package repository

import (
	"errors"
	"math"
	"testing"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/routing"
)

// WithinSnapRadius is the whole "is this pin covered" rule, and it is the branch
// api_plans [routing]_estimate_fallback_default (bug #2) turned on in the
// DEFAULT configuration: with a non-positive radius the check never runs, so a
// pin in the middle of nowhere snaps to the nearest road and the honest
// is_estimate answer is unreachable.
func TestWithinSnapRadius(t *testing.T) {
	cases := []struct {
		name      string
		distanceM float64
		radiusM   float64
		want      bool
	}{
		{name: "inside_radius", distanceM: 12.5, radiusM: 50000, want: true},
		{name: "exactly_on_the_radius", distanceM: 50000, radiusM: 50000, want: true},
		{name: "just_beyond_the_radius", distanceM: 50000.1, radiusM: 50000, want: false},
		{name: "far_beyond_the_radius", distanceM: 60000, radiusM: 50000, want: false},
		// radius <= 0 is the documented always-snap opt-in, and must cover a
		// pin no radius would ever cover.
		{name: "radius_zero_always_snaps", distanceM: 60000, radiusM: 0, want: true},
		{name: "negative_radius_always_snaps", distanceM: 60000, radiusM: -1, want: true},
		{name: "radius_zero_covers_an_on_vertex_snap", distanceM: 0, radiusM: 0, want: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := WithinSnapRadius(tc.distanceM, tc.radiusM); got != tc.want {
				t.Errorf("WithinSnapRadius(distance=%v, radius=%v) = %v, want %v",
					tc.distanceM, tc.radiusM, got, tc.want)
			}
		})
	}
}

// The shipped default must actually make the estimate path reachable: a pin
// 60 km from the nearest road is covered under the old 0 = always-snap default
// and NOT covered under the shipped one, which is the whole bug (#2). Reading
// the real config default (rather than restating 50000 here) keeps the two from
// drifting apart.
func TestShippedSnapRadiusDefaultMakesTheEstimateReachable(t *testing.T) {
	t.Setenv("ROUTING_SNAP_RADIUS_M", "")
	radius := config.Load().RoutingSnapRadiusM

	if radius <= 0 {
		t.Fatalf("shipped default ROUTING_SNAP_RADIUS_M = %v; a non-positive default disables the "+
			"coverage check and makes the is_estimate answer unreachable", radius)
	}

	// A real urban pickup is meters from a road and must be unaffected by the
	// new default — the change is only meant to catch genuinely remote pins.
	const urbanPickupM = 350
	if !WithinSnapRadius(urbanPickupM, radius) {
		t.Errorf("a %v m urban pickup must stay covered under the %v m default", urbanPickupM, radius)
	}

	// A pin in unserved country must now be uncovered, where the old 0 default
	// snapped it to a road ~60 km away and drew a confident, road-less route.
	const remotePinM = 60000
	if WithinSnapRadius(remotePinM, radius) {
		t.Errorf("a %v m remote pin must be uncovered under the %v m default, so the endpoint "+
			"answers is_estimate instead of snapping", remotePinM, radius)
	}
	// The opt-in still bypasses it entirely.
	if !WithinSnapRadius(remotePinM, 0) {
		t.Error("an explicit radius of 0 must still always-snap")
	}
}

// ---- the radius has to REACH the native engine, not just the config ---------
//
// NewNavigationRepoWithDatasources is the only production constructor for the
// native engine (internal/router → NewRoutingRepositoryWithPools), and the
// native engine is the permanent default. A constructor that accepts
// snapRadiusM and drops it therefore does not degrade anything: it silently
// turns the 50 km default back into "always snap", which is exactly the state
// bug #2 says is fixed, and the service suite cannot see it because every
// radius test there runs against a fake that re-implements the predicate.

func TestNativeCtorCarriesSnapRadius(t *testing.T) {
	cases := []struct {
		name    string
		radiusM float64
	}{
		{name: "shipped_default", radiusM: 50000},
		{name: "always_snap_opt_in", radiusM: 0},
		{name: "operator_chosen", radiusM: 1234.5},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := NewNavigationRepoWithDatasources(nil, nil, tc.radiusM, 0)
			if repo.snapRadiusM != tc.radiusM {
				t.Errorf("NewNavigationRepoWithDatasources(.., %v, 0).snapRadiusM = %v, want %v "+
					"(a dropped argument makes the native engine always-snap, so is_estimate "+
					"stays unreachable in the DEFAULT engine)", tc.radiusM, repo.snapRadiusM, tc.radiusM)
			}
		})
	}
}

// The constructor is only half the wiring: the engine factory is what
// internal/router actually calls, so the config value has to survive THAT too.
// With ROUTING_ENGINE unset (the shipped default) the factory must build the
// native repo — the permanent default — carrying the shipped radius.
func TestEngineFactoryCarriesConfiguredSnapRadiusToTheNativeRepo(t *testing.T) {
	t.Setenv("ROUTING_ENGINE", "")
	t.Setenv("ROUTING_SNAP_RADIUS_M", "")
	cfg := config.Load()

	navRepo := NewRoutingRepositoryWithPools(nil, nil, cfg)
	native, ok := navRepo.(*NativeNavigationRepo)
	if !ok {
		t.Fatalf("engine = %T, want the native engine for the shipped ROUTING_ENGINE=%q", navRepo, cfg.RoutingEngine)
	}
	if native.snapRadiusM != cfg.RoutingSnapRadiusM {
		t.Errorf("factory-built native repo snapRadiusM = %v, want the configured %v",
			native.snapRadiusM, cfg.RoutingSnapRadiusM)
	}
	// The opt-in has to survive the same path, or an operator cannot get the
	// old always-snap behavior back.
	t.Setenv("ROUTING_SNAP_RADIUS_M", "0")
	if got := NewRoutingRepositoryWithPools(nil, nil, config.Load()); got.(*NativeNavigationRepo).snapRadiusM != 0 {
		t.Errorf("factory-built native repo snapRadiusM = %v with ROUTING_SNAP_RADIUS_M=0, want 0",
			got.(*NativeNavigationRepo).snapRadiusM)
	}
}

// ---- the native engine must honour the radius too --------------------------
//
// snapInRegion gated the SQL snap path, but the native engine's RouteInRegion
// and GetShortestPath snapped through routing.NearestNode with no check at all:
// the two engines answered differently for the same pin. The gate is the shared
// WithinSnapRadius rule, applied before the A* search — on the paths where this
// call is the coverage authority (see coverageAuthority), which for
// routeResults means the unscoped path these tests drive directly.

func TestNativeRouteRejectsPinBeyondTheSnapRadius(t *testing.T) {
	g := nativeTestGraph()
	nearPin := [2]float64{9.92730, -84.08000} // ~300 m south of the graph
	farPin := [2]float64{10.53000, -84.08000} // ~66 km north of the graph

	// Keep the fixtures honest: these distances are the whole premise.
	if d := snapDistanceM(g, nearPin[0], nearPin[1]); d > 1000 {
		t.Fatalf("near fixture is %v m from the graph, want an urban pick (<1000 m)", d)
	}
	if d := snapDistanceM(g, farPin[0], farPin[1]); d < 60000 {
		t.Fatalf("far fixture is only %v m from the graph, want unserved country (>60 km)", d)
	}

	cases := []struct {
		name    string
		pin     [2]float64
		radiusM float64
		wantErr bool
	}{
		{name: "far_pin_under_the_shipped_default", pin: farPin, radiusM: 50000, wantErr: true},
		{name: "far_pin_with_the_always_snap_opt_in", pin: farPin, radiusM: 0, wantErr: false},
		{name: "urban_pin_under_the_shipped_default", pin: nearPin, radiusM: 50000, wantErr: false},
		{name: "urban_pin_beyond_a_tight_radius", pin: nearPin, radiusM: 100, wantErr: true},
		{name: "urban_pin_under_a_tight_radius", pin: nearPin, radiusM: 1000, wantErr: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := routeResults(g, routing.CostWeights{}, tc.radiusM, gateIsAuthority,
				tc.pin[0], tc.pin[1], nearPin[0], nearPin[1])
			if tc.wantErr {
				if !errors.Is(err, ErrPinUncovered) {
					t.Fatalf("err = %v, want ErrPinUncovered for a pin %v m out under a %v m radius",
						err, snapDistanceM(g, tc.pin[0], tc.pin[1]), tc.radiusM)
				}
				return
			}
			if err != nil {
				t.Fatalf("a covered pin must still route, got %v", err)
			}
		})
	}
}

// The boundary itself: a pin exactly on the radius is covered, a hair beyond it
// is not. Computed from the graph rather than hardcoded, so it stays correct if
// the fixture coordinates change.
func TestNativeRouteRadiusBoundary(t *testing.T) {
	g := nativeTestGraph()
	pin := [2]float64{9.92730, -84.08000}
	d := snapDistanceM(g, pin[0], pin[1])

	if _, err := routeResults(g, routing.CostWeights{}, d, gateIsAuthority, pin[0], pin[1], 9.9400, -84.0800); err != nil {
		t.Errorf("a pin exactly on the %v m radius must stay covered, got %v", d, err)
	}
	if _, err := routeResults(g, routing.CostWeights{}, math.Nextafter(d, 0), gateIsAuthority, pin[0], pin[1], 9.9400, -84.0800); !errors.Is(err, ErrPinUncovered) {
		t.Errorf("a pin one ulp beyond the radius must be uncovered, got %v", err)
	}
}

// routeResults is the shared tail of GetShortestPath and RouteInRegion, so the
// gate is only worth anything if the METHODS pass their own configured radius
// down. GetShortestPath is pinned here with a pre-seeded graph (no database
// needed); RouteInRegion takes the same r.snapRadiusM for the same helper.
func TestGetShortestPathAppliesTheConfiguredRadius(t *testing.T) {
	g := nativeTestGraph()
	farPin := [2]float64{10.53000, -84.08000}

	// 0 is the always-snap opt-in and must survive all the way down.
	always := NewNavigationRepo(nil, 0)
	always.graph, always.graphAttempted = g, true
	if _, err := always.GetShortestPath(farPin[0], farPin[1], 9.9400, -84.0800); err != nil {
		t.Errorf("radius 0 (always-snap) must route an uncovered pin, got %v", err)
	}

	// The shipped default must not.
	gated := NewNavigationRepo(nil, 50000)
	gated.graph, gated.graphAttempted = g, true
	if _, err := gated.GetShortestPath(farPin[0], farPin[1], 9.9400, -84.0800); !errors.Is(err, ErrPinUncovered) {
		t.Errorf("err = %v, want ErrPinUncovered: GetShortestPath ignored the configured radius", err)
	}
}

// A covered pin must still get a full road-following answer: the gate rejects
// uncovered pins, it does not reshape the success path.
func TestNativeRouteSuccessPathIsUnchanged(t *testing.T) {
	g := nativeTestGraph()
	from := [2]float64{9.92730, -84.08000} // ~300 m from the graph
	to := [2]float64{9.94270, -84.08000}   // ~300 m from the far end

	results, err := routeResults(g, routing.CostWeights{}, 50000, gateIsAuthority, from[0], from[1], to[0], to[1])
	if err != nil {
		t.Fatalf("covered pins must route, got %v", err)
	}
	if len(results) == 0 {
		t.Fatal("covered pins must return path nodes")
	}
	last := results[len(results)-1]
	if last.AggCost != 1112 {
		t.Errorf("AggCost = %v, want 1112 (the edge cost in meters)", last.AggCost)
	}
	if last.NodeSeq != len(results)-1 {
		t.Errorf("NodeSeq = %d on the last node, want %d", last.NodeSeq, len(results)-1)
	}
}

// nativeTestGraph is a two-vertex graph shaped like the loaded road network:
// vertices ~1.1 km apart joined by one ~1.1 km edge.
func nativeTestGraph() *routing.Graph {
	return routing.NewGraph(
		[]routing.Node{
			{ID: 1, Lat: 9.9300, Lng: -84.0800},
			{ID: 2, Lat: 9.9400, Lng: -84.0800},
		},
		[]routing.Edge{{Source: 1, Target: 2, Cost: 1112}},
	)
}

// snapDistanceM is what the engine's NearestNode would resolve a pin to, in
// meters — the value WithinSnapRadius is compared against.
func snapDistanceM(g *routing.Graph, lat, lng float64) float64 {
	n, ok := g.NearestNode(lat, lng)
	if !ok {
		return math.Inf(1)
	}
	return routing.HaversineMeters(lat, lng, n.Lat, n.Lng)
}
