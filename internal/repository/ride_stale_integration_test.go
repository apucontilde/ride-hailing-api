//go:build integration

package repository

import (
	"errors"
	"testing"
	"time"

	"github.com/jmoiron/sqlx"
)

// These tests exercise the REAL SQL of the pending-ride lifecycle
// (api_plans/[rides]_orphaned_pending_expiry.md) against a TEMP `rides` table,
// so the age guard, the database-clock cutoff, and the CAS are proven by
// Postgres rather than by a mock. `go test ./...` does not build this file.
func newStaleRideTestDB(t *testing.T) *sqlx.DB {
	t.Helper()
	db := connectPG(t)
	db.SetMaxOpenConns(1) // TEMP tables must stay visible to every repo query
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })
	createRidesTable(t, db, ridesFull)
	return db
}

// insertRide inserts a minimal ridesFull row with an explicit id, rider, status
// and created_at age (computed by the DATABASE clock, matching the queries).
func insertRide(t *testing.T, db *sqlx.DB, id, riderID, status string, age string) {
	t.Helper()
	mustExec(t, db, `
		INSERT INTO rides (id, rider_id, status, pickup_lat, pickup_lng,
			dropoff_lat, dropoff_lng, created_at, updated_at)
		VALUES ($1, $2, $3, 9.93, -84.08, 9.94, -84.07,
			NOW() - $4::interval, NOW() - $4::interval)`,
		id, riderID, status, age)
}

func TestFindCurrentRideByRiderExcludesStalePending(t *testing.T) {
	db := newStaleRideTestDB(t)
	repo := NewRideRepo(db, WithPendingStaleAfter(10*time.Minute))

	const (
		riderStale   = "11111111-1111-1111-1111-111111111111"
		riderFresh   = "22222222-2222-2222-2222-222222222222"
		riderLong    = "33333333-3333-3333-3333-333333333333"
		rideStale    = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		rideFresh    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rideAccepted = "cccccccc-cccc-cccc-cccc-cccccccccccc"
	)
	insertRide(t, db, rideStale, riderStale, "pending", "11 minutes")
	insertRide(t, db, rideFresh, riderFresh, "pending", "0 seconds")
	insertRide(t, db, rideAccepted, riderLong, "accepted", "2 hours")

	// Stale pending is indistinguishable from "no ride" (D4).
	if _, err := repo.FindCurrentRideByRider(riderStale); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stale pending error = %v, want ErrNotFound", err)
	}

	ride, err := repo.FindCurrentRideByRider(riderFresh)
	if err != nil {
		t.Fatalf("fresh pending: %v", err)
	}
	if ride.ID != rideFresh || ride.Status != "pending" {
		t.Errorf("fresh pending = %s/%s, want %s/pending", ride.ID, ride.Status, rideFresh)
	}

	// Only pending is age-filtered: a two-hour-old accepted ride is legitimate.
	ride, err = repo.FindCurrentRideByRider(riderLong)
	if err != nil {
		t.Fatalf("long accepted ride: %v", err)
	}
	if ride.ID != rideAccepted || ride.Status != "accepted" {
		t.Errorf("accepted ride = %s/%s, want %s/accepted", ride.ID, ride.Status, rideAccepted)
	}
}

func TestFindStalePendingRideIDsBoundary(t *testing.T) {
	db := newStaleRideTestDB(t)
	repo := NewRideRepo(db, WithPendingStaleAfter(10*time.Minute))

	const (
		rider = "44444444-4444-4444-4444-444444444444"
		fresh = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		stale = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
		acc   = "ffffffff-ffff-ffff-ffff-ffffffffffff"
		canc  = "99999999-9999-9999-9999-999999999999"
	)
	insertRide(t, db, fresh, rider, "pending", "9 minutes")
	insertRide(t, db, stale, rider, "pending", "11 minutes")
	insertRide(t, db, acc, rider, "accepted", "1 hour")
	insertRide(t, db, canc, rider, "cancelled", "1 hour")

	ids, err := repo.FindStalePendingRideIDs()
	if err != nil {
		t.Fatalf("FindStalePendingRideIDs: %v", err)
	}
	if len(ids) != 1 || ids[0] != stale {
		t.Fatalf("stale ids = %v, want exactly [%s]", ids, stale)
	}
	for _, id := range ids {
		if id == fresh {
			t.Errorf("fresh pending id %s was reported stale", fresh)
		}
	}
}

func TestPendingSweepCASDoesNotClobberAccepted(t *testing.T) {
	db := newStaleRideTestDB(t)
	repo := NewRideRepo(db, WithPendingStaleAfter(10*time.Minute))

	const (
		rider = "55555555-5555-5555-5555-555555555555"
		ride  = "12121212-1212-1212-1212-121212121212"
	)
	insertRide(t, db, ride, rider, "pending", "1 hour")

	// An accept wins between the sweep's read and its write.
	ok, err := repo.UpdateRideStatusFrom(ride, []string{"pending"}, "accepted", nil)
	if err != nil || !ok {
		t.Fatalf("accept CAS = (%v, %v), want (true, nil)", ok, err)
	}

	ok, err = repo.UpdateRideStatusFrom(ride, []string{"pending"}, "no_driver_available", nil)
	if err != nil {
		t.Fatalf("sweep CAS error = %v, want nil", err)
	}
	if ok {
		t.Fatal("sweep CAS reported updated=true for an accepted ride")
	}

	var status string
	var acceptedAt, cancelledAt *time.Time
	if err := db.QueryRow(`
		SELECT status, accepted_at, cancelled_at FROM rides WHERE id = $1`, ride).
		Scan(&status, &acceptedAt, &cancelledAt); err != nil {
		t.Fatalf("reload ride: %v", err)
	}
	if status != "accepted" {
		t.Errorf("status = %q, want accepted", status)
	}
	if acceptedAt == nil {
		t.Error("accepted_at was cleared by the lost sweep CAS")
	}
	if cancelledAt != nil {
		t.Errorf("cancelled_at = %v, want nil", cancelledAt)
	}
}

func TestBootReconcileQueryReturnsAllPending(t *testing.T) {
	db := newStaleRideTestDB(t)
	repo := NewRideRepo(db, WithPendingStaleAfter(10*time.Minute))

	const (
		rider = "66666666-6666-6666-6666-666666666666"
		old   = "13131313-1313-1313-1313-131313131313"
		young = "14141414-1414-1414-1414-141414141414"
		acc   = "15151515-1515-1515-1515-151515151515"
	)
	insertRide(t, db, old, rider, "pending", "2 hours")
	insertRide(t, db, young, rider, "pending", "0 seconds")
	insertRide(t, db, acc, rider, "accepted", "1 hour")

	ids, err := repo.FindPendingRideIDs()
	if err != nil {
		t.Fatalf("FindPendingRideIDs: %v", err)
	}
	got := map[string]bool{}
	for _, id := range ids {
		got[id] = true
	}
	if len(ids) != 2 || !got[old] || !got[young] {
		t.Fatalf("pending ids = %v, want [%s %s]", ids, old, young)
	}
	if got[acc] {
		t.Errorf("accepted ride %s was listed as pending", acc)
	}
}
