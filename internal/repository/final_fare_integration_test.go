//go:build integration

package repository

import (
	"testing"
)

// TestFinalizeRideFareSQLIntegration exercises migration 022/023's real SQL
// against a live DB: the guarded, single-statement UPDATE must copy the CURRENT
// money columns AND the booked climb uplift into quoted_* and overwrite them
// with the final charge / applied uplift, and a second call must be a no-op that
// reports finalized=false. Fixtures are TEMP tables on a single-connection
// handle (the trick the other integration tests here use), so the real rides
// table is never touched.
func TestFinalizeRideFareSQLIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })

	mustExec(t, db, `CREATE TEMP TABLE rides (
		id                     UUID PRIMARY KEY,
		base_fare              DOUBLE PRECISION NOT NULL DEFAULT 0,
		distance_fare          DOUBLE PRECISION NOT NULL DEFAULT 0,
		time_fare              DOUBLE PRECISION NOT NULL DEFAULT 0,
		surge_multiplier       DOUBLE PRECISION NOT NULL DEFAULT 1.0,
		total_fare             DOUBLE PRECISION NOT NULL DEFAULT 0,
		grade_uplift_pct       NUMERIC(6,4),
		quoted_base_fare       DOUBLE PRECISION,
		quoted_distance_fare   DOUBLE PRECISION,
		quoted_time_fare       DOUBLE PRECISION,
		quoted_surge_multiplier DOUBLE PRECISION,
		quoted_total_fare      DOUBLE PRECISION,
		quoted_grade_uplift_pct NUMERIC(6,4),
		updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)

	repo := NewRideRepo(db)
	rideID := "11111111-1111-1111-1111-111111111111"
	// The booked quote, carrying the booked climb uplift.
	mustExec(t, db, `INSERT INTO rides
		(id, base_fare, distance_fare, time_fare, surge_multiplier, total_fare, grade_uplift_pct)
		VALUES ($1, 5.00, 7.50, 3.78, 1.5, 24.43, 0.1000)`, rideID)

	// First finalization: snapshots the quote (money and uplift), writes the
	// final charge and the uplift actually applied to the final distance leg.
	finalUplift := 0.0567
	finalized, err := repo.FinalizeRideFare(rideID, 5.00, 16.68, 0.0, 32.52, &finalUplift)
	if err != nil {
		t.Fatalf("FinalizeRideFare: %v", err)
	}
	if !finalized {
		t.Fatal("first finalization reported finalized=false")
	}

	var got struct {
		BaseFare          float64  `db:"base_fare"`
		DistanceFare      float64  `db:"distance_fare"`
		TimeFare          float64  `db:"time_fare"`
		TotalFare         float64  `db:"total_fare"`
		GradeUplift       *float64 `db:"grade_uplift_pct"`
		QuotedBase        *float64 `db:"quoted_base_fare"`
		QuotedDistance    *float64 `db:"quoted_distance_fare"`
		QuotedTime        *float64 `db:"quoted_time_fare"`
		QuotedSurge       *float64 `db:"quoted_surge_multiplier"`
		QuotedTotal       *float64 `db:"quoted_total_fare"`
		QuotedGradeUplift *float64 `db:"quoted_grade_uplift_pct"`
	}
	if err := db.Get(&got, `SELECT base_fare, distance_fare, time_fare, total_fare, grade_uplift_pct,
		quoted_base_fare, quoted_distance_fare, quoted_time_fare,
		quoted_surge_multiplier, quoted_total_fare, quoted_grade_uplift_pct
		FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read finalized ride: %v", err)
	}
	if got.BaseFare != 5.00 || got.DistanceFare != 16.68 || got.TimeFare != 0.0 || got.TotalFare != 32.52 {
		t.Errorf("final charge = %v/%v/%v/%v, want 5/16.68/0/32.52",
			got.BaseFare, got.DistanceFare, got.TimeFare, got.TotalFare)
	}
	if got.QuotedTotal == nil || *got.QuotedTotal != 24.43 || got.QuotedBase == nil || *got.QuotedBase != 5.00 ||
		got.QuotedDistance == nil || *got.QuotedDistance != 7.50 || got.QuotedTime == nil || *got.QuotedTime != 3.78 ||
		got.QuotedSurge == nil || *got.QuotedSurge != 1.5 {
		t.Errorf("quote not captured: base %v distance %v time %v surge %v total %v",
			got.QuotedBase, got.QuotedDistance, got.QuotedTime, got.QuotedSurge, got.QuotedTotal)
	}
	// The applied column describes the FINAL distance leg; the booked value is
	// preserved in the quoted audit. This is what makes the receipt reconcile.
	if got.GradeUplift == nil || *got.GradeUplift != finalUplift {
		t.Errorf("applied grade_uplift_pct = %v, want the final %v", got.GradeUplift, finalUplift)
	}
	if got.QuotedGradeUplift == nil || *got.QuotedGradeUplift != 0.1000 {
		t.Errorf("quoted_grade_uplift_pct = %v, want the booked 0.1000", got.QuotedGradeUplift)
	}

	// Second call is a no-op: no re-snapshot, no new charge, no uplift move.
	otherUplift := 0.99
	finalized, err = repo.FinalizeRideFare(rideID, 999.0, 999.0, 999.0, 999.0, &otherUplift)
	if err != nil {
		t.Fatalf("second FinalizeRideFare: %v", err)
	}
	if finalized {
		t.Fatal("second finalization reported finalized=true; the guard is not once-only")
	}
	var after struct {
		TotalFare         float64  `db:"total_fare"`
		QuotedTotal       *float64 `db:"quoted_total_fare"`
		GradeUplift       *float64 `db:"grade_uplift_pct"`
		QuotedGradeUplift *float64 `db:"quoted_grade_uplift_pct"`
	}
	if err := db.Get(&after, `SELECT total_fare, quoted_total_fare, grade_uplift_pct,
		quoted_grade_uplift_pct FROM rides WHERE id=$1`, rideID); err != nil {
		t.Fatalf("read after second call: %v", err)
	}
	if after.TotalFare != 32.52 || after.QuotedTotal == nil || *after.QuotedTotal != 24.43 {
		t.Errorf("second call changed the fare: total %v quoted %v, want 32.52 / 24.43",
			after.TotalFare, after.QuotedTotal)
	}
	if after.GradeUplift == nil || *after.GradeUplift != finalUplift {
		t.Errorf("second call changed the applied uplift: %v, want %v", after.GradeUplift, finalUplift)
	}
	if after.QuotedGradeUplift == nil || *after.QuotedGradeUplift != 0.1000 {
		t.Errorf("second call changed the quoted uplift: %v, want 0.1000", after.QuotedGradeUplift)
	}
}
