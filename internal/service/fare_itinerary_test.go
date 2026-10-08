package service

import (
	"math"
	"testing"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// legSpec is one consecutive-waypoint leg a test mock should return.
type legSpec struct {
	distance       int
	ascent         float64
	elevationAware bool
}

// legNav returns a NavigationService whose consecutive GetRoute calls return
// the given leg specs in order. It is a legacy (non-RegionSource) repo, so
// every leg takes the unscoped path — the same shape the db-less harness uses.
func legNav(specs ...legSpec) *NavigationService {
	i := 0
	return NewNavigationService(&mockNavRepo{
		pathFunc: func(_, _, _, _ float64) ([]repository.RouteResult, error) {
			spec := legSpec{}
			if i < len(specs) {
				spec = specs[i]
			}
			i++
			return []repository.RouteResult{
				{NodeID: 1, AggCost: 0},
				{NodeID: 2, AggCost: float64(spec.distance), AscentM: spec.ascent, ElevationAware: spec.elevationAware},
			}, nil
		},
	})
}

func sumDistances(specs []legSpec) int {
	total := 0
	for _, s := range specs {
		total += s.distance
	}
	return total
}

func sumDurations(specs []legSpec) int {
	total := 0
	for _, s := range specs {
		total += s.distance / avgSpeedMps
	}
	return total
}

// itineraryTotalCents recomputes the expected single-summed price from the card
// the fake stores, so a test asserts arithmetic rather than a hardcoded dollar.
func itineraryTotalCents(repo *fakeFareRepo, vehicleType string, distance, duration int, uplift float64, conditions float64) float64 {
	card := repo.rates["cr-sj|"+vehicleType]
	distCents := (float64(distance) / 1000.0) * float64(card.PerKmCents) * (1 + uplift)
	timeCents := (float64(duration) / 60.0) * float64(card.PerMinCents)
	return math.Round((float64(card.BaseFareCents) + distCents + timeCents) * conditions)
}

// Zero stops must reproduce today's CalculateEstimate PRICE exactly for every
// class, with a synthetic single leg equal to the whole trip.
func TestCalculateItineraryEstimateZeroStopsMatchesCalculateEstimate(t *testing.T) {
	cases := []struct {
		vehicleType string
		wantTotal   float64
	}{
		{"sedan", 16.28},
		{"suv", 23.30},
		{"luxury", 34.57},
	}
	for _, tc := range cases {
		t.Run(tc.vehicleType, func(t *testing.T) {
			repo := newFakeFareRepo()
			svc := NewFareService(fixedRouteGeo(10), legacyNav(), repo, testFareConfig())

			direct, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, tc.vehicleType)
			if err != nil {
				t.Fatalf("CalculateEstimate: %v", err)
			}
			itinerary, err := svc.CalculateItineraryEstimate(9.93, -84.08, nil, 9.94, -84.07, tc.vehicleType)
			if err != nil {
				t.Fatalf("CalculateItineraryEstimate: %v", err)
			}

			if direct.Total != tc.wantTotal || itinerary.Total != tc.wantTotal {
				t.Errorf("totals = direct %v / itinerary %v, want the legacy %v",
					direct.Total, itinerary.Total, tc.wantTotal)
			}
			// The zero-stop path is structurally the same call: every priced
			// field must match.
			if direct.Total != itinerary.Total || direct.DistanceFare != itinerary.DistanceFare ||
				direct.TimeFare != itinerary.TimeFare || direct.BaseFare != itinerary.BaseFare ||
				direct.RegionID != itinerary.RegionID || direct.RateID != itinerary.RateID {
				t.Errorf("itinerary differs from direct at zero stops:\n direct    = %+v\n itinerary = %+v", direct, itinerary)
			}
			if itinerary.IsEstimate {
				t.Error("a covered mock route must not be flagged is_estimate")
			}
			// Exactly one synthesized leg equal to the whole trip.
			if len(itinerary.Legs) != 1 {
				t.Fatalf("legs = %+v, want exactly one", itinerary.Legs)
			}
			leg := itinerary.Legs[0]
			if leg.DistanceMeters != 5000 || leg.DurationSecs != 5000/avgSpeedMps {
				t.Errorf("synthetic leg = %+v, want the whole 5000 m trip", leg)
			}
			if math.Abs(leg.DistanceFare-itinerary.DistanceFare) > 1e-9 ||
				math.Abs(leg.TimeFare-itinerary.TimeFare) > 1e-9 {
				t.Errorf("single leg does not sum to the aggregate: leg %+v agg %v/%v",
					leg, itinerary.DistanceFare, itinerary.TimeFare)
			}
		})
	}
}

