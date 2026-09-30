//go:build integration

package repository

import (
	"errors"
	"testing"
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

// The unit suite backs GeoRepository with testutil.MockGeoRepo, which cannot see
// a malformed SQL parameter. These tests therefore run against the live dev
// database (docker compose up -d) and are the only proof that the liveness
// window actually binds and filters in Postgres.
//
// The liveness window is bound as a float8 through make_interval() rather than
// as a time.Duration: lib/pq converts an unknown Go type via
// driver.DefaultParameterConverter, turning time.Duration into int64, so
// binding DriverLivenessWindow directly would send its raw nanosecond count
// (30000000000). The failure this guards is SILENT, not a rejected cast:
// Postgres accepts that number, reads it as 30,000,000,000 SECONDS, and both
// `NOW() - $1::interval` and `make_interval(secs => $1::double precision)` then
// land centuries in the past without error — so no dead driver ever ages out
// and the sweep never fires. (Verified on the dev DB and recorded in full on
// driverLivenessSeconds, internal/repository/geo_repo.go:41-54; do not
// "simplify" this comment back into claiming Postgres rejects the type.)
// That mis-binding is invisible to every mock test, so it is pinned here.

// integrationDB connects to the dev database, skipping when it is unavailable
// (the integration tag is opt-in; a missing DB must not fail the suite).
func integrationDB(t *testing.T) *sqlx.DB {
	t.Helper()
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// seedDriverPosition creates the users+drivers fixture that
// driver_positions.driver_id depends on (FK to drivers.user_id) and writes a
// position row aged by age. Deleting the user cascades away the position row,
// so cleanup is one statement.
//
// The uuid is derived from the probe name via md5 so a test is re-runnable and
// two probes never collide.
func seedDriverPosition(t *testing.T, db *sqlx.DB, name string, age time.Duration) string {
	t.Helper()
	var id, phone string
	if err := db.Get(&id,
		`SELECT ('00000000-0000-0000-0000-' || substr(md5($1), 1, 12))::uuid`, name); err != nil {
		t.Fatalf("derive id for %s: %v", name, err)
	}
	if err := db.Get(&phone,
		`SELECT '+5060' || substr(md5($1), 13, 8)`, name); err != nil {
		t.Fatalf("derive phone for %s: %v", name, err)
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`DELETE FROM users WHERE id = $1`, id); err != nil {
			t.Logf("post-clean %s: %v", name, err)
		}
	})

	if _, err := db.Exec(
		`INSERT INTO users (id, email, phone, password_hash, role)
		 VALUES ($1, $2, $3, 'not-a-real-hash', 'driver')
		 ON CONFLICT (id) DO NOTHING`,
		id, name+"@liveness.test", phone); err != nil {
		t.Fatalf("seed user %s: %v", name, err)
	}
	if _, err := db.Exec(
		`INSERT INTO drivers (user_id, first_name, last_name, status, onboarding_status)
		 VALUES ($1, 'Liveness', 'Probe', 'online', 'approved')
		 ON CONFLICT (user_id) DO UPDATE SET status = 'online'`, id); err != nil {
		t.Fatalf("seed driver %s: %v", name, err)
	}
	if _, err := db.Exec(
		`INSERT INTO driver_positions (driver_id, location, heading, speed, status, updated_at)
		 VALUES ($1, ST_SetSRID(ST_MakePoint(-84.08, 9.93), 4326)::GEOGRAPHY, 0, 0, 'online', NOW() - $2::interval)
		 ON CONFLICT (driver_id) DO UPDATE SET updated_at = NOW() - $2::interval, status = 'online'`,
		id, age.String()); err != nil {
		t.Fatalf("seed position %s: %v", name, err)
	}
	return id
}

