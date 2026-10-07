package service

import (
	"math"
	"testing"

	"ride-hailing-api/internal/repository"
)

// elevatedNav returns a navigation service whose single route reports the given
// RAW ascent and is elevation-aware, so the fare service sees the exact seam the
// landed elevation flip produces. distanceMeters also drives the duration
// (distance / 11), exactly as routeInfo does.
func elevatedNav(distanceMeters int, ascentM float64) *NavigationService {
	return NewNavigationService(&mockNavRepo{
		pathFunc: func(_, _, _, _ float64) ([]repository.RouteResult, error) {
			return []repository.RouteResult{
				{NodeID: 1, AggCost: 0},
				{NodeID: 2, AggCost: float64(distanceMeters), AscentM: ascentM, DescentM: ascentM, ElevationAware: true},
			}, nil
		},
	})
}

// TestGradeUpliftPct pins the pure uplift math and, above all, every fail-flat
// branch: no elevation awareness, no distance, a disabled card, or no climb
// must each yield exactly 0 (never NaN, never negative).
func TestGradeUpliftPct(t *testing.T) {
	const factor, cap = 0.001377, 0.15

	cases := []struct {
		name           string
		ascentM        float64
		distanceMeters int
		aware          bool
		factor         float64
		cap            float64
		want           float64
	}{
		{"known climb 412 m over 5 km", 412, 5000, true, factor, cap, 82.4 * factor},
		{"no elevation coverage fails flat", 412, 5000, false, factor, cap, 0},
		{"zero distance fails flat and never NaN", 412, 0, true, factor, cap, 0},
		{"negative distance fails flat", 412, -10, true, factor, cap, 0},
		{"flat route has nothing to price", 0, 5000, true, factor, cap, 0},
		{"descent never credits", -50, 5000, true, factor, cap, 0},
		{"disabled card (factor 0) fails flat", 412, 5000, true, 0, cap, 0},
		{"disabled card (cap 0) fails flat", 412, 5000, true, factor, 0, 0},
		{"huge ascent clamps at the cap", 1_000_000, 5000, true, factor, cap, cap},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := gradeUpliftPct(tc.ascentM, tc.distanceMeters, tc.aware, tc.factor, tc.cap)
			if math.IsNaN(got) || math.IsInf(got, 0) {
				t.Fatalf("uplift = %v, want a finite number", got)
			}
			if got < 0 {
				t.Fatalf("uplift = %v, must never be negative", got)
			}
			if math.Abs(got-tc.want) > 1e-12 {
				t.Errorf("uplift = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestFareService_GradeUpliftAppliedToDistanceLegOnly proves the fare-level
// effect: the climb raises ONLY the distance leg, base/time/conditions are
// untouched, and the applied fraction is echoed on the estimate.
func TestFareService_GradeUpliftAppliedToDistanceLegOnly(t *testing.T) {
	fares := newFakeFareRepo()
	fares.setUplift("cr-sj", "sedan", 0.001377, 0.15)

	flat := NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())
	elevated := NewFareService(fixedRouteGeo(10), elevatedNav(5000, 412), fares, testFareConfig())

	flatEst, err := flat.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("flat: %v", err)
	}
	est, err := elevated.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("elevated: %v", err)
	}

	// 412 m / 5 km = 82.4 m/km; 82.4 * 0.001377 = 0.1134648.
	wantUplift := 82.4 * 0.001377
	if math.Abs(est.GradeUpliftPct-wantUplift) > 1e-12 {
		t.Errorf("grade_uplift_pct = %v, want %v", est.GradeUpliftPct, wantUplift)
	}
	if est.AscentM != 412 {
		t.Errorf("ascent = %v, want 412", est.AscentM)
	}
	// Distance leg grows by (1 + uplift): 5 km * 1.50 * 1.1134648 = 8.35098.
	if want := 7.5 * (1 + wantUplift); math.Abs(est.DistanceFare-want) > 1e-9 {
		t.Errorf("distance_fare = %v, want %v", est.DistanceFare, want)
	}
	// The other three components never move.
	if est.BaseFare != flatEst.BaseFare || est.TimeFare != flatEst.TimeFare || est.SurgeMultiplier != flatEst.SurgeMultiplier {
		t.Errorf("base/time/conditions moved with the uplift: base %v/%v time %v/%v surge %v/%v",
			est.BaseFare, flatEst.BaseFare, est.TimeFare, flatEst.TimeFare, est.SurgeMultiplier, flatEst.SurgeMultiplier)
	}
	if est.Total <= flatEst.Total {
		t.Errorf("total %v is not above the flat %v despite a climb", est.Total, flatEst.Total)
	}
}

// TestFareService_FailFlatEquivalence is the hard contract: for every failure
// mode the elevated card must price EXACTLY the pre-upgrade fare.
func TestFareService_FailFlatEquivalence(t *testing.T) {
	baseline := func() float64 {
		fares := newFakeFareRepo() // default card: uplift knobs at 0
		svc := NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())
		est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
		if err != nil {
			t.Fatalf("baseline: %v", err)
		}
		return est.Total
	}()
	const baselineNoCoverage = 16.28

	cases := []struct {
		name string
		nav  *NavigationService
		card func(*fakeFareRepo)
	}{
		{"elevation_aware=false", legacyNav(), func(f *fakeFareRepo) { f.setUplift("cr-sj", "sedan", 0.001377, 0.15) }},
		{"card disabled", elevatedNav(5000, 412), func(f *fakeFareRepo) {}},
		{"flat route", elevatedNav(5000, 0), func(f *fakeFareRepo) { f.setUplift("cr-sj", "sedan", 0.001377, 0.15) }},
		{"descent only never credits", elevatedNav(5000, -100), func(f *fakeFareRepo) { f.setUplift("cr-sj", "sedan", 0.001377, 0.15) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fares := newFakeFareRepo()
			tc.card(fares)
			svc := NewFareService(fixedRouteGeo(10), tc.nav, fares, testFareConfig())
			est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if est.GradeUpliftPct != 0 {
				t.Errorf("grade_uplift_pct = %v, want exactly 0", est.GradeUpliftPct)
			}
			if est.Total != baselineNoCoverage {
				t.Errorf("total = %v, want the flat %v", est.Total, baselineNoCoverage)
			}
		})
	}

	if baseline != baselineNoCoverage {
		t.Fatalf("sanity: the default card must price %v, got %v", baselineNoCoverage, baseline)
	}

	// A zero-length leg has no distance to price and must yield no uplift (and
	// no NaN/Inf). Its total is base-only, so it is asserted separately rather
	// than against the 5 km baseline.
	fares := newFakeFareRepo()
	fares.setUplift("cr-sj", "sedan", 0.001377, 0.15)
	svc := NewFareService(fixedRouteGeo(10), elevatedNav(0, 412), fares, testFareConfig())
	zero, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("zero-length leg: %v", err)
	}
	if math.IsNaN(zero.GradeUpliftPct) || zero.GradeUpliftPct != 0 {
		t.Errorf("zero-length grade_uplift_pct = %v, want 0", zero.GradeUpliftPct)
	}
	if zero.Total != 5.0 {
		t.Errorf("zero-length total = %v, want the base-only 5.00", zero.Total)
	}
}

