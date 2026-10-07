//go:build integration

package repository

import (
	"testing"
	"time"

	"ride-hailing-api/internal/model"
)

// TestRideFareSnapshotRoundTripIntegration proves the migration-019 audit
// columns survive a REAL SQL round trip. tests/fare_snapshot_test.go uses
// MockRideRepo, which stores the same pointer the service populated, so it
// cannot catch a dropped or defaulted fare_region_id/fare_rate_id/fare_currency
// in the INSERT. Here CreateRide writes through lib/pq into a TEMP `rides`
// table and FindByID's SELECT * reads it back, so a NULL — or a substituted
// default region/currency — fails.
//
// The card is deliberately unlike any default: region `zz-faretest` (not the
// registered default `cr-sj`) and currency `XTS` (not the USD default). The
// fixtures are TEMP tables on a single-connection handle (the trick the other
// integration tests here use), so the real fare/ride tables are never touched.
func TestRideFareSnapshotRoundTripIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_rates") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_regions") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS routing_regions") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })

	mustExec(t, db, `CREATE TEMP TABLE rides (
		id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
		rider_id          UUID          NOT NULL,
		driver_id         UUID,
		status            TEXT          NOT NULL DEFAULT 'pending',
		pickup_lat        DOUBLE PRECISION NOT NULL,
		pickup_lng        DOUBLE PRECISION NOT NULL,
		dropoff_lat       DOUBLE PRECISION NOT NULL,
		dropoff_lng       DOUBLE PRECISION NOT NULL,
		pickup_address    TEXT          NOT NULL DEFAULT '',
		dropoff_address   TEXT          NOT NULL DEFAULT '',
		vehicle_type      TEXT          NOT NULL DEFAULT 'sedan',
		cancellation_fee  DOUBLE PRECISION NOT NULL DEFAULT 0,
		idempotency_key   TEXT          NOT NULL DEFAULT '',
		base_fare         DOUBLE PRECISION NOT NULL DEFAULT 0,
		distance_fare     DOUBLE PRECISION NOT NULL DEFAULT 0,
		time_fare         DOUBLE PRECISION NOT NULL DEFAULT 0,
		surge_multiplier  DOUBLE PRECISION NOT NULL DEFAULT 1.0,
		total_fare        DOUBLE PRECISION NOT NULL DEFAULT 0,
		fare_region_id    TEXT,
		fare_rate_id      UUID,
		fare_currency     TEXT,
		grade_uplift_pct  NUMERIC(6,4),
		grade_ascent_m    DOUBLE PRECISION,
		requested_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
		accepted_at       TIMESTAMPTZ,
		driver_arrived_at TIMESTAMPTZ,
		started_at        TIMESTAMPTZ,
		completed_at      TIMESTAMPTZ,
		cancelled_at      TIMESTAMPTZ,
		created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
		updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
	)`)
	mustExec(t, db, `CREATE TEMP TABLE routing_regions (
		region_id      TEXT PRIMARY KEY,
		default_region BOOLEAN NOT NULL DEFAULT FALSE
	)`)
	mustExec(t, db, `CREATE TEMP TABLE fare_regions (
		region_id  TEXT PRIMARY KEY REFERENCES routing_regions(region_id),
		currency   TEXT NOT NULL DEFAULT 'USD',
		timezone   TEXT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	mustExec(t, db, `CREATE TEMP TABLE fare_rates (
		id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id       TEXT NOT NULL REFERENCES fare_regions(region_id),
		vehicle_type    TEXT NOT NULL,
		currency        TEXT NOT NULL,
		base_fare_cents INTEGER NOT NULL,
		per_km_cents    INTEGER NOT NULL,
		per_min_cents   INTEGER NOT NULL,
		grade_uplift_factor NUMERIC(10,6) NOT NULL DEFAULT 0,
		grade_uplift_cap    NUMERIC(6,4)  NOT NULL DEFAULT 0,
		effective_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
		effective_to    TIMESTAMPTZ,
		created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	mustExec(t, db, `CREATE UNIQUE INDEX uq_fare_rates_active
		ON fare_rates(region_id, vehicle_type) WHERE effective_to IS NULL`)

	const (
		regionID = "zz-faretest"
		currency = "XTS"
		riderID  = "11111111-1111-1111-1111-111111111111"
	)
	mustExec(t, db, `INSERT INTO routing_regions (region_id, default_region) VALUES
		('cr-sj', TRUE), ($1, FALSE)`, regionID)
	mustExec(t, db, `INSERT INTO fare_regions (region_id, currency, timezone) VALUES
		('cr-sj', 'USD', 'America/Costa_Rica'), ($1, $2, 'America/Costa_Rica')`, regionID, currency)
	mustExec(t, db, `INSERT INTO fare_rates
		(region_id, vehicle_type, currency, base_fare_cents, per_km_cents, per_min_cents, effective_from, effective_to)
		VALUES ($1, 'sedan', $2, 4321, 321, 43, now() - interval '1 hour', NULL)`, regionID, currency)

	// Price the ride from the card the real repository returns, so the audit
	// fields are exactly what "priced" it.
	fareRepo := NewFareRepo(db)
	card, err := fareRepo.GetActiveFareRate(regionID, "sedan", time.Now())
	if err != nil {
		t.Fatalf("GetActiveFareRate: %v", err)
	}
	if card.RegionID != regionID || card.Currency != currency || card.ID == "" {
		t.Fatalf("fixture card = %s/%s id=%q, want %s/%s with an id", card.RegionID, card.Currency, card.ID, regionID, currency)
	}

	repo := NewRideRepo(db)
	uplift := 0.1135
	ascent := 412.0
	ride := &model.Ride{
		RiderID: riderID, Status: "pending", VehicleType: "sedan",
		PickupLat: 9.93, PickupLng: -84.08, DropoffLat: 9.95, DropoffLng: -84.05,
		BaseFare: 43.21, DistanceFare: 1.23, TimeFare: 0.43,
		SurgeMultiplier: 1.0, TotalFare: 44.87,
		FareRegionID:   &card.RegionID,
		FareRateID:     &card.ID,
		FareCurrency:   &card.Currency,
		GradeUpliftPct: &uplift,
		GradeAscentM:   &ascent,
	}
	if err := repo.CreateRide(ride); err != nil {
		t.Fatalf("CreateRide: %v", err)
	}

	got, err := repo.FindByID(ride.ID)
	if err != nil {
		t.Fatalf("FindByID: %v", err)
	}

	if got.FareRegionID == nil {
		t.Fatal("fare_region_id came back NULL; the INSERT dropped it")
	}
	if got.FareRateID == nil {
		t.Fatal("fare_rate_id came back NULL; the INSERT dropped it")
	}
	if got.FareCurrency == nil {
		t.Fatal("fare_currency came back NULL; the INSERT dropped it")
	}
	if *got.FareRegionID != card.RegionID {
		t.Errorf("fare_region_id = %q, want the pricing card's %q", *got.FareRegionID, card.RegionID)
	}
	if *got.FareRateID != card.ID {
		t.Errorf("fare_rate_id = %q, want the pricing card's %q", *got.FareRateID, card.ID)
	}
	if *got.FareCurrency != card.Currency {
		t.Errorf("fare_currency = %q, want the pricing card's %q", *got.FareCurrency, card.Currency)
	}
	if got.GradeUpliftPct == nil || *got.GradeUpliftPct != uplift {
		t.Errorf("grade_uplift_pct = %v, want %v", got.GradeUpliftPct, uplift)
	}
	if got.GradeAscentM == nil || *got.GradeAscentM != ascent {
		t.Errorf("grade_ascent_m = %v, want %v", got.GradeAscentM, ascent)
	}

	// Distinguishable-from-default guards: NULL already fails above, but a bug
	// that substituted the default region or currency must fail too.
	if *got.FareRegionID == "cr-sj" {
		t.Error("fare_region_id fell back to the default region instead of the card's region")
	}
	if *got.FareCurrency == "USD" {
		t.Error("fare_currency fell back to the default USD instead of the card's currency")
	}
}
