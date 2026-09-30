package repository

import (
	"errors"
	"math"
	"strings"
	"testing"

	"ride-hailing-api/internal/routing"
)

// An uncovered pin is a DATA gap with its own sentinel, not the "no path"
// error. Before this, routeResults returned routing.ErrNoRoute for it, which
// was indistinguishable from a graph that was searched and found nothing — and
// the service only degrades a datasource outage, so the pin reached the handler
// as a 500 INTERNAL that the rider app then drew as a road-less straight line
// (known bug #3).
func TestUncoveredPinIsNotTheNoRouteError(t *testing.T) {
	g := nativeTestGraph()
	// A pin the engine measures at 50113 m from the graph: beyond the shipped
	// 50000 m radius, the same pin PostGIS measures as 49850 m (see the
	// boundary-band test below and the DB-backed integration test).
	lat, lng := pinAtSnapDistanceM(g, 9.9300, -84.0800, 50113, -1)

	_, err := routeResults(g, routing.CostWeights{}, 50000, gateIsAuthority, lat, lng, 9.9400, -84.0800)
	if !errors.Is(err, ErrPinUncovered) {
		t.Fatalf("err = %v, want ErrPinUncovered for a pin 50113 m out under a 50000 m radius", err)
	}
	if errors.Is(err, routing.ErrNoRoute) {
		t.Errorf("err = %v also matches routing.ErrNoRoute; the two conditions must stay distinguishable", err)
	}
	// The debugging numbers support needs are in the message, not just the type.
	msg := err.Error()
	if !strings.Contains(msg, "50113") || !strings.Contains(msg, "50000") {
		t.Errorf("message = %q, want the measured distance and the radius", msg)
	}
	if !strings.Contains(msg, "pickup") {
		t.Errorf("message = %q, want the pin named so a support ticket says WHICH pin", msg)
	}
}

// The droppoff side of the same gate: naming only the pickup would leave support
// guessing which end of the trip fell out of coverage.
func TestUncoveredDropoffIsNamedInTheError(t *testing.T) {
	g := nativeTestGraph()
	lat, lng := pinAtSnapDistanceM(g, 9.9300, -84.0800, 50113, -1)

	_, err := routeResults(g, routing.CostWeights{}, 50000, gateIsAuthority, 9.9400, -84.0800, lat, lng)
	if !errors.Is(err, ErrPinUncovered) {
		t.Fatalf("err = %v, want ErrPinUncovered", err)
	}
	if !strings.Contains(err.Error(), "dropoff") {
		t.Errorf("message = %q, want the dropoff named", err)
	}
}

// A graph with no path between two pins that are both well inside the radius is
// a genuine routing failure and must keep its honest error: flattening it into
// an estimate would draw a straight line for a trip the network cannot serve.
func TestGenuineNoPathBetweenCoveredPinsStaysNoRoute(t *testing.T) {
	// Two components, 50 m apart, no edge between them.
	g := routing.NewGraph(
		[]routing.Node{
			{ID: 1, Lat: 9.9300, Lng: -84.0800},
			{ID: 2, Lat: 9.9400, Lng: -84.0800},
			{ID: 3, Lat: 9.9500, Lng: -84.0800},
		},
		[]routing.Edge{{Source: 1, Target: 2, Cost: 1112}},
	)
	// Every pin is within 100 m of a vertex, so the radius is not in play.
	for _, pin := range [][2]float64{{9.9300, -84.0800}, {9.9500, -84.0800}} {
		if d := snapDistanceM(g, pin[0], pin[1]); d > 100 {
			t.Fatalf("fixture pin is %v m from the graph; the test is about a PATH, not coverage", d)
		}
	}

	for _, authority := range []coverageAuthority{gateIsAuthority, resolverIsAuthority} {
		_, err := routeResults(g, routing.CostWeights{}, 50000, authority, 9.9300, -84.0800, 9.9500, -84.0800)
		if !errors.Is(err, routing.ErrNoRoute) {
			t.Errorf("authority %d: err = %v, want routing.ErrNoRoute", authority, err)
		}
		if errors.Is(err, ErrPinUncovered) {
			t.Errorf("authority %d: err = %v must not read as an uncovered pin", authority, err)
		}
	}
}