// TestFareService_GradeUpliftClampsAtCap: a pathological ascent must not produce
// an absurd fare — the fraction pins at the card's cap.
func TestFareService_GradeUpliftClampsAtCap(t *testing.T) {
	fares := newFakeFareRepo()
	fares.setUplift("cr-sj", "sedan", 0.001377, 0.15)
	svc := NewFareService(fixedRouteGeo(10), elevatedNav(5000, 1_000_000), fares, testFareConfig())

	est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.GradeUpliftPct != 0.15 {
		t.Errorf("grade_uplift_pct = %v, want the cap 0.15", est.GradeUpliftPct)
	}
	if want := 7.5 * 1.15; math.Abs(est.DistanceFare-want) > 1e-9 {
		t.Errorf("distance_fare = %v, want the capped %v", est.DistanceFare, want)
	}
}

// TestGradeUpliftRealSJValues pins the shipped sedan factor against a few real
// SJ ascent-per-km values (the ~412 m climb over ~5 km near San José is the
// measured example used elsewhere in this suite).
func TestGradeUpliftRealSJValues(t *testing.T) {
	const factor, cap = 0.001377, 0.15
	cases := []struct {
		name         string
		ascentPerKm  float64
		wantFraction float64
	}{
		{"flat coastal leg", 0, 0},
		{"gentle 2% grade", 20, 20 * factor},
		{"moderate 5% grade", 50, 50 * factor},
		{"real SJ climb 412 m / 5 km", 82.4, 82.4 * factor},
		{"steep 12% grade", 120, cap},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Represent the value as an ascent over a fixed 1 km leg so the
			// per-km figure is exact.
			got := gradeUpliftPct(tc.ascentPerKm, 1000, true, factor, cap)
			if math.Abs(got-tc.wantFraction) > 1e-12 {
				t.Errorf("uplift for %v m/km = %v, want %v", tc.ascentPerKm, got, tc.wantFraction)
			}
		})
	}
}
