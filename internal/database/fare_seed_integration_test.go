//go:build integration

package database

import (
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

// TestSeedFaresRegionIntegration proves the bootstrap tool is idempotent and
// append-only against a live DB, using TEMP fixtures so the real fare tables are
// never touched. It uses a single-connection handle so the session sees its own
// temp tables.
func TestSeedFaresRegionIntegration(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_rates") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_regions") })

	mustExecDB(t, db, `CREATE TEMP TABLE fare_regions (
		region_id  TEXT PRIMARY KEY,
		currency   TEXT NOT NULL DEFAULT 'USD',
		timezone   TEXT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	mustExecDB(t, db, `CREATE TEMP TABLE fare_rates (
		id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id       TEXT NOT NULL,
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
	mustExecDB(t, db, `CREATE UNIQUE INDEX uq_fare_rates_active
		ON fare_rates(region_id, vehicle_type) WHERE effective_to IS NULL`)

	activeCount := func() int {
		var n int
		if err := db.Get(&n, `SELECT count(*) FROM fare_rates WHERE effective_to IS NULL`); err != nil {
			t.Fatalf("count active: %v", err)
		}
		return n
	}

	if err := SeedFaresRegion(db, "cr-sj", "USD", "America/Costa_Rica"); err != nil {
		t.Fatalf("first seed: %v", err)
	}
	if got := activeCount(); got != 3 {
		t.Fatalf("active cards after first seed = %d, want 3", got)
	}

	// The derived per-km rates must reproduce the legacy card (fuel + margin).
	for _, tc := range []struct {
		vehicleType string
		wantKm      int
	}{{"sedan", 150}, {"suv", 200}, {"luxury", 300}} {
		var km int
		if err := db.Get(&km, `SELECT per_km_cents FROM fare_rates
			WHERE region_id='cr-sj' AND vehicle_type=$1 AND effective_to IS NULL`, tc.vehicleType); err != nil {
			t.Fatalf("read %s: %v", tc.vehicleType, err)
		}
		if km != tc.wantKm {
			t.Errorf("%s per_km_cents = %d, want the legacy %d", tc.vehicleType, km, tc.wantKm)
		}
	}

	// The migration-020 uplift knobs are authored per class: a nonzero derived
	// factor and the shared cap. A migrated card must not stay at the 0 default.
	for _, tc := range []struct {
		vehicleType string
		wantFactor  float64
	}{{"sedan", 0.001377}, {"suv", 0.001446}, {"luxury", 0.000872}} {
		var factor, cap float64
		if err := db.QueryRow(`SELECT grade_uplift_factor::float8, grade_uplift_cap::float8
			FROM fare_rates WHERE region_id='cr-sj' AND vehicle_type=$1 AND effective_to IS NULL`,
			tc.vehicleType).Scan(&factor, &cap); err != nil {
			t.Fatalf("read uplift knobs %s: %v", tc.vehicleType, err)
		}
		if factor != tc.wantFactor {
			t.Errorf("%s grade_uplift_factor = %v, want the derived %v", tc.vehicleType, factor, tc.wantFactor)
		}
		if cap != 0.15 {
			t.Errorf("%s grade_uplift_cap = %v, want 0.15", tc.vehicleType, cap)
		}
	}

	// Idempotent: a second run over an unchanged card is a no-op.
	if err := SeedFaresRegion(db, "cr-sj", "USD", "America/Costa_Rica"); err != nil {
		t.Fatalf("second seed: %v", err)
	}
	if got := activeCount(); got != 3 {
		t.Fatalf("active cards after idempotent re-run = %d, want 3", got)
	}
	var total int
	if err := db.Get(&total, `SELECT count(*) FROM fare_rates`); err != nil {
		t.Fatalf("count total: %v", err)
	}
	if total != 3 {
		t.Fatalf("total rate rows = %d, want 3 (no churn)", total)
	}

	// A card that DIFFERS is versioned: the old active row is closed and a new
	// active row is appended; history is never rewritten in place.
	mustExecDB(t, db, `UPDATE fare_rates SET per_km_cents = 999
		WHERE region_id='cr-sj' AND vehicle_type='sedan' AND effective_to IS NULL`)
	if err := SeedFaresRegion(db, "cr-sj", "USD", "America/Costa_Rica"); err != nil {
		t.Fatalf("versioning seed: %v", err)
	}
	if got := activeCount(); got != 3 {
		t.Fatalf("active cards after versioning = %d, want 3 (one active per class)", got)
	}
	if err := db.Get(&total, `SELECT count(*) FROM fare_rates WHERE vehicle_type='sedan'`); err != nil {
		t.Fatalf("count sedan: %v", err)
	}
	if total != 2 {
		t.Fatalf("sedan rows = %d, want 2 (one closed, one active)", total)
	}
	var closed, activeKm int
	if err := db.Get(&closed, `SELECT count(*) FROM fare_rates
		WHERE vehicle_type='sedan' AND effective_to IS NOT NULL`); err != nil {
		t.Fatalf("count closed sedan: %v", err)
	}
	if err := db.Get(&activeKm, `SELECT per_km_cents FROM fare_rates
		WHERE vehicle_type='sedan' AND effective_to IS NULL`); err != nil {
		t.Fatalf("read active sedan: %v", err)
	}
	if closed != 1 || activeKm != 150 {
		t.Errorf("versioning = %d closed / active km %d, want 1 closed / 150", closed, activeKm)
	}

	// The timezone is explicit and validated.
	if err := SeedFaresRegion(db, "cr-sj", "USD", "Not/AZone"); err == nil {
		t.Error("an invalid timezone must be rejected")
	}
	if err := SeedFaresRegion(db, "cr-sj", "USD", ""); err == nil {
		t.Error("a missing timezone must be rejected, never guessed")
	}
}

func mustExecDB(t *testing.T, db *sqlx.DB, q string, args ...any) {
	t.Helper()
	if _, err := db.Exec(q, args...); err != nil {
		t.Fatalf("exec error: %v (query: %s)", err, q)
	}
}
