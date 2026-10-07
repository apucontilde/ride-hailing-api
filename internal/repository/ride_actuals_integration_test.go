//go:build integration

package repository

import (
	"testing"
	"time"
)

// TestRideActualsSQLIntegration exercises the real SQL of migration 021 against
// a live DB: the append-only trace insert/read ordering and the NULL-preserving
// actuals UPDATE. The fixtures are TEMP tables on a single-connection handle
// (the trick the other integration tests here use), so the real tables are
// never touched.
func TestRideActualsSQLIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS ride_track_points") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })

	mustExec(t, db, `CREATE TEMP TABLE rides (
		id                UUID PRIMARY KEY,
		actual_duration_s INTEGER,
		actual_distance_m DOUBLE PRECISION,
		updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)
	mustExec(t, db, `CREATE TEMP TABLE ride_track_points (
		id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
		ride_id     UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
		lat         DOUBLE PRECISION NOT NULL,
		lng         DOUBLE PRECISION NOT NULL,
		recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)

	repo := NewRideRepo(db)
	rideID := "11111111-1111-1111-1111-111111111111"
	mustExec(t, db, `INSERT INTO rides (id) VALUES ($1)`, rideID)

	// A ride with no fixes yields an empty slice, never nil.
	none, err := repo.FindRideTrackPoints(rideID)
	if err != nil {
		t.Fatalf("FindRideTrackPoints(empty): %v", err)
	}
	if none == nil || len(none) != 0 {
		t.Fatalf("FindRideTrackPoints(empty) = %#v, want empty non-nil", none)
	}

	// Insert out of chronological order to prove the read orders by time.
	base := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	if err := repo.InsertRideTrackPoint(rideID, 9.1, -84.1, base.Add(2*time.Second)); err != nil {
		t.Fatalf("InsertRideTrackPoint(3rd): %v", err)
	}
	if err := repo.InsertRideTrackPoint(rideID, 9.0, -84.0, base); err != nil {
		t.Fatalf("InsertRideTrackPoint(1st): %v", err)
	}
	if err := repo.InsertRideTrackPoint(rideID, 9.05, -84.05, base.Add(time.Second)); err != nil {
		t.Fatalf("InsertRideTrackPoint(2nd): %v", err)
	}

	points, err := repo.FindRideTrackPoints(rideID)
	if err != nil {
		t.Fatalf("FindRideTrackPoints: %v", err)
	}
	if len(points) != 3 {
		t.Fatalf("track points = %d, want 3", len(points))
	}
	if points[0].Lat != 9.0 || points[2].Lat != 9.1 {
		t.Fatalf("points not ordered by recorded_at: %#v", points)
	}

	// SetRideActuals persists both values.
	duration := 95
	distance := 1234.5
	if err := repo.SetRideActuals(rideID, &duration, &distance); err != nil {
		t.Fatalf("SetRideActuals: %v", err)
	}
	var stored struct {
		Duration *int     `db:"actual_duration_s"`
		Distance *float64 `db:"actual_distance_m"`
	}
	if err := db.Get(&stored, `SELECT actual_duration_s, actual_distance_m FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read actuals: %v", err)
	}
	if stored.Duration == nil || *stored.Duration != 95 {
		t.Fatalf("actual_duration_s = %v, want 95", stored.Duration)
	}
	if stored.Distance == nil || *stored.Distance != 1234.5 {
		t.Fatalf("actual_distance_m = %v, want 1234.5", stored.Distance)
	}

	// A nil update writes SQL NULL, the honest "no usable actual".
	if err := repo.SetRideActuals(rideID, nil, nil); err != nil {
		t.Fatalf("SetRideActuals(nil): %v", err)
	}
	stored = struct {
		Duration *int     `db:"actual_duration_s"`
		Distance *float64 `db:"actual_distance_m"`
	}{}
	if err := db.Get(&stored, `SELECT actual_duration_s, actual_distance_m FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read null actuals: %v", err)
	}
	if stored.Duration != nil || stored.Distance != nil {
		t.Fatalf("actuals after nil update = (%v,%v), want (nil,nil)", stored.Duration, stored.Distance)
	}
}