// One and two stops: the total is the price over the SUMMED leg distance and
// duration, the per-leg fares sum to the aggregate (excluding base and
// multiplier), and the documented total reconstruction holds.
func TestCalculateItineraryEstimateSummedLegs(t *testing.T) {
	cases := []struct {
		name  string
		specs []legSpec
		stops []model.LatLng
	}{
		{
			name:  "one stop",
			specs: []legSpec{{distance: 5000}, {distance: 3000}},
			stops: []model.LatLng{{Lat: 9.935, Lng: -84.077}},
		},
		{
			name:  "two stops",
			specs: []legSpec{{distance: 5000}, {distance: 3000}, {distance: 1200}},
			stops: []model.LatLng{{Lat: 9.935, Lng: -84.077}, {Lat: 9.938, Lng: -84.075}},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeFareRepo()
			svc := NewFareService(fixedRouteGeo(10), legNav(tc.specs...), repo, testFareConfig())

			est, err := svc.CalculateItineraryEstimate(9.93, -84.08, tc.stops, 9.94, -84.07, "sedan")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if est.IsEstimate {
				t.Error("a summed legacy route must not be flagged is_estimate")
			}

			totalDistance := sumDistances(tc.specs)
			totalDuration := sumDurations(tc.specs)
			wantTotalCents := itineraryTotalCents(repo, "sedan", totalDistance, totalDuration, est.GradeUpliftPct, est.SurgeMultiplier)
			if gotCents := math.Round(est.Total * 100); gotCents != wantTotalCents {
				t.Errorf("total = %.2f (%v c), want %v c over %d m / %d s",
					est.Total, gotCents, wantTotalCents, totalDistance, totalDuration)
			}

			if len(est.Legs) != len(tc.specs) {
				t.Fatalf("legs = %d, want %d", len(est.Legs), len(tc.specs))
			}
			var distSum, timeSum float64
			for i, leg := range est.Legs {
				if leg.DistanceMeters != tc.specs[i].distance {
					t.Errorf("leg %d distance = %d, want %d", i, leg.DistanceMeters, tc.specs[i].distance)
				}
				distSum += leg.DistanceFare
				timeSum += leg.TimeFare
			}
			if math.Abs(distSum-est.DistanceFare) > 1e-9 {
				t.Errorf("Σ legs.distance_fare = %v, want the aggregate %v", distSum, est.DistanceFare)
			}
			if math.Abs(timeSum-est.TimeFare) > 1e-9 {
				t.Errorf("Σ legs.time_fare = %v, want the aggregate %v", timeSum, est.TimeFare)
			}
			// The documented reconstruction: one base × multiplier plus the
			// summed legs reproduces the total (within a cent of the one round).
			reconstructed := math.Round((est.BaseFare+distSum+timeSum)*est.SurgeMultiplier*100) / 100
			if math.Abs(reconstructed-est.Total) > 0.011 {
				t.Errorf("reconstructed total = %v, want %v", reconstructed, est.Total)
			}
		})
	}
}

// Same-region multi-leg against the real resolver keeps the RegionID and prices
// with that region's card (never the default when a real region was resolved).
func TestCalculateItineraryEstimateKeepsResolvedRegion(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	stop := [2]float64{9.935, -84.077}
	repo.covered[pinKey(stop)] = map[string]bool{"cr-sj": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 2094}},
	}
	svc := NewFareService(fixedRouteGeo(10), NewNavigationService(repo), newFakeFareRepo(), testFareConfig())

	est, err := svc.CalculateItineraryEstimate(sjPin[0], sjPin[1],
		[]model.LatLng{{Lat: stop[0], Lng: stop[1]}}, sjDropPin[0], sjDropPin[1], "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.IsEstimate {
		t.Error("an all-in-region itinerary must not be an estimate")
	}
	if est.RegionID != "cr-sj" {
		t.Errorf("region = %q, want the resolved cr-sj", est.RegionID)
	}
	if len(est.Legs) != 2 {
		t.Fatalf("legs = %d, want 2", len(est.Legs))
	}
}

