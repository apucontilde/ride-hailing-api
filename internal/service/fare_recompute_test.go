package service

import (
	"math"
	"testing"

	"ride-hailing-api/internal/model"
)

// These are the unit-level proofs for the completion fare recompute
// (api_plans/01_[fare]_actuals_recompute_on_completion.md). They drive
// FareService.RecomputeActualFare directly against the db-free fakeFareRepo, so
// the exact cents, the uncapped-both-directions policy, the booked-conditions
// reuse, the uplift-on-actual-distance rule, and every fallback branch are
// pinned without a database. The end-to-end completion/persistence proof lives
// in tests/fare_actuals_recompute_test.go.

// actualRide builds the minimal completed-ride snapshot the recompute reads.
func actualRide(rateID string, distanceM float64, durationS int, conditions float64) *model.Ride {
	return &model.Ride{
		ID:              "ride-recompute",
		FareRateID:      &rateID,
		ActualDistanceM: &distanceM,
		ActualDurationS: &durationS,
		SurgeMultiplier: conditions,
		// A deliberately un-booked-shaped quote: the recompute must ignore it.
		BaseFare: 1, DistanceFare: 1, TimeFare: 1, TotalFare: 3,
	}
}

// TestRecomputeActualFare_UncappedBothDirections is the product decision:
// the recomputed actual REPLACES the quote with no tolerance in EITHER
// direction. The default fake sedan card is 500c base / 150c per km / 50c per
// min.
func TestRecomputeActualFare_UncappedBothDirections(t *testing.T) {
	fares := newFakeFareRepo()
	cardID := fares.rates["cr-sj|sedan"].ID
	svc := NewFareService(nil, nil, fares, testFareConfig())

	t.Run("actual above booked charges the actual", func(t *testing.T) {
		// 10 km, 10 min: 500 + 1500 + 500 = 2500c = $25.00.
		est, err := svc.RecomputeActualFare(actualRide(cardID, 10000, 600, 1.0))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if est == nil {
			t.Fatal("expected a recompute, got the nil fallback")
		}
		if est.BaseFare != 5.0 || est.DistanceFare != 15.0 || est.TimeFare != 5.0 || est.Total != 25.0 {
			t.Errorf("components = base %v distance %v time %v total %v, want 5/15/5/25",
				est.BaseFare, est.DistanceFare, est.TimeFare, est.Total)
		}
	})

	t.Run("actual below booked charges the actual", func(t *testing.T) {
		// 2 km, 2 min: 500 + 300 + 100 = 900c = $9.00 (< the $25 "quote" above).
		est, err := svc.RecomputeActualFare(actualRide(cardID, 2000, 120, 1.0))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if est == nil {
			t.Fatal("expected a recompute, got the nil fallback")
		}
		if est.Total != 9.0 {
			t.Errorf("total = %v, want the uncapped actual 9.00", est.Total)
		}
	})
}

// TestRecomputeActualFare_ReusesBookedConditions pins the determinism rule: the
// demand/supply conditions are the BOOKED multiplier, reused verbatim, never
// re-sampled at completion (which would make a retry charge differently).
func TestRecomputeActualFare_ReusesBookedConditions(t *testing.T) {
	fares := newFakeFareRepo()
	cardID := fares.rates["cr-sj|sedan"].ID
	// Seed a demand window AND a zero driver count: if the recompute re-sampled
	// the world it would multiply by a different factor, not the booked 1.5.
	fares.windows["cr-sj"] = []model.FareDemandWindow{
		{Name: "surge", DayMask: 127, StartMinute: 0, EndMinute: 1440, Multiplier: 2.5},
	}
	svc := NewFareService(fixedRouteGeo(0), legacyNav(), fares, testFareConfig())

	// 5 km, 5 min: (500 + 750 + 250) * 1.5 = 2250c = $22.50.
	est, err := svc.RecomputeActualFare(actualRide(cardID, 5000, 300, 1.5))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.SurgeMultiplier != 1.5 {
		t.Fatalf("conditions = %v, want the booked 1.5", est.SurgeMultiplier)
	}
	if est.Total != 22.5 {
		t.Errorf("total = %v, want %v with the booked conditions", est.Total, 22.5)
	}
}

