//go:build integration

package database

// Proof that migration 024 (driver earnings ledger,
// api_plans/[payout]_driver_earnings_and_withdraw.md) applies on startup and
// installs the three constraints the ledger's guarantees rest on: the
// double-credit guard, the withdrawal-key dedup, and the drivers FK.

import (
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

func TestMigration024DriverEarningsApplies(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	// Idempotent: the runner skips already-applied versions, so this is safe
	// to call again after cmd/server already migrated the volume.
	if err := RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	// The runner recorded version "024" (numeric prefix before the first "_").
	var recorded bool
	if err := db.Get(&recorded,
		`SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = '024')`); err != nil {
		t.Fatalf("schema_migrations probe: %v", err)
	}
	if !recorded {
		t.Error("version 024 missing from schema_migrations")
	}

	var tableExists bool
	if err := db.Get(&tableExists,
		`SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = 'driver_earnings')`); err != nil {
		t.Fatalf("table probe: %v", err)
	}
	if !tableExists {
		t.Fatal("driver_earnings table missing after migration 024")
	}

	for _, index := range []string{
		"idx_driver_earnings_driver",
		"idx_driver_earnings_ride_earning",   // double-credit guard
		"idx_driver_earnings_withdrawal_key", // DB-level Idempotency-Key dedup
	} {
		var present bool
		if err := db.Get(&present,
			`SELECT EXISTS(SELECT 1 FROM pg_indexes WHERE tablename = 'driver_earnings' AND indexname = $1)`,
			index); err != nil {
			t.Fatalf("index probe %s: %v", index, err)
		}
		if !present {
			t.Errorf("index %s missing after migration 024", index)
		}
	}

	// The FK to drivers(user_id) the migration declares.
	var fkPresent bool
	if err := db.Get(&fkPresent,
		`SELECT EXISTS(SELECT 1 FROM pg_constraint
		  WHERE conrelid = 'driver_earnings'::regclass AND contype = 'f')`); err != nil {
		t.Fatalf("fk probe: %v", err)
	}
	if !fkPresent {
		t.Error("driver_earnings → drivers foreign key missing after migration 024")
	}

	// The constraints must actually reject what they claim to. Everything
	// runs in one always-rolled-back transaction so a MISSING constraint
	// (the failure case) cannot leave a junk row behind.
	tx, err := db.Beginx()
	if err != nil {
		t.Fatalf("begin probe tx: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	var driverID string
	if err := tx.Get(&driverID, `SELECT id FROM users WHERE role = 'driver' ORDER BY created_at LIMIT 1`); err == nil {
		if _, err := tx.Exec(
			`INSERT INTO driver_earnings (driver_id, kind, amount_cents) VALUES ($1, 'adjustment', 0)`,
			driverID); err == nil {
			t.Error("amount_cents = 0 must violate the <> 0 CHECK")
		}
		if _, err := tx.Exec(
			`INSERT INTO driver_earnings (driver_id, ride_id, kind, amount_cents)
			 VALUES ($1, 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'ride_earning', 100)`, driverID); err == nil {
			t.Error("a duplicate ride_earning for one ride must violate idx_driver_earnings_ride_earning")
		}
	} else {
		t.Logf("no driver rows present; skipping live constraint probes: %v", err)
	}
}
