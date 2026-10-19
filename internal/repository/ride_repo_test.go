package repository

import (
	"strings"
	"testing"
)

// TestUpdateRideStatusQuery pins the DB-free shape of the status UPDATE built by
// updateRideStatusQuery: a status WITH a timestamp column keeps the exact
// historical statement and argument order, and a status WITHOUT one omits the
// column entirely (the old Sprintf emitted `SET status=$1, =$2, ...`, which
// Postgres rejects — the no_driver_available defect).
//
// This is a shape guard, not proof the SQL executes; the DB-backed gate is
// TestRideRepoUpdateRideStatusNoDriverAvailable (integration build tag).
func TestUpdateRideStatusQuery(t *testing.T) {
	const (
		withTS = "UPDATE rides SET status=$1, %s=$2, updated_at=NOW() WHERE id=$3"
		noTS   = "UPDATE rides SET status=$1, updated_at=NOW() WHERE id=$2"
	)

	tests := []struct {
		status        string
		wantColumn    string // "" means no timestamp column
		wantQuery     string
		wantTimestamp bool
	}{
		{status: "accepted", wantColumn: "accepted_at", wantQuery: "UPDATE rides SET status=$1, accepted_at=$2, updated_at=NOW() WHERE id=$3", wantTimestamp: true},
		{status: "driver_arrived", wantColumn: "driver_arrived_at", wantQuery: "UPDATE rides SET status=$1, driver_arrived_at=$2, updated_at=NOW() WHERE id=$3", wantTimestamp: true},
		{status: "in_progress", wantColumn: "started_at", wantQuery: "UPDATE rides SET status=$1, started_at=$2, updated_at=NOW() WHERE id=$3", wantTimestamp: true},
		{status: "completed", wantColumn: "completed_at", wantQuery: "UPDATE rides SET status=$1, completed_at=$2, updated_at=NOW() WHERE id=$3", wantTimestamp: true},
		{status: "cancelled", wantColumn: "cancelled_at", wantQuery: "UPDATE rides SET status=$1, cancelled_at=$2, updated_at=NOW() WHERE id=$3", wantTimestamp: true},
		{status: "pending", wantColumn: "", wantQuery: noTS, wantTimestamp: false},
		{status: "no_driver_available", wantColumn: "", wantQuery: noTS, wantTimestamp: false},
	}

	for _, tt := range tests {
		t.Run(tt.status, func(t *testing.T) {
			if got := rideStatusTimestampColumn(tt.status); got != tt.wantColumn {
				t.Errorf("rideStatusTimestampColumn(%q) = %q, want %q", tt.status, got, tt.wantColumn)
			}

			query, withTimestamp := updateRideStatusQuery(tt.status)
			if query != tt.wantQuery {
				t.Errorf("updateRideStatusQuery(%q) query = %q, want %q", tt.status, query, tt.wantQuery)
			}
			if withTimestamp != tt.wantTimestamp {
				t.Errorf("updateRideStatusQuery(%q) withTimestamp = %v, want %v", tt.status, withTimestamp, tt.wantTimestamp)
			}

			// The defect signature: a dangling column assignment from the
			// unconditional Sprintf.
			if strings.Contains(query, ", =") || strings.Contains(query, ",=") {
				t.Errorf("query = %q contains a dangling column assignment", query)
			}
			// Never interpolate the caller-supplied status value into SQL; it
			// is always passed as $1. Check the quoted literal (the form an
			// injection/formatting bug would produce) rather than a bare
			// substring, which would collide with e.g. accepted/accepted_at.
			if strings.Contains(query, "'"+tt.status+"'") {
				t.Errorf("query = %q interpolates the status value %q", query, tt.status)
			}

			// Guard the historical statement shape too: every timestamped form
			// must be exactly the old statement.
			if tt.wantTimestamp && tt.wantColumn != "" {
				want := strings.Replace(withTS, "%s", tt.wantColumn, 1)
				if query != want {
					t.Errorf("timestamped query drifted: got %q, want %q", query, want)
				}
			}
		})
	}
}