// seedOrphanDriver creates a driver fixture with NO position row, so the
// "online but never sent a fix" case can be exercised.
func seedOrphanDriver(t *testing.T, db *sqlx.DB, name string) string {
	t.Helper()
	var id, phone string
	if err := db.Get(&id,
		`SELECT ('00000000-0000-0000-0000-' || substr(md5($1), 1, 12))::uuid`, name); err != nil {
		t.Fatalf("derive id for %s: %v", name, err)
	}
	if err := db.Get(&phone,
		`SELECT '+5060' || substr(md5($1), 13, 8)`, name); err != nil {
		t.Fatalf("derive phone for %s: %v", name, err)
	}
	t.Cleanup(func() {
		if _, err := db.Exec(`DELETE FROM users WHERE id = $1`, id); err != nil {
			t.Logf("post-clean %s: %v", name, err)
		}
	})
	if _, err := db.Exec(
		`INSERT INTO users (id, email, phone, password_hash, role)
		 VALUES ($1, $2, $3, 'not-a-real-hash', 'driver')
		 ON CONFLICT (id) DO NOTHING`,
		id, name+"@liveness.test", phone); err != nil {
		t.Fatalf("seed user %s: %v", name, err)
	}
	if _, err := db.Exec(
		`INSERT INTO drivers (user_id, first_name, last_name, status, onboarding_status)
		 VALUES ($1, 'Liveness', 'Probe', 'online', 'approved')
		 ON CONFLICT (user_id) DO UPDATE SET status = 'online'`, id); err != nil {
		t.Fatalf("seed driver %s: %v", name, err)
	}
	if _, err := db.Exec(`DELETE FROM driver_positions WHERE driver_id = $1`, id); err != nil {
		t.Fatalf("ensure orphan %s: %v", name, err)
	}
	return id
}

// TestLivenessWindowBindsInPostgres is the regression test for the interval
// BINDING. A mis-bound window raises no error, so the only evidence is
// behaviour: every liveness-filtered query must run, and a row older than the
// window must be excluded while a fresh one is included.
func TestLivenessWindowBindsInPostgres(t *testing.T) {
	db := integrationDB(t)
	geo := NewGeoRepo(db)

	fresh := seedDriverPosition(t, db, "liveness-fresh-probe", time.Second)
	stale := seedDriverPosition(t, db, "liveness-stale-probe", DriverLivenessWindow+time.Minute)

	drivers, err := geo.FindNearbyDrivers(9.93, -84.08, 5000, 10)
	if err != nil {
		t.Fatalf("FindNearbyDrivers must bind the liveness interval: %v", err)
	}
	seen := map[string]bool{}
	for _, d := range drivers {
		seen[d.DriverID] = true
	}
	if !seen[fresh] {
		t.Errorf("a driver inside the %s window must be dispatch-eligible; got %v", DriverLivenessWindow, seen)
	}
	if seen[stale] {
		t.Errorf("a driver older than %s must NOT be dispatch-eligible", DriverLivenessWindow)
	}

	count, err := geo.CountNearbyDrivers(9.93, -84.08, 5000)
	if err != nil {
		t.Fatalf("CountNearbyDrivers must bind the liveness interval: %v", err)
	}
	if count < 1 {
		t.Errorf("CountNearbyDrivers = %d, want >= 1 (the fresh probe)", count)
	}
}

// TestMarkStaleDriversOfflineSweepsAndBinds proves the sweeper's own query
// binds, and that it reconciles exactly the stale rows while leaving live ones
// alone. It is the DB-backed half of the sweeper wiring.
func TestMarkStaleDriversOfflineSweepsAndBinds(t *testing.T) {
	db := integrationDB(t)
	geo := NewGeoRepo(db)

	fresh := seedDriverPosition(t, db, "sweep-fresh-probe", time.Second)
	stale := seedDriverPosition(t, db, "sweep-stale-probe", DriverLivenessWindow+time.Minute)

	if err := geo.MarkStaleDriversOffline(); err != nil {
		t.Fatalf("MarkStaleDriversOffline must bind the liveness interval: %v", err)
	}

	var status string
	if err := db.Get(&status, `SELECT status FROM driver_positions WHERE driver_id = $1`, stale); err != nil {
		t.Fatalf("read stale status: %v", err)
	}
	if status != "offline" {
		t.Errorf("stale driver status = %q, want %q", status, "offline")
	}
	if err := db.Get(&status, `SELECT status FROM driver_positions WHERE driver_id = $1`, fresh); err != nil {
		t.Fatalf("read fresh status: %v", err)
	}
	if status != "online" {
		t.Errorf("fresh driver status = %q, want %q (the sweep must not touch live rows)", status, "online")
	}
}