// An empty network is not a per-pin coverage answer — there is nothing to
// measure a pin against — so it keeps the honest "no route" error instead of
// being reported as an uncovered pin.
func TestEmptyGraphIsNotAnUncoveredPin(t *testing.T) {
	g := routing.NewGraph(nil, nil)

	_, err := routeResults(g, routing.CostWeights{}, 50000, gateIsAuthority, 9.9300, -84.0800, 9.9400, -84.0800)
	if errors.Is(err, ErrPinUncovered) {
		t.Errorf("err = %v; an empty network is an import fault, not a pin that is not covered", err)
	}
	if !errors.Is(err, routing.ErrNoRoute) {
		t.Errorf("err = %v, want routing.ErrNoRoute for an empty network", err)
	}
}

// ---- the ~265 m disagreement band at the 50000 m boundary -----------------
//
// The two coverage predicates are two MEASUREMENTS of the same fact and they
// do not agree: the region resolver measures with PostGIS ST_Distance over
// ::geography (spheroidal), the native engine with routing.HaversineMeters (a
// great-circle formula on a 6371 km sphere). At 10 deg N the Go formula reads
// ~0.53% LONGER, so under the shipped 50000 m radius a band of pins exists that
// PostGIS calls covered and the Go gate calls uncovered — 265 m wide.
//
// Two things are pinned here. First, that the band is real (it is not a
// hypothetical rounding difference). Second, that a pin in it CANNOT fail a
// routing call on the region path, which is the guarantee this fix exists for:
// a pin the service accepted through Snap can never 500.
func TestRadiusBoundaryBandBetweenTheTwoCoveragePredicates(t *testing.T) {
	const radiusM = 50000

	g := nativeTestGraph()
	// The two pins the reviewer measured, expressed in each formula's own units:
	// the distance PostGIS reported (covered) and the distance the Go gate
	// measures for the same pin (uncovered).
	band := []struct {
		name        string
		postgisM    float64 // what the resolver's Snap reported
		goHaversine float64 // what the engine's own snap measures for the same pin
	}{
		{name: "just_inside_the_radius", postgisM: 49850, goHaversine: 50113},
		{name: "almost_on_the_radius", postgisM: 49990, goHaversine: 50255},
	}

	for _, tc := range band {
		t.Run(tc.name, func(t *testing.T) {
			// The resolver's answer: covered.
			if !WithinSnapRadius(tc.postgisM, radiusM) {
				t.Fatalf("the resolver's own predicate must call %v m covered under a %v m radius", tc.postgisM, radiusM)
			}
			// The gate's answer for that same pin: not covered. If this ever
			// stops being true the two predicates converged and this whole test
			// is measuring nothing.
			if WithinSnapRadius(tc.goHaversine, radiusM) {
				t.Fatalf("the gate's predicate now agrees with the resolver's at %v m; the band is empty", tc.goHaversine)
			}
			// And the band is a real band, not one exact pin: the divergence
			// is proportional, so a 150 m slice of the radius is affected.
			if width := tc.goHaversine - tc.postgisM; width < 100 {
				t.Errorf("band width = %.0f m, want the ~265 m this fix is about", width)
			}

			lat, lng := pinAtSnapDistanceM(g, 9.9300, -84.0800, tc.goHaversine, -1)

			// THE GUARANTEE. RouteInRegion is the region path: the service
			// resolved this pin through Snap first, so the repository must not
			// re-decide coverage and reject the very pin the service accepted.
			repo := NewNavigationRepo(nil, radiusM)
			repo.graphs["cr-sj"] = &regionGraphEntry{graph: g, datasource: ""}
			nodes, err := repo.RouteInRegion("cr-sj", "", lat, lng, 9.9400, -84.0800)
			if err != nil {
				t.Fatalf("a pin the resolver accepted must never fail the region path: %v", err)
			}
			if len(nodes) == 0 {
				t.Fatal("expected the road route, got no nodes")
			}
			if last := nodes[len(nodes)-1]; last.AggCost != 1112 {
				t.Errorf("AggCost = %v, want 1112 (edge cost in meters)", last.AggCost)
			}

			// The unscoped path has no resolver, so the gate IS the authority
			// there — and it reports the gap with its own sentinel, which the
			// service degrades to an estimate.
			legacy := NewNavigationRepo(nil, radiusM)
			legacy.graph, legacy.graphAttempted = g, true
			if _, err := legacy.GetShortestPath(lat, lng, 9.9400, -84.0800); !errors.Is(err, ErrPinUncovered) {
				t.Errorf("unscoped path err = %v, want ErrPinUncovered (the service turns it into an estimate)", err)
			}
		})
	}
}

