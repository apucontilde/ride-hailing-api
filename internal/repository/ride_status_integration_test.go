//go:build integration

package repository

import (
	"errors"
	"testing"
	"time"
)

// TestRideRepoUpdateRideStatusNoDriverAvailable is the DB-backed gate for the
// no_driver_available defect: the previous unconditional Sprintf emitted
// `UPDATE rides SET status=$1, =$2, updated_at=NOW() WHERE id=$3`, which
// Postgres rejects, so the terminal dispatch write always failed and the rider
// never got the push.
//
// It runs against a live Postgres (the ride-hailing-db container) using the
// canonical TEMP `rides` fixture on a single-connection handle, so the real
// table is untouched. A mock cannot substitute: it never builds or executes the
// SQL.
func TestRideRepoUpdateRideStatusNoDriverAvailable(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1) // the TEMP table must stay visible to every repo query
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })

	createRidesTable(t, db, ridesFull)

	const rideID = "22222222-2222-2222-2222-222222222222"
	mustExec(t, db, `
		INSERT INTO rides (id, rider_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
			created_at, updated_at)
		VALUES ($1, $2, 'pending', 9.93, -84.08, 9.94, -84.07,
			NOW() - INTERVAL '2 minutes', NOW() - INTERVAL '1 minute')`,
		rideID, "33333333-3333-3333-3333-333333333333")

	var before struct {
		Status    string    `db:"status"`
		UpdatedAt time.Time `db:"updated_at"`
	}
	if err := db.Get(&before, `SELECT status, updated_at FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read inserted ride: %v", err)
	}
	if before.Status != "pending" {
		t.Fatalf("inserted status = %q, want pending", before.Status)
	}

	if ok, err := NewRideRepo(db).UpdateRideStatusFrom(rideID, []string{"pending"}, "no_driver_available", nil); err != nil {
		t.Fatalf("UpdateRideStatusFrom(no_driver_available) against real Postgres: %v", err)
	} else if !ok {
		t.Fatal("UpdateRideStatusFrom(no_driver_available) reported no row updated")
	}

	var after struct {
		Status    string    `db:"status"`
		UpdatedAt time.Time `db:"updated_at"`
	}
	if err := db.Get(&after, `SELECT status, updated_at FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read updated ride: %v", err)
	}
	if after.Status != "no_driver_available" {
		t.Errorf("status = %q, want no_driver_available", after.Status)
	}
	if !after.UpdatedAt.After(before.UpdatedAt) {
		t.Errorf("updated_at did not move: before=%s after=%s", before.UpdatedAt, after.UpdatedAt)
	}
}

// insertPendingRide seeds one pending ride in the TEMP fixture and returns its
// id.
func insertPendingRide(t *testing.T, rideID string) *RideRepo {
	t.Helper()
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })
	createRidesTable(t, db, ridesFull)
	mustExec(t, db, `
		INSERT INTO rides (id, rider_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
			created_at, updated_at)
		VALUES ($1, $2, 'pending', 9.93, -84.08, 9.94, -84.07, NOW(), NOW())`,
		rideID, "33333333-3333-3333-3333-333333333333")
	return NewRideRepo(db)
}

// TestRideRepoUpdateRideStatusFromRejectsStaleExpectedStatus is the CAS gate: a
// transition whose expected status no longer matches affects ZERO rows, returns
// (false, nil) and leaves the row untouched.
func TestRideRepoUpdateRideStatusFromRejectsStaleExpectedStatus(t *testing.T) {
	const rideID = "44444444-4444-4444-4444-444444444444"
	repo := insertPendingRide(t, rideID)

	if ok, err := repo.UpdateRideStatusFrom(rideID, []string{"pending"}, "accepted", nil); err != nil || !ok {
		t.Fatalf("pending -> accepted = (%v, %v), want (true, nil)", ok, err)
	}
	ok, err := repo.UpdateRideStatusFrom(rideID, []string{"pending"}, "cancelled", nil)
	if err != nil {
		t.Fatalf("stale transition returned a real error: %v", err)
	}
	if ok {
		t.Fatal("stale expected status must affect 0 rows and report updated=false")
	}

	var row struct {
		Status      string     `db:"status"`
		CancelledAt *time.Time `db:"cancelled_at"`
	}
	db := repo.db
	if err := db.Get(&row, `SELECT status, cancelled_at FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if row.Status != "accepted" {
		t.Errorf("status = %q, want accepted (the stale write must not land)", row.Status)
	}
	if row.CancelledAt != nil {
		t.Errorf("cancelled_at = %v, want NULL", row.CancelledAt)
	}
}

// TestRideRepoUpdateRideStatusFromCancelFromAccepted proves the cancel set can
// move an accepted ride to cancelled against real Postgres (accept-then-cancel
// ordering) and sets cancelled_at.
func TestRideRepoUpdateRideStatusFromCancelFromAccepted(t *testing.T) {
	const rideID = "55555555-5555-5555-5555-555555555555"
	repo := insertPendingRide(t, rideID)

	if err := repo.AssignDriver(rideID, "66666666-6666-6666-6666-666666666666"); err != nil {
		t.Fatalf("AssignDriver: %v", err)
	}
	ok, err := repo.UpdateRideStatusFrom(rideID, []string{"pending", "accepted", "driver_arrived"}, "cancelled", nil)
	if err != nil || !ok {
		t.Fatalf("accepted -> cancelled = (%v, %v), want (true, nil)", ok, err)
	}

	var row struct {
		Status      string     `db:"status"`
		CancelledAt *time.Time `db:"cancelled_at"`
	}
	db := repo.db
	if err := db.Get(&row, `SELECT status, cancelled_at FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if row.Status != "cancelled" {
		t.Errorf("status = %q, want cancelled", row.Status)
	}
	if row.CancelledAt == nil {
		t.Error("cancelled_at is NULL after a committed cancel")
	}
}

// TestRideRepoAssignDriverAfterCancelConflicts pins the second half of the
// race fix: once a cancel commits, AssignDriver (WHERE status='pending') affects
// zero rows and reports repository.ErrConflict, so no assignment can survive a
// cancel.
func TestRideRepoAssignDriverAfterCancelConflicts(t *testing.T) {
	const rideID = "77777777-7777-7777-7777-777777777777"
	repo := insertPendingRide(t, rideID)

	if ok, err := repo.UpdateRideStatusFrom(rideID, []string{"pending"}, "cancelled", nil); err != nil || !ok {
		t.Fatalf("pending -> cancelled = (%v, %v), want (true, nil)", ok, err)
	}
	err := repo.AssignDriver(rideID, "88888888-8888-8888-8888-888888888888")
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("AssignDriver after cancel = %v, want a wrapped ErrConflict", err)
	}

	var row struct {
		Status   string  `db:"status"`
		DriverID *string `db:"driver_id"`
	}
	db := repo.db
	if err := db.Get(&row, `SELECT status, driver_id FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if row.Status != "cancelled" || row.DriverID != nil {
		t.Errorf("row = status %q driver %v, want cancelled with no driver", row.Status, row.DriverID)
	}
}