// A stop in a second region turns the WHOLE itinerary into a straight-line
// estimate priced against the DEFAULT card, never region A's card over
// region B's geometry.
func TestCalculateItineraryEstimateCrossRegionIsEstimateOnDefaultCard(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	stop := [2]float64{9.935, -84.077}
	repo.covered[pinKey(stop)] = map[string]bool{"cr-sj": true}
	repo.covered[pinKey(lcPin)] = map[string]bool{"cr-lc": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 2094}},
		"cr-lc": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 2094}},
	}

	fares := newFakeFareRepo()
	fares.addRegion("cr-lc", "USD", "America/Costa_Rica")
	fares.addRate("cr-lc", "sedan", "USD", 900, 250, 90) // a distinct card

	svc := NewFareService(fixedRouteGeo(10), NewNavigationService(repo), fares, testFareConfig())

	est, err := svc.CalculateItineraryEstimate(sjPin[0], sjPin[1],
		[]model.LatLng{{Lat: stop[0], Lng: stop[1]}}, lcPin[0], lcPin[1], "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !est.IsEstimate {
		t.Error("a second-region stop must make the whole itinerary an estimate")
	}
	// The default cr-sj card is what priced it: the fare response names the
	// card's region, never the second region's card.
	if est.RegionID != "cr-sj" {
		t.Errorf("region = %q, want the default card's cr-sj", est.RegionID)
	}
	if est.BaseFare != 5.0 || est.DistanceRate != 1.5 {
		t.Errorf("priced with base %v/km %v, want the default cr-sj 5.0/1.5", est.BaseFare, est.DistanceRate)
	}
	// One stop = two waypoint pairs: the estimate must carry a leg per leg, not
	// collapse to the single synthesized leg the old aggregate-only shape had.
	if len(est.Legs) != 2 {
		t.Fatalf("legs = %d, want stops+1 = 2", len(est.Legs))
	}
	var distSum, timeSum float64
	for _, leg := range est.Legs {
		distSum += leg.DistanceFare
		timeSum += leg.TimeFare
	}
	if math.Abs(distSum-est.DistanceFare) > 1e-9 {
		t.Errorf("Σ legs.distance_fare = %v, want the aggregate %v", distSum, est.DistanceFare)
	}
	if math.Abs(timeSum-est.TimeFare) > 1e-9 {
		t.Errorf("Σ legs.time_fare = %v, want the aggregate %v", timeSum, est.TimeFare)
	}
	reconstructed := math.Round((est.BaseFare+distSum+timeSum)*est.SurgeMultiplier*100) / 100
	if math.Abs(reconstructed-est.Total) > 0.011 {
		t.Errorf("reconstructed total = %v, want %v", reconstructed, est.Total)
	}
}