// A covered pin on the region path still gets the real road route with meters
// cost: turning the gate off must not have turned routing off.
func TestRegionPathStillRoutesCoveredPins(t *testing.T) {
	g := nativeTestGraph()
	repo := NewNavigationRepo(nil, 50000)
	repo.graphs["cr-sj"] = &regionGraphEntry{graph: g, datasource: ""}

	nodes, err := repo.RouteInRegion("cr-sj", "", 9.92730, -84.08000, 9.94270, -84.08000)
	if err != nil {
		t.Fatalf("covered pins must route: %v", err)
	}
	if len(nodes) != 2 {
		t.Fatalf("got %d nodes, want the 2-node graph", len(nodes))
	}
	for i, n := range nodes {
		if n.NodeSeq != i {
			t.Errorf("node[%d].NodeSeq = %d, want %d", i, n.NodeSeq, i)
		}
	}
	if last := nodes[len(nodes)-1]; last.AggCost != 1112 {
		t.Errorf("AggCost = %v, want 1112 (the route length in METERS, never the weighted cost)", last.AggCost)
	}
}

// radiusM <= 0 is the documented always-snap opt-in and it must survive the
// gate, on the path where the gate is the authority.
func TestAlwaysSnapOptInSurvivesTheGate(t *testing.T) {
	g := nativeTestGraph()
	repo := NewNavigationRepo(nil, 0)
	repo.graph, repo.graphAttempted = g, true

	farLat, farLng := pinAtSnapDistanceM(g, 9.9300, -84.0800, 66000, -1)
	if _, err := repo.GetShortestPath(farLat, farLng, 9.9400, -84.0800); err != nil {
		t.Errorf("radius 0 must always snap, got %v", err)
	}
	// Negative is the same opt-in.
	neg := NewNavigationRepo(nil, -1)
	neg.graph, neg.graphAttempted = g, true
	if _, err := neg.GetShortestPath(farLat, farLng, 9.9400, -84.0800); err != nil {
		t.Errorf("a negative radius must always snap, got %v", err)
	}
}

// pinAtSnapDistanceM walks a pin away from (lat, lng) by dir degrees of
// latitude — +1 north, -1 south — until the graph's own snap measures targetM
// to it, by bisection on the measured distance. Building the band pins this way
// keeps the fixtures honest: a test asserts the distance it needs instead of
// trusting a hardcoded coordinate.
//
// The direction matters: the pin must stay closer to (lat, lng)'s own vertex
// than to any other, or it would snap somewhere else and the route assertions
// would be measuring a different trip.
func pinAtSnapDistanceM(g *routing.Graph, lat, lng, targetM, dir float64) (float64, float64) {
	lo, hi := 0.0, 5.0
	for i := 0; i < 200; i++ {
		mid := (lo + hi) / 2
		if snapDistanceM(g, lat+dir*mid, lng) < targetM {
			lo = mid
		} else {
			hi = mid
		}
	}
	got := lat + dir*(lo+hi)/2
	if math.Abs(snapDistanceM(g, got, lng)-targetM) > 1 {
		panic("bisection failed to converge on the requested snap distance")
	}
	return got, lng
}