// TestTouchDriverPresenceReArmsWindow is the DB-backed proof of the
// just-online/stationary driver fix: an existing row that has aged past the
// window becomes dispatch-eligible again from its LAST KNOWN coordinates,
// with no new GPS fix involved.
func TestTouchDriverPresenceReArmsWindow(t *testing.T) {
	db := integrationDB(t)
	geo := NewGeoRepo(db)

	id := seedDriverPosition(t, db, "touch-presence-probe", DriverLivenessWindow+time.Minute)

	if err := geo.TouchDriverPresence(id, "online"); err != nil {
		t.Fatalf("TouchDriverPresence on an existing row: %v", err)
	}

	drivers, err := geo.FindNearbyDrivers(9.93, -84.08, 5000, 10)
	if err != nil {
		t.Fatalf("FindNearbyDrivers: %v", err)
	}
	found := false
	for _, d := range drivers {
		if d.DriverID == id {
			found = true
			// Last known coordinates must be preserved, not invented.
			if d.Lat != 9.93 || d.Lng != -84.08 {
				t.Errorf("TouchDriverPresence moved the driver: lat=%v lng=%v, want 9.93/-84.08", d.Lat, d.Lng)
			}
		}
	}
	if !found {
		t.Errorf("a touched driver must be dispatch-eligible again (the just-online/stationary case)")
	}
}

// TestTouchDriverPresenceRecordsOfflineTransition pins the other direction: the
// touch also carries the status, so going offline is reflected in the same
// write.
func TestTouchDriverPresenceRecordsOfflineTransition(t *testing.T) {
	db := integrationDB(t)
	geo := NewGeoRepo(db)

	id := seedDriverPosition(t, db, "touch-offline-probe", time.Second)

	if err := geo.TouchDriverPresence(id, "offline"); err != nil {
		t.Fatalf("TouchDriverPresence: %v", err)
	}
	var status string
	if err := db.Get(&status, `SELECT status FROM driver_positions WHERE driver_id = $1`, id); err != nil {
		t.Fatalf("read status: %v", err)
	}
	if status != "offline" {
		t.Errorf("status = %q, want %q", status, "offline")
	}
	// An offline driver must not be dispatch-eligible.
	drivers, err := geo.FindNearbyDrivers(9.93, -84.08, 5000, 10)
	if err != nil {
		t.Fatalf("FindNearbyDrivers: %v", err)
	}
	for _, d := range drivers {
		if d.DriverID == id {
			t.Errorf("an offline driver must not be dispatch-eligible")
		}
	}
}

// TestTouchDriverPresenceWithoutRowIsNotFound pins the "unlocatable driver"
// case. The UPDATE ... WHERE driver_id = $1 affects zero rows, and the method
// must report that as ErrNotFound rather than a silent success — a silent
// success here is precisely the invisible false negative this plan is closing.
func TestTouchDriverPresenceWithoutRowIsNotFound(t *testing.T) {
	db := integrationDB(t)
	geo := NewGeoRepo(db)

	id := seedOrphanDriver(t, db, "touch-missing-probe")

	err := geo.TouchDriverPresence(id, "online")
	if err == nil {
		t.Fatal("TouchDriverPresence must fail when the driver has no position row")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("error = %v, want it to wrap ErrNotFound (the handler keys off IsNotFound)", err)
	}
	// And it must not have created a row out of thin air.
	var count int
	if err := db.Get(&count, `SELECT COUNT(*) FROM driver_positions WHERE driver_id = $1`, id); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Errorf("TouchDriverPresence invented a position row (%d found); it must never do that", count)
	}
}
