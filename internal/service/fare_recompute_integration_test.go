//go:build integration

package service

// Real-database proof for the completion recompute's card seam
// (api_plans/01_[fare]_actuals_recompute_on_completion.md, defect 2 of the
// actuals review): a ride is repriced against the card it BOOKED, even when that
// card was closed/superseded after booking. This is the test the comment on
// fakeFareRepo.GetFareRateByID refers to — the fake scans a map, so only the
// real SQL (a primary-key lookup with NO effective-window filter) can prove the
// behavior.
//
// Needs Postgres (`docker compose up -d`). The fare_rates fixture is a TEMP
// table on a dedicated single-connection handle, so the real pricing tables are
// never touched.

import (
	"testing"
	"time"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

func TestRecomputeActualFarePricesViaClosedBookedCardIntegration(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1) // the TEMP fixture must stay visible to every query

	if _, err := db.Exec(`CREATE TEMP TABLE fare_rates (
		id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id           TEXT NOT NULL,
		vehicle_type        TEXT NOT NULL,
		currency            TEXT NOT NULL,
		base_fare_cents     INTEGER NOT NULL,
		per_km_cents        INTEGER NOT NULL,
		per_min_cents       INTEGER NOT NULL,
		grade_uplift_factor NUMERIC(10,6) NOT NULL DEFAULT 0,
		grade_uplift_cap    NUMERIC(6,4)  NOT NULL DEFAULT 0,
		effective_from      TIMESTAMPTZ NOT NULL DEFAULT now(),
		effective_to        TIMESTAMPTZ,
		created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		t.Fatalf("create temp fare_rates: %v", err)
	}

	// The BOOKED card: active when the ride was booked.
	var bookedID string
	if err := db.Get(&bookedID, `INSERT INTO fare_rates
		(region_id, vehicle_type, currency, base_fare_cents, per_km_cents, per_min_cents, effective_from, effective_to)
		VALUES ('cr-sj', 'sedan', 'USD', 500, 150, 50, now() - interval '2 hours', NULL)
		RETURNING id`); err != nil {
		t.Fatalf("insert booked card: %v", err)
	}

	// Supersede it AFTER booking: close it and start a different card.
	if _, err := db.Exec(`UPDATE fare_rates SET effective_to = now() WHERE id = $1`, bookedID); err != nil {
		t.Fatalf("close booked card: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO fare_rates
		(region_id, vehicle_type, currency, base_fare_cents, per_km_cents, per_min_cents, effective_from, effective_to)
		VALUES ('cr-sj', 'sedan', 'USD', 900, 250, 90, now(), NULL)`); err != nil {
		t.Fatalf("insert successor card: %v", err)
	}

	fareRepo := repository.NewFareRepo(db)

	// Sanity: the current active card is the successor, NOT the booked one, so
	// the recompute below cannot accidentally pass by selecting the active card.
	active, err := fareRepo.GetActiveFareRate("cr-sj", "sedan", time.Now())
	if err != nil {
		t.Fatalf("GetActiveFareRate: %v", err)
	}
	if active.ID == bookedID || active.BaseFareCents != 900 {
		t.Fatalf("active card = %s base %d, want the successor 900 (not the closed %s)",
			active.ID, active.BaseFareCents, bookedID)
	}

	svc := NewFareService(nil, nil, fareRepo, testFareConfig())

	distance, duration := 10000.0, 600
	ride := &model.Ride{
		ID:              "ride-closed-card",
		FareRateID:      &bookedID,
		ActualDistanceM: &distance,
		ActualDurationS: &duration,
		SurgeMultiplier: 1.0,
		// A deliberately different "current" quote the recompute must ignore.
		BaseFare: 9, DistanceFare: 25, TimeFare: 9, TotalFare: 43,
	}

	est, err := svc.RecomputeActualFare(ride)
	if err != nil {
		t.Fatalf("RecomputeActualFare: %v", err)
	}
	if est == nil {
		t.Fatal("expected a recompute, got the nil fallback")
	}
	if est.RateID != bookedID {
		t.Errorf("priced against card %q, want the booked %q", est.RateID, bookedID)
	}
	// Booked card 500/150/50 on 10 km / 10 min: 500 + 1500 + 500 = 2500c = $25.
	// The successor (900/250/90) would have produced $43.
	if est.BaseFare != 5.0 || est.DistanceFare != 15.0 || est.TimeFare != 5.0 || est.Total != 25.0 {
		t.Errorf("components = base %v distance %v time %v total %v, want 5/15/5/25 (the booked card)",
			est.BaseFare, est.DistanceFare, est.TimeFare, est.Total)
	}
}