// TestRecomputeActualFare_GradeUpliftOnActualDistance pins that the capped climb
// uplift is re-derived from the booked RAW ascent and the ACTUAL distance (the
// per-km denominator), using the booked card's factor/cap.
func TestRecomputeActualFare_GradeUpliftOnActualDistance(t *testing.T) {
	fares := newFakeFareRepo()
	fares.setUplift("cr-sj", "sedan", 0.001377, 0.15)
	cardID := fares.rates["cr-sj|sedan"].ID
	svc := NewFareService(nil, nil, fares, testFareConfig())

	ride := actualRide(cardID, 10000, 600, 1.0)
	ascent := 412.0
	ride.GradeAscentM = &ascent

	// uplift = (412 / 10 km) * 0.001377 = 0.0567324.
	// distance = 10 * 150 * 1.0567324 = 1585.0986c; +500+500 = 2585.0986c
	// -> round 2585c = $25.85.
	est, err := svc.RecomputeActualFare(ride)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantUplift := 41.2 * 0.001377
	if math.Abs(est.GradeUpliftPct-wantUplift) > 1e-12 {
		t.Errorf("uplift = %v, want %v", est.GradeUpliftPct, wantUplift)
	}
	if est.Total != 25.85 {
		t.Errorf("total = %v, want the uplifted 25.85", est.Total)
	}

	// A NULL ascent is the honest "no uplift priced": fail flat, not a guess.
	ride.GradeAscentM = nil
	flat, err := svc.RecomputeActualFare(ride)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if flat.GradeUpliftPct != 0 || flat.Total != 25.0 {
		t.Errorf("flat = uplift %v total %v, want 0/25.00", flat.GradeUpliftPct, flat.Total)
	}
}

// TestRecomputeActualFare_Fallbacks pins the "never fabricate a recompute"
// contract: no booked card or either actual NULL yields the (nil, nil) signal
// the caller turns into "charge the booked quote unchanged".
func TestRecomputeActualFare_Fallbacks(t *testing.T) {
	fares := newFakeFareRepo()
	cardID := fares.rates["cr-sj|sedan"].ID
	svc := NewFareService(nil, nil, fares, testFareConfig())

	noRate := actualRide(cardID, 10000, 600, 1.0)
	noRate.FareRateID = nil

	noDistance := actualRide(cardID, 10000, 600, 1.0)
	noDistance.ActualDistanceM = nil

	noDuration := actualRide(cardID, 10000, 600, 1.0)
	noDuration.ActualDurationS = nil

	cases := map[string]*model.Ride{
		"nil ride":           nil,
		"no booked card":     noRate,
		"no actual distance": noDistance,
		"no actual time":     noDuration,
	}
	for name, ride := range cases {
		t.Run(name, func(t *testing.T) {
			est, err := svc.RecomputeActualFare(ride)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if est != nil {
				t.Fatalf("est = %+v, want the nil fallback", est)
			}
		})
	}
}

// TestRecomputeActualFare_MissingCardErrors: a booked card that cannot be
// loaded is an error (so the caller logs and falls back), never a silent
// recompute against nothing.
func TestRecomputeActualFare_MissingCardErrors(t *testing.T) {
	fares := newFakeFareRepo()
	svc := NewFareService(nil, nil, fares, testFareConfig())

	est, err := svc.RecomputeActualFare(actualRide("no-such-card", 10000, 600, 1.0))
	if err == nil {
		t.Fatal("expected an error for a missing booked card")
	}
	if est != nil {
		t.Errorf("est = %+v, want nil alongside the error", est)
	}
}

// TestRecomputeActualFare_Deterministic pins the no-re-sampling rule hard: the
// stored ride yields the same cents every time EVEN WHEN the ambient world
// changes between the calls. A surge demand window appears and the nearby-driver
// count changes (zero drivers would re-sample supply to 2.0), so a recompute
// that re-derived conditions at completion would necessarily return a different
// total. The two results must be identical because the BOOKED surge is reused
// verbatim and demand/supply are never consulted.
func TestRecomputeActualFare_Deterministic(t *testing.T) {
	fares := newFakeFareRepo()
	fares.setUplift("cr-sj", "sedan", 0.001377, 0.15)
	cardID := fares.rates["cr-sj|sedan"].ID
	// Ten drivers at first: supply 1.0. It will be flipped to zero (supply 2.0)
	// between the calls.
	geo := fixedRouteGeo(10)
	svc := NewFareService(geo, legacyNav(), fares, testFareConfig())

	ride := actualRide(cardID, 7345.67, 812, 1.3)
	ascent := 233.4
	ride.GradeAscentM = &ascent

	first, err := svc.RecomputeActualFare(ride)
	if err != nil {
		t.Fatalf("first: %v", err)
	}

	// Change the ambient world: an all-day 2.5x surge window appears and the
	// driver count drops to zero. If the recompute re-sampled either, the total
	// would jump.
	fares.windows["cr-sj"] = []model.FareDemandWindow{
		{Name: "surge", DayMask: 127, StartMinute: 0, EndMinute: 1440, Multiplier: 2.5},
	}
	geo.countFunc = func(_, _ float64, _ float64) (int, error) { return 0, nil }

	second, err := svc.RecomputeActualFare(ride)
	if err != nil {
		t.Fatalf("second: %v", err)
	}
	if *first != *second {
		t.Errorf("recompute re-sampled the world:\n first  = %+v\n second = %+v", *first, *second)
	}
	if first.SurgeMultiplier != 1.3 {
		t.Errorf("conditions = %v, want the booked 1.3", first.SurgeMultiplier)
	}
}