// An UNCOVERED multi-stop itinerary (every leg itself an estimate) must still
// return one leg per consecutive waypoint pair — the same stops+1 shape as a
// covered itinerary — and the legs must sum to the aggregate. This is the
// contract drift the aggregate-only estimateRoute answer used to violate:
// GetItineraryRoute fell into itineraryEstimate, which carried no Legs, so
// fareLegs synthesized a single leg and the rider UI's hasMultipleLegs gate
// suppressed the breakdown.
func TestCalculateItineraryEstimateUncoveredMultiStopKeepsLegs(t *testing.T) {
	repo := newFakeFareRepo()
	// Every leg is a data gap: GetRoute degrades each pair to estimateRoute,
	// so GetItineraryRoute takes the whole-itinerary estimate branch.
	svc := NewFareService(fixedRouteGeo(10), NewNavigationService(&mockNavRepo{
		pathFunc: func(_, _, _, _ float64) ([]repository.RouteResult, error) {
			return nil, repository.ErrPinUncovered
		},
	}), repo, testFareConfig())

	// Two stops -> three legs; coordinates far enough apart for distinct
	// haversine distances.
	est, err := svc.CalculateItineraryEstimate(9.93, -84.08, []model.LatLng{
		{Lat: 9.935, Lng: -84.077},
		{Lat: 9.938, Lng: -84.075},
	}, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !est.IsEstimate {
		t.Error("an uncovered itinerary must be flagged is_estimate")
	}
	if len(est.Legs) != 3 {
		t.Fatalf("legs = %d, want stops+1 = 3", len(est.Legs))
	}
	var distSum, timeSum float64
	for _, leg := range est.Legs {
		if leg.DistanceMeters <= 0 || leg.DurationSecs <= 0 {
			t.Errorf("leg has no distance/duration: %+v", leg)
		}
		distSum += leg.DistanceFare
		timeSum += leg.TimeFare
	}
	if math.Abs(distSum-est.DistanceFare) > 1e-9 {
		t.Errorf("Σ legs.distance_fare = %v, want the aggregate %v", distSum, est.DistanceFare)
	}
	if math.Abs(timeSum-est.TimeFare) > 1e-9 {
		t.Errorf("Σ legs.time_fare = %v, want the aggregate %v", timeSum, est.TimeFare)
	}
	reconstructed := math.Round((est.BaseFare+distSum+timeSum)*est.SurgeMultiplier*100) / 100
	if math.Abs(reconstructed-est.Total) > 0.011 {
		t.Errorf("reconstructed total = %v, want %v", reconstructed, est.Total)
	}
}

// One flat leg plus one elevated leg fails the WHOLE itinerary flat: no ascent,
// no uplift, not elevation-aware.
func TestCalculateItineraryEstimatePartialElevationFailsFlat(t *testing.T) {
	repo := newFakeFareRepo()
	repo.setUplift("cr-sj", "sedan", 0.1, 0.5)
	svc := NewFareService(fixedRouteGeo(10), legNav(
		legSpec{distance: 5000, ascent: 100, elevationAware: true},
		legSpec{distance: 5000, ascent: 0, elevationAware: false},
	), repo, testFareConfig())

	est, err := svc.CalculateItineraryEstimate(9.93, -84.08,
		[]model.LatLng{{Lat: 9.935, Lng: -84.077}}, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.AscentM != 0 || est.GradeUpliftPct != 0 {
		t.Errorf("partial-coverage climb = ascent %v uplift %v, want 0/0", est.AscentM, est.GradeUpliftPct)
	}
	// Priced flat: the total uses uplift 0.
	wantCents := itineraryTotalCents(repo, "sedan", 10000, sumDurations([]legSpec{{distance: 5000}, {distance: 5000}}), 0, est.SurgeMultiplier)
	if got := math.Round(est.Total * 100); got != wantCents {
		t.Errorf("total = %v c, want the flat %v c", got, wantCents)
	}
}

// When every leg is elevation-aware the shared uplift is derived ONCE from the
// summed ascent and distance and applied to the summed distance leg.
func TestCalculateItineraryEstimateSharedUpliftOnSummedAscent(t *testing.T) {
	repo := newFakeFareRepo()
	repo.setUplift("cr-sj", "sedan", 0.1, 0.5)
	svc := NewFareService(fixedRouteGeo(10), legNav(
		legSpec{distance: 5000, ascent: 100, elevationAware: true},
		legSpec{distance: 5000, ascent: 100, elevationAware: true},
	), repo, testFareConfig())

	est, err := svc.CalculateItineraryEstimate(9.93, -84.08,
		[]model.LatLng{{Lat: 9.935, Lng: -84.077}}, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.AscentM != 200 {
		t.Errorf("ascent = %v, want the summed 200", est.AscentM)
	}
	// 200 m over 10 km = 20 m/km * 0.1 = 2.0, capped at 0.5.
	if est.GradeUpliftPct != 0.5 {
		t.Errorf("uplift = %v, want the shared capped 0.5", est.GradeUpliftPct)
	}
}
