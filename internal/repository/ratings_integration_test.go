//go:build integration

package repository

import (
	"testing"
)

// TestFindRatingsByRaterIntegration exercises the real rater-scoped SQL against
// a live DB. It seeds a TEMP ratings table on a single-connection handle (the
// same trick the routing integration tests use) so the real table is never
// touched and every unqualified `ratings` reference resolves to the fixture.
func TestFindRatingsByRaterIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS ratings") })

	mustExec(t, db, `CREATE TEMP TABLE ratings (
		id         UUID        PRIMARY KEY,
		ride_id    UUID        NOT NULL,
		rater_role TEXT        NOT NULL,
		rater_id   UUID        NOT NULL,
		ratee_id   UUID        NOT NULL,
		score      INTEGER     NOT NULL,
		comment    TEXT        NOT NULL DEFAULT '',
		created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)

	const (
		driver1 = "11111111-1111-1111-1111-111111111111"
		rider1  = "22222222-2222-2222-2222-222222222222"
		driver2 = "33333333-3333-3333-3333-333333333333"
		ride1   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		ride2   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	)

	// driver1 submitted two ratings; rider1 submitted one on the SAME ride1
	// (the UNIQUE(ride_id, rater_role) pair); driver2 submitted an unrelated
	// rating. created_at is explicit so ordering and paging are deterministic.
	mustExec(t, db, `INSERT INTO ratings (id, ride_id, rater_role, rater_id, ratee_id, score, comment, created_at) VALUES
		('00000000-0000-0000-0000-000000000001', $1, 'driver', $2, $3, 5, 'smooth', NOW() - INTERVAL '2 hours'),
		('00000000-0000-0000-0000-000000000002', $4, 'driver', $2, $3, 3, '',       NOW() - INTERVAL '1 hour'),
		('00000000-0000-0000-0000-000000000003', $1, 'rider',  $3, $2, 1, 'meh',    NOW()),
		('00000000-0000-0000-0000-000000000004', $4, 'driver', $5, $3, 4, '',       NOW())`,
		ride1, driver1, rider1, ride2, driver2)

	repo := NewRideRepo(db)

	// Newest first, scoped to (driver1, driver).
	page1, total, err := repo.FindRatingsByRater(driver1, "driver", 1, 0)
	if err != nil {
		t.Fatalf("FindRatingsByRater page 1: %v", err)
	}
	if total != 2 || len(page1) != 1 {
		t.Fatalf("page1 total=%d len=%d, want 2/1", total, len(page1))
	}
	if page1[0].RideID != ride2 || page1[0].Score != 3 {
		t.Errorf("page1[0] = ride %s score %d, want ride2/3 (newest first)", page1[0].RideID, page1[0].Score)
	}
	if page1[0].RaterRole != "driver" {
		t.Errorf("rater_role = %q, want driver", page1[0].RaterRole)
	}

	// Offset advances into the older row.
	page2, _, err := repo.FindRatingsByRater(driver1, "driver", 1, 1)
	if err != nil {
		t.Fatalf("FindRatingsByRater page 2: %v", err)
	}
	if len(page2) != 1 || page2[0].RideID != ride1 || page2[0].Score != 5 {
		t.Fatalf("page2 = %+v, want ride1/5", page2)
	}

	// Out-of-range offset is an empty list with the real total, not an error.
	empty, total, err := repo.FindRatingsByRater(driver1, "driver", 10, 99)
	if err != nil {
		t.Fatalf("FindRatingsByRater out-of-range: %v", err)
	}
	if total != 2 || len(empty) != 0 {
		t.Fatalf("out-of-range total=%d len=%d, want 2/0", total, len(empty))
	}

	// Role scoping: driver1's rows are all rater_role='driver', so querying the
	// same rater_id as a rider returns nothing.
	noRider, noRiderTotal, err := repo.FindRatingsByRater(driver1, "rider", 10, 0)
	if err != nil {
		t.Fatalf("FindRatingsByRater rider role: %v", err)
	}
	if noRiderTotal != 0 || len(noRider) != 0 {
		t.Fatalf("driver1/rider rows=%+v total=%d, want 0 (role leak)", noRider, noRiderTotal)
	}

	// ...and the rider's own submission is reachable only under rater_role='rider'.
	riderRows, riderTotal, err := repo.FindRatingsByRater(rider1, "rider", 10, 0)
	if err != nil {
		t.Fatalf("FindRatingsByRater rider own: %v", err)
	}
	if riderTotal != 1 || len(riderRows) != 1 || riderRows[0].Score != 1 {
		t.Fatalf("rider1/rider rows=%+v total=%d, want one score-1 row", riderRows, riderTotal)
	}
}
