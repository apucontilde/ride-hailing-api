//go:build integration

package repository

import (
	"errors"
	"testing"
	"time"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"

	"ride-hailing-api/internal/config"
)

// TouchDriverPresence re-arms a driver's dispatch presence from their LAST
// KNOWN position, so the age of that position is load-bearing: a fix from hours
// ago is not "where the driver is", and re-arming it hands a rider a wrong ETA
// and sends a driver who is somewhere else to the pickup. These tests are the
// DB-backed proof of the bound, because the mock-backed unit suite cannot see a
// WHERE clause.
//
// Self-contained on purpose (its own connection and fixture helpers) so it does
// not depend on any other test file's fixtures.

func presenceAgeDB(t *testing.T) *sqlx.DB {
	t.Helper()
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// seedAgedPosition writes a driver whose position row is `age` old and currently
// offline, so a successful touch is visible in both status and updated_at. The
// uuid/phone derive from the name so a re-run reuses the same rows.
func seedAgedPosition(t *testing.T, db *sqlx.DB, name string, age time.Duration) string {
	t.Helper()
	var id, phone string
	if err := db.Get(&id,
		`SELECT ('00000000-0000-0000-0000-' || substr(md5($1), 1, 12))::uuid`, name); err != nil {
		t.Fatalf("derive id for %s: %v", name, err)
	}
	if err := db.Get(&phone, `SELECT '+5061' || substr(md5($1), 13, 8)`, name); err != nil {
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
		id, name+"@presence-age.test", phone); err != nil {
		t.Fatalf("seed user %s: %v", name, err)
	}
	if _, err := db.Exec(
		`INSERT INTO drivers (user_id, first_name, last_name, status, onboarding_status)
		 VALUES ($1, 'Presence', 'Probe', 'offline', 'approved')
		 ON CONFLICT (user_id) DO NOTHING`, id); err != nil {
		t.Fatalf("seed driver %s: %v", name, err)
	}
	if _, err := db.Exec(
		`INSERT INTO driver_positions (driver_id, location, heading, speed, status, updated_at)
		 VALUES ($1, ST_SetSRID(ST_MakePoint(-84.08, 9.93), 4326)::GEOGRAPHY, 0, 0, 'offline', NOW() - $2::interval)
		 ON CONFLICT (driver_id) DO UPDATE
		   SET updated_at = NOW() - $2::interval, status = 'offline'`,
		id, age.String()); err != nil {
		t.Fatalf("seed position %s: %v", name, err)
	}
	return id
}

func readPosition(t *testing.T, db *sqlx.DB, id string) (status string, age time.Duration) {
	t.Helper()
	if err := db.Get(&status, `SELECT status FROM driver_positions WHERE driver_id = $1`, id); err != nil {
		t.Fatalf("read status for %s: %v", id, err)
	}
	var secs float64
	if err := db.Get(&secs,
		`SELECT EXTRACT(EPOCH FROM (NOW() - updated_at)) FROM driver_positions WHERE driver_id = $1`, id); err != nil {
		t.Fatalf("read age for %s: %v", id, err)
	}
	return status, time.Duration(secs * float64(time.Second))
}

// TestTouchDriverPresenceRefusesAnAncientFix is THE regression test for the age
// bound. A driver who opens the app far from home and taps online before the
// first GPS fix used to re-arm the 30 s liveness window at their old
// coordinates, and FindNearbyDrivers then offered that stale position.
func TestTouchDriverPresenceRefusesAnAncientFix(t *testing.T) {
	db := presenceAgeDB(t)
	geo := NewGeoRepo(db)

	ancient := seedAgedPosition(t, db, "presence-ancient-probe", time.Duration(DriverPresenceMaxAgeS)*time.Second+time.Hour)
	beforeStatus, beforeAge := readPosition(t, db, ancient)

	err := geo.TouchDriverPresence(ancient, "online")
	if err == nil {
		t.Fatal("TouchDriverPresence must not re-arm a fix older than DriverPresenceMaxAgeS")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want it to wrap ErrNotFound (the handler keys off it)", err)
	}

	afterStatus, afterAge := readPosition(t, db, ancient)
	if afterStatus != beforeStatus {
		t.Errorf("status = %q, want %q: a refused touch must not write anything", afterStatus, beforeStatus)
	}
	if after := afterAge - beforeAge; after > 5*time.Second {
		t.Errorf("updated_at moved by %s, want it untouched (age was %s, now %s)", after, beforeAge, afterAge)
	}
	// And the driver must not have become dispatch-eligible.
	drivers, err := geo.FindNearbyDrivers(9.93, -84.08, 5000, 10)
	if err != nil {
		t.Fatalf("FindNearbyDrivers: %v", err)
	}
	for _, d := range drivers {
		if d.DriverID == ancient {
			t.Error("a driver with only an ancient fix must not be dispatch-eligible")
		}
	}
}

// A fix younger than the cap still re-arms, and it must be younger than the
// LIVENESS window boundary being crossed — the whole point of the touch. The age
// is chosen just inside the cap so the "one boundary, two answers" pairing with
// the test above is unambiguous.
func TestTouchDriverPresenceReArmsAFreshFix(t *testing.T) {
	db := presenceAgeDB(t)
	geo := NewGeoRepo(db)

	// Older than the liveness window (so it is not dispatch-eligible as it
	// stands) but well inside the presence cap.
	id := seedAgedPosition(t, db, "presence-fresh-probe", DriverLivenessWindow+30*time.Second)

	if err := geo.TouchDriverPresence(id, "online"); err != nil {
		t.Fatalf("TouchDriverPresence on a fix inside the %ds cap: %v", DriverPresenceMaxAgeS, err)
	}

	status, age := readPosition(t, db, id)
	if status != "online" {
		t.Errorf("status = %q, want %q", status, "online")
	}
	if age > 5*time.Second {
		t.Errorf("presence age after the touch = %s, want it re-armed to now", age)
	}
	found := false
	drivers, err := geo.FindNearbyDrivers(9.93, -84.08, 5000, 10)
	if err != nil {
		t.Fatalf("FindNearbyDrivers: %v", err)
	}
	for _, d := range drivers {
		if d.DriverID == id {
			found = true
			// Last known coordinates are reused, never invented or moved.
			if d.Lat != 9.93 || d.Lng != -84.08 {
				t.Errorf("TouchDriverPresence moved the driver: lat=%v lng=%v, want 9.93/-84.08", d.Lat, d.Lng)
			}
		}
	}
	if !found {
		t.Error("a driver with a fix inside the cap must be dispatch-eligible after the touch")
	}
}
