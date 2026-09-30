package service

import (
	"errors"
	"fmt"
	"math"
	"testing"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/routing"
)

// An uncovered pin is a DATA gap: the rider gets HTTP 200 with a straight line
// and is_estimate=true, which is the whole point of the flag. It must never be
// a 500 — both Flutter apps draw a straight-line fallback on EVERY error status
// (rider_app .../home_screen.dart:157), so a 500 renders a road-less line with
// no is_estimate to warn the rider it is not a road route.
//
// N1: the region path. The resolver covered both pins through Snap; the router
// then reported the pin as not covered anyway (the ~0.5% disagreement between
// PostGIS geography and the engine's own haversine at the radius boundary). The
// service has to absorb that, not propagate it.
func TestGetRouteUncoveredPinFromTheRegionRouterIsAnEstimate(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	// The exact error the native repository reports, numbers and all.
	repo.routesErr = fmt.Errorf("%w: pickup is 50113 m from the nearest road vertex, beyond the 50000 m snap radius",
		repository.ErrPinUncovered)

	got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("an uncovered pin must not be an error (it answered 500 before): %v", err)
	}
	assertStraightLineEstimate(t, got, sjPin, sjDropPin)
	if len(repo.routeIDs) != 1 || repo.routeIDs[0].RegionID != "cr-sj" {
		t.Errorf("RouteInRegion calls = %+v, want exactly one in cr-sj", repo.routeIDs)
	}
}

// The band itself, named: under the shipped 50000 m radius there is a ~265 m
// slice of pins the SQL resolver calls covered and the Go gate calls not. Every
// pin in it must answer an estimate. The distances are the ones each formula
// reports for the same pin (PostGIS on the left, the Go gate on the right), so
// the band is pinned as the two measurements, not as a rounding curiosity.
func TestGetRouteRadiusBoundaryBandIsAnEstimateNotAnError(t *testing.T) {
	t.Setenv("ROUTING_SNAP_RADIUS_M", "")
	radiusM := config.Load().RoutingSnapRadiusM
	if radiusM <= 0 {
		t.Fatalf("shipped radius = %v; the band under test does not exist", radiusM)
	}

	band := []struct {
		name      string
		resolverM float64 // what the region resolver's Snap measured (covered)
		gateM     float64 // what the engine's own gate measures for the same pin
	}{
		{name: "just_inside_the_radius", resolverM: 49850, gateM: 50113},
		{name: "almost_on_the_radius", resolverM: 49990, gateM: 50255},
	}

	for _, tc := range band {
		t.Run(tc.name, func(t *testing.T) {
			if !repository.WithinSnapRadius(tc.resolverM, radiusM) {
				t.Fatalf("fixture: %v m must be covered under the %v m radius for the band to exist", tc.resolverM, radiusM)
			}
			if repository.WithinSnapRadius(tc.gateM, radiusM) {
				t.Fatalf("fixture: the gate's %v m must be outside the %v m radius for the band to exist", tc.gateM, radiusM)
			}

			// The resolver covered both pins; the router rejects the pickup the
			// way the native gate did before the fix.
			repo := newRadiusRepo(registry(), config.Load(), map[pinKey]float64{
				pinKey(sjPin):     tc.resolverM,
				pinKey(sjDropPin): 1200,
			})
			repo.routesErr = fmt.Errorf("%w: pickup is %.0f m from the nearest road vertex, beyond the %.0f m snap radius",
				repository.ErrPinUncovered, tc.gateM, radiusM)

			got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
			if err != nil {
				t.Fatalf("a pin in the boundary band answered %v, not an estimate", err)
			}
			assertStraightLineEstimate(t, got, sjPin, sjDropPin)
		})
	}
}

// N2: the legacy path. A repo without RegionSource (every mock, and a
// deployment whose routing_regions registry cannot be read) has no resolver at
// all, so the repository's own snap gate is the coverage authority — and it had
// NO estimate branch, which turned every pin beyond the radius into a 500.
func TestLegacyRouteUncoveredPinIsAnEstimate(t *testing.T) {
	repo := &navRepoFake{err: fmt.Errorf("%w: dropoff is 66000 m from the nearest road vertex, beyond the 50000 m snap radius",
		repository.ErrPinUncovered)}

	got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("an uncovered pin on the unscoped path must be an estimate, not an error: %v", err)
	}
	assertStraightLineEstimate(t, got, sjPin, sjDropPin)
	if len(repo.pathIDs) != 1 {
		t.Errorf("expected one GetShortestPath call, got %v", repo.pathIDs)
	}
}

