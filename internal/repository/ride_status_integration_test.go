//go:build integration

package repository

import (
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

	if err := NewRideRepo(db).UpdateRideStatus(rideID, "no_driver_available", nil); err != nil {
		t.Fatalf("UpdateRideStatus(no_driver_available) against real Postgres: %v", err)
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
