package service

import (
	"errors"
	"testing"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/routing"
)

// GetItineraryRoute sums the consecutive two-point legs and exposes them as
// per-leg slices on the aggregate.
func TestGetItineraryRouteSumsLegs(t *testing.T) {
	svc := legNav(legSpec{distance: 5000}, legSpec{distance: 3000})
	waypoints := []model.LatLng{
		{Lat: 9.93, Lng: -84.08},
		{Lat: 9.935, Lng: -84.077},
		{Lat: 9.94, Lng: -84.07},
	}

	got, err := svc.GetItineraryRoute(waypoints)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("an all-routed itinerary must not be an estimate")
	}
	if got.DistanceMeters != 8000 {
		t.Errorf("distance = %d, want the summed 8000", got.DistanceMeters)
	}
	if got.DurationSecs != 5000/avgSpeedMps+3000/avgSpeedMps {
		t.Errorf("duration = %d, want the summed leg durations", got.DurationSecs)
	}
	if len(got.Legs) != 2 {
		t.Fatalf("legs = %+v, want 2", got.Legs)
	}
	if got.Legs[0].DistanceMeters != 5000 || got.Legs[1].DistanceMeters != 3000 {
		t.Errorf("per-leg distances = %+v, want 5000 then 3000", got.Legs)
	}
	// The polyline runs through every waypoint (pinned endpoints included).
	if len(got.Polyline) < len(waypoints) {
		t.Errorf("polyline = %+v, want at least the %d waypoints", got.Polyline, len(waypoints))
	}
}

// Two waypoints delegate straight to GetRoute, leaving Legs nil.
func TestGetItineraryRouteTwoPointsDelegates(t *testing.T) {
	svc := legNav(legSpec{distance: 2094})
	got, err := svc.GetItineraryRoute([]model.LatLng{
		{Lat: 9.93, Lng: -84.08},
		{Lat: 9.94, Lng: -84.07},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.DistanceMeters != 2094 || got.IsEstimate {
		t.Errorf("got %+v, want the single 2094 m route", got)
	}
	if len(got.Legs) != 0 {
		t.Errorf("legs = %+v, want nil on the two-point path", got.Legs)
	}
}

// A same-region multi-leg itinerary keeps the resolved RegionID.
func TestGetItineraryRouteKeepsResolvedRegion(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	stop := [2]float64{9.935, -84.077}
	repo.covered[pinKey(stop)] = map[string]bool{"cr-sj": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 2094}},
	}
	svc := NewNavigationService(repo)

	got, err := svc.GetItineraryRoute([]model.LatLng{
		{Lat: sjPin[0], Lng: sjPin[1]},
		{Lat: stop[0], Lng: stop[1]},
		{Lat: sjDropPin[0], Lng: sjDropPin[1]},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.RegionID != "cr-sj" {
		t.Errorf("region = %q, want the resolved cr-sj", got.RegionID)
	}
	if got.IsEstimate {
		t.Error("an all-in-region itinerary must not be an estimate")
	}
}

// A differing/second-region leg turns the WHOLE itinerary into a straight-line
// estimate with NO owning region.
func TestGetItineraryRouteCrossRegionIsStraightLineEstimate(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	stop := [2]float64{9.935, -84.077}
	repo.covered[pinKey(stop)] = map[string]bool{"cr-sj": true}
	repo.covered[pinKey(lcPin)] = map[string]bool{"cr-lc": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 2094}},
		"cr-lc": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 2094}},
	}
	svc := NewNavigationService(repo)

	waypoints := []model.LatLng{
		{Lat: sjPin[0], Lng: sjPin[1]},
		{Lat: stop[0], Lng: stop[1]},
		{Lat: lcPin[0], Lng: lcPin[1]},
	}
	got, err := svc.GetItineraryRoute(waypoints)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.IsEstimate {
		t.Error("a second-region leg must make the whole itinerary an estimate")
	}
	if got.RegionID != "" {
		t.Errorf("region = %q, want empty on a cross-region estimate", got.RegionID)
	}
	// Pinned numeric oracles (independent law-of-cosines, R = 6371000), NOT a
	// recomputation through routing.HaversineMeters: the production estimate
	// path uses that very function (navigation.go:328), so recomputing here
	// would make a wrong great-circle formula undetectable. Each leg is the
	// per-leg rounding the estimate applies, then summed.
	legDist := []int{646, 98251} // sjPin->stop, stop->lcPin
	wantDist := legDist[0] + legDist[1]
	if got.DistanceMeters != wantDist {
		t.Errorf("distance = %d, want the straight-line sum %d", got.DistanceMeters, wantDist)
	}
	// Duration is the sum of the per-leg durations (each truncated), which is
	// what the fare legs use; it can differ from totalDistance/avgSpeedMps by a
	// second.
	wantDur := legDist[0]/avgSpeedMps + legDist[1]/avgSpeedMps
	if got.DurationSecs != wantDur {
		t.Errorf("duration = %d, want the summed leg durations %d", got.DurationSecs, wantDur)
	}
	// The estimate must carry one leg per waypoint pair, not the collapsed
	// single aggregate leg.
	if len(got.Legs) != 2 {
		t.Fatalf("legs = %+v, want 2", got.Legs)
	}
	legSum := 0
	for i, leg := range got.Legs {
		if leg.DistanceMeters != legDist[i] || leg.DurationSecs != legDist[i]/avgSpeedMps {
			t.Errorf("leg %d = %+v, want %d m / %d s", i, leg, legDist[i], legDist[i]/avgSpeedMps)
		}
		legSum += leg.DistanceMeters
	}
	if legSum != got.DistanceMeters {
		t.Errorf("Σ leg distances = %d, want the aggregate %d", legSum, got.DistanceMeters)
	}
	if got.AscentM != 0 || got.ElevationAware {
		t.Errorf("estimate elevation = %v/%v, want 0/false", got.AscentM, got.ElevationAware)
	}
}

// A genuine routing failure on a leg propagates as an error (HTTP 500), never
// as a flattened estimate.
func TestGetItineraryRouteHardLegErrorPropagates(t *testing.T) {
	svc := NewNavigationService(&navRepoFake{err: routing.ErrNoRoute})
	_, err := svc.GetItineraryRoute([]model.LatLng{
		{Lat: 9.93, Lng: -84.08},
		{Lat: 9.935, Lng: -84.077},
		{Lat: 9.94, Lng: -84.07},
	})
	if !errors.Is(err, routing.ErrNoRoute) {
		t.Fatalf("got %v, want ErrNoRoute", err)
	}
}

// Fewer than two waypoints is a programming error, not a route.
func TestGetItineraryRouteNeedsTwoWaypoints(t *testing.T) {
	if _, err := (&NavigationService{}).GetItineraryRoute([]model.LatLng{{Lat: 1, Lng: 2}}); err == nil {
		t.Fatal("a one-waypoint itinerary must error")
	}
}