// The other half of the rule: only a DATA GAP is an estimate. A pair of pins
// the radius covers and the network cannot connect is a real routing failure,
// and the error the handler sees must still be routing.ErrNoRoute — flattening
// it into a straight line would draw a route the road network does not serve.
func TestCoveredButUnroutablePairStillSurfacesTheRoutingError(t *testing.T) {
	t.Run("region_path", func(t *testing.T) {
		repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
		repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
		repo.routesErr = routing.ErrNoRoute

		got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
		if !errors.Is(err, routing.ErrNoRoute) {
			t.Fatalf("err = %v, want routing.ErrNoRoute", err)
		}
		if errors.Is(err, repository.ErrPinUncovered) {
			t.Error("a genuine no-path must not be reported as an uncovered pin")
		}
		if got != nil {
			t.Error("a failed route must return no RouteInfo at all")
		}
	})

	t.Run("legacy_path", func(t *testing.T) {
		repo := &navRepoFake{err: routing.ErrNoRoute}

		got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
		if !errors.Is(err, routing.ErrNoRoute) {
			t.Fatalf("err = %v, want routing.ErrNoRoute", err)
		}
		if got != nil {
			t.Error("a failed route must return no RouteInfo at all")
		}
	})

	t.Run("internal_faults_are_not_estimates", func(t *testing.T) {
		repo := &navRepoFake{err: errors.New("pq: could not connect to road_network_edges_pgr")}

		got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
		if err == nil {
			t.Fatalf("an engine fault must stay an error, got %+v", got)
		}
	})
}

// The new branches must not swallow the success path: a covered trip is still a
// road route with a meters distance, never a straight line.
func TestCoveredTripStillReturnsTheRoadRoute(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {
			{NodeID: 1, NodeSeq: 0, Lat: 9.9350, Lng: -84.0800},
			{NodeID: 2, NodeSeq: 1, Lat: 9.9433, Lng: -84.0733, AggCost: 2094},
		},
	}

	got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("a covered, in-region trip must not be an estimate")
	}
	if got.DistanceMeters != 2094 || got.DurationSecs != 2094/11 {
		t.Errorf("got %d m / %d s, want the routed 2094 m / %d s", got.DistanceMeters, got.DurationSecs, 2094/11)
	}
	if len(got.Polyline) != 3 {
		t.Errorf("polyline = %+v, want pin + node + pin", got.Polyline)
	}
}

// Which errors count as a data gap, stated once so the two call sites cannot
// drift apart.
func TestRoutingDataGapClassification(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{name: "uncovered_pin", err: repository.ErrPinUncovered, want: true},
		{name: "wrapped_uncovered_pin", err: fmt.Errorf("route: %w", repository.ErrPinUncovered), want: true},
		{name: "datasource_unavailable", err: fmt.Errorf("dialing lc-db: %w", repository.ErrDatasourceUnavailable), want: true},
		{name: "no_path", err: routing.ErrNoRoute, want: false},
		{name: "internal", err: errors.New("pq: could not connect"), want: false},
		{name: "nil", err: nil, want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := routingDataGap(tc.err); got != tc.want {
				t.Errorf("routingDataGap(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

// assertStraightLineEstimate is the 200-with-is_estimate contract: a straight
// line between the pins, the haversine distance, and duration = distance / 11.
func assertStraightLineEstimate(t *testing.T, got *RouteInfo, from, to [2]float64) {
	t.Helper()
	if got == nil {
		t.Fatal("no RouteInfo returned")
	}
	if !got.IsEstimate {
		t.Error("IsEstimate must be true: a straight line drawn as a road route is the failure mode")
	}
	wantDist := int(math.Round(routing.HaversineMeters(from[0], from[1], to[0], to[1])))
	if got.DistanceMeters != wantDist {
		t.Errorf("distance = %d m, want the straight line %d m", got.DistanceMeters, wantDist)
	}
	if wantDur := wantDist / avgSpeedMps; got.DurationSecs != wantDur {
		t.Errorf("duration = %d s, want %d s (distance / %d)", got.DurationSecs, wantDur, avgSpeedMps)
	}
	if len(got.Polyline) != 2 {
		t.Fatalf("polyline = %+v, want exactly the two pinned points", got.Polyline)
	}
	if got.Polyline[0] != (model.LatLng{Lat: from[0], Lng: from[1]}) ||
		got.Polyline[1] != (model.LatLng{Lat: to[0], Lng: to[1]}) {
		t.Errorf("polyline must be the two pins, got %+v", got.Polyline)
	}
}
