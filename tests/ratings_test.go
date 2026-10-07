package tests

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"

	"ride-hailing-api/internal/model"
)

// ratingList mirrors the public envelope of GET /api/v1/{rider,driver}/ratings.
type ratingList struct {
	Ratings []struct {
		ID        string `json:"id"`
		RideID    string `json:"ride_id"`
		RaterRole string `json:"rater_role"`
		Score     int    `json:"score"`
		Comment   string `json:"comment"`
	} `json:"ratings"`
	Total      int `json:"total"`
	Page       int `json:"page"`
	PerPage    int `json:"per_page"`
	TotalPages int `json:"total_pages"`
}

func decodeRatings(t *testing.T, body []byte) ratingList {
	t.Helper()
	var got ratingList
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decoding ratings response: %v (body=%s)", err, body)
	}
	return got
}

// TestDriverRatingsReturnsSubmittedRatings pins the server half of
// driver_app_plans bug #5: GET /api/v1/driver/ratings must return the driver's
// own submissions (not the old stub) with the ride_id the app folds into its
// "already rated" set, and must not leak the rider's row on the same ride.
func TestDriverRatingsReturnsSubmittedRatings(t *testing.T) {
	riderEmail := "rider.ratings.drv@test.com"
	driverEmail := "driver.ratings.drv@test.com"
	registerAndLogin(t, riderEmail, "+7903000001")
	driverToken := registerDriver(t, driverEmail, "+7903000002")

	riderUser, err := ts.UserRepo.FindByEmail(riderEmail)
	if err != nil {
		t.Fatalf("load rider user: %v", err)
	}
	driverUser, err := ts.UserRepo.FindByEmail(driverEmail)
	if err != nil {
		t.Fatalf("load driver user: %v", err)
	}

	// The driver submitted two ratings; the rider also rated the SAME first
	// ride (the UNIQUE(ride_id, rater_role) pair). Role scoping means the
	// driver response carries only the driver rows.
	seedRatings(t,
		model.Rating{RideID: "ride-ratings-drv-1", RaterRole: "driver", RaterID: driverUser.ID, RateeID: riderUser.ID, Score: 5, Comment: "smooth"},
		model.Rating{RideID: "ride-ratings-drv-2", RaterRole: "driver", RaterID: driverUser.ID, RateeID: riderUser.ID, Score: 4},
		model.Rating{RideID: "ride-ratings-drv-1", RaterRole: "rider", RaterID: riderUser.ID, RateeID: driverUser.ID, Score: 1, Comment: "rider side"},
	)

	resp := ts.DoRequest("GET", "/api/v1/driver/ratings", driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	got := decodeRatings(t, resp.Body)
	if got.Total != 2 {
		t.Fatalf("total = %d, want 2 (only the driver's rows)", got.Total)
	}
	if len(got.Ratings) != 2 {
		t.Fatalf("returned %d ratings, want 2", len(got.Ratings))
	}
	seen := map[string]int{}
	for _, r := range got.Ratings {
		if r.RaterRole != "driver" {
			t.Errorf("rater_role = %q, want driver (role leak)", r.RaterRole)
		}
		if r.RideID == "ride-ratings-drv-1" && r.Score != 5 {
			t.Errorf("ride-ratings-drv-1 score = %d, want 5", r.Score)
		}
		seen[r.RideID] = r.Score
	}
	if seen["ride-ratings-drv-2"] != 4 {
		t.Errorf("ride-ratings-drv-2 score = %d, want 4", seen["ride-ratings-drv-2"])
	}
	// The public shape must not carry ratee_id.
	if strings.Contains(string(resp.Body), "ratee_id") {
		t.Errorf("body leaks ratee_id: %s", resp.Body)
	}
}

// TestDriverRatingsRideIDFilter is the driver-route half of the per-ride
// existence filter: the shared handler must resolve a known ride to the
// driver's own row and an unknown ride to an empty 0-total 200, never the
// rider's row on the same ride.
func TestDriverRatingsRideIDFilter(t *testing.T) {
	riderEmail := "rider.ratings.drv.exist@test.com"
	driverEmail := "driver.ratings.drv.exist@test.com"
	registerAndLogin(t, riderEmail, "+7909000001")
	driverToken := registerDriver(t, driverEmail, "+7909000002")

	riderUser, err := ts.UserRepo.FindByEmail(riderEmail)
	if err != nil {
		t.Fatalf("load rider user: %v", err)
	}
	driverUser, err := ts.UserRepo.FindByEmail(driverEmail)
	if err != nil {
		t.Fatalf("load driver user: %v", err)
	}

	const (
		rideA = "12121212-3434-5656-7878-909090909090"
		rideC = "abababab-cdcd-efef-0101-232323232323"
	)
	seedRatings(t,
		model.Rating{RideID: rideA, RaterRole: "driver", RaterID: driverUser.ID, RateeID: riderUser.ID, Score: 5},
		model.Rating{RideID: rideA, RaterRole: "rider", RaterID: riderUser.ID, RateeID: driverUser.ID, Score: 1},
	)

	resp := ts.DoRequest("GET", "/api/v1/driver/ratings?ride_id="+rideA, driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	got := decodeRatings(t, resp.Body)
	if got.Total != 1 || len(got.Ratings) != 1 || got.Ratings[0].RaterRole != "driver" || got.Ratings[0].Score != 5 {
		t.Fatalf("driver rideA filter total=%d rows=%+v, want one driver score-5 row", got.Total, got.Ratings)
	}

	resp = ts.DoRequest("GET", "/api/v1/driver/ratings?ride_id="+rideC, driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	if got := decodeRatings(t, resp.Body); got.Total != 0 || len(got.Ratings) != 0 {
		t.Fatalf("driver rideC filter total=%d rows=%d, want 0/0", got.Total, len(got.Ratings))
	}
}

// TestRiderRatingsReturnsSubmittedRatings is the symmetric rider endpoint.
func TestRiderRatingsReturnsSubmittedRatings(t *testing.T) {
	riderEmail := "rider.ratings.rdr@test.com"
	driverEmail := "driver.ratings.rdr@test.com"
	riderToken := registerAndLogin(t, riderEmail, "+7904000001")
	registerDriver(t, driverEmail, "+7904000002")

	riderUser, err := ts.UserRepo.FindByEmail(riderEmail)
	if err != nil {
		t.Fatalf("load rider user: %v", err)
	}
	driverUser, err := ts.UserRepo.FindByEmail(driverEmail)
	if err != nil {
		t.Fatalf("load driver user: %v", err)
	}

	seedRatings(t,
		model.Rating{RideID: "ride-ratings-rdr-1", RaterRole: "rider", RaterID: riderUser.ID, RateeID: driverUser.ID, Score: 3, Comment: "ok"},
		model.Rating{RideID: "ride-ratings-rdr-1", RaterRole: "driver", RaterID: driverUser.ID, RateeID: riderUser.ID, Score: 5},
	)

	resp := ts.DoRequest("GET", "/api/v1/rider/ratings", riderToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	got := decodeRatings(t, resp.Body)
	if got.Total != 1 || len(got.Ratings) != 1 {
		t.Fatalf("total=%d len=%d, want 1/1 (only the rider's row)", got.Total, len(got.Ratings))
	}
	if got.Ratings[0].RaterRole != "rider" || got.Ratings[0].Score != 3 {
		t.Errorf("got role=%q score=%d, want rider/3", got.Ratings[0].RaterRole, got.Ratings[0].Score)
	}
}

// TestRatingsPaginationAndClamp covers the history-shaped pagination contract:
// per_page is clamped, and an out-of-range page is an empty list, not an error.
func TestRatingsPaginationAndClamp(t *testing.T) {
	email := "rider.ratings.page@test.com"
	token := registerAndLogin(t, email, "+7905000001")
	user, err := ts.UserRepo.FindByEmail(email)
	if err != nil {
		t.Fatalf("load user: %v", err)
	}

	seedRatings(t,
		model.Rating{RideID: "ride-page-1", RaterRole: "rider", RaterID: user.ID, RateeID: user.ID, Score: 5},
		model.Rating{RideID: "ride-page-2", RaterRole: "rider", RaterID: user.ID, RateeID: user.ID, Score: 4},
		model.Rating{RideID: "ride-page-3", RaterRole: "rider", RaterID: user.ID, RateeID: user.ID, Score: 2},
	)

	// per_page above the cap is normalized to the default 20.
	resp := ts.DoRequest("GET", "/api/v1/rider/ratings?page=1&per_page=999", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	if got := decodeRatings(t, resp.Body); got.PerPage != 20 {
		t.Errorf("per_page = %d, want clamped 20", got.PerPage)
	}

	// A page past the end returns an empty list with the real total, not an error.
	resp = ts.DoRequest("GET", "/api/v1/rider/ratings?page=99&per_page=1", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	got := decodeRatings(t, resp.Body)
	if got.Total != 3 {
		t.Errorf("total = %d, want 3", got.Total)
	}
	if len(got.Ratings) != 0 {
		t.Errorf("out-of-range page returned %d ratings, want 0", len(got.Ratings))
	}
	if got.TotalPages != 3 {
		t.Errorf("total_pages = %d, want 3", got.TotalPages)
	}
}

// TestRatingsRepoFailureIs500 pins the error contract: a repository read
// failure is 5xx INTERNAL with the operation sentence, never a 4xx and never a
// stub-shaped 200.
func TestRatingsRepoFailureIs500(t *testing.T) {
	email := "rider.ratings.outage@test.com"
	token := registerAndLogin(t, email, "+7906000001")
	if _, err := ts.UserRepo.FindByEmail(email); err != nil {
		t.Fatalf("load user: %v", err)
	}

	ts.RideRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := ts.DoRequest("GET", "/api/v1/rider/ratings", token, nil)
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to load ratings") {
		t.Fatalf("body = %s, want operation sentence 'failed to load ratings'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "connection reset") {
		t.Fatalf("body leaks driver error: %s", resp.Body)
	}
	if strings.Contains(string(resp.Body), `"status":"stub"`) {
		t.Fatalf("body is the old stub shape: %s", resp.Body)
	}
}

// TestRatingsRideIDFilterResolvesExistence covers the per-ride existence
// filter: a known ride_id returns that rater's 0-or-1 row (envelope shape
// unchanged, total 0/1), an unknown ride is a definitive empty 200, and the
// filter never leaks another rater's row on the same ride.
func TestRatingsRideIDFilterResolvesExistence(t *testing.T) {
	riderEmail := "rider.ratings.exist@test.com"
	otherEmail := "rider.ratings.exist.other@test.com"
	token := registerAndLogin(t, riderEmail, "+7907000001")
	registerAndLogin(t, otherEmail, "+7907000002")

	riderUser, err := ts.UserRepo.FindByEmail(riderEmail)
	if err != nil {
		t.Fatalf("load rider user: %v", err)
	}
	otherUser, err := ts.UserRepo.FindByEmail(otherEmail)
	if err != nil {
		t.Fatalf("load other user: %v", err)
	}

	const (
		rideA = "11111111-2222-3333-4444-555555555555"
		rideB = "66666666-7777-8888-9999-aaaaaaaaaaaa"
		rideC = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
	)
	seedRatings(t,
		model.Rating{RideID: rideA, RaterRole: "rider", RaterID: riderUser.ID, RateeID: otherUser.ID, Score: 5, Comment: "a"},
		model.Rating{RideID: rideB, RaterRole: "rider", RaterID: riderUser.ID, RateeID: otherUser.ID, Score: 4},
		model.Rating{RideID: rideA, RaterRole: "rider", RaterID: otherUser.ID, RateeID: riderUser.ID, Score: 1, Comment: "other"},
	)

	// A rated ride resolves to exactly one row.
	resp := ts.DoRequest("GET", "/api/v1/rider/ratings?ride_id="+rideA, token, nil)
	resp.AssertStatus(t, http.StatusOK)
	got := decodeRatings(t, resp.Body)
	if got.Total != 1 || len(got.Ratings) != 1 || got.Ratings[0].Score != 5 || got.Ratings[0].RideID != rideA {
		t.Fatalf("rideA filter total=%d rows=%+v, want one score-5 row", got.Total, got.Ratings)
	}
	if got.Ratings[0].RaterRole != "rider" {
		t.Errorf("rater_role = %q, want rider (role leak)", got.Ratings[0].RaterRole)
	}

	// An unrated ride is a definitive empty answer, never a list or an error.
	resp = ts.DoRequest("GET", "/api/v1/rider/ratings?ride_id="+rideC, token, nil)
	resp.AssertStatus(t, http.StatusOK)
	got = decodeRatings(t, resp.Body)
	if got.Total != 0 || len(got.Ratings) != 0 {
		t.Fatalf("rideC filter total=%d rows=%d, want 0/0 (false unrated)", got.Total, len(got.Ratings))
	}
	if got.TotalPages != 0 {
		t.Errorf("total_pages = %d, want 0", got.TotalPages)
	}

	// No param preserves today's list behavior for the same seeded data: only
	// the caller's two rows, never the other user's same-ride row.
	resp = ts.DoRequest("GET", "/api/v1/rider/ratings", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	got = decodeRatings(t, resp.Body)
	if got.Total != 2 || len(got.Ratings) != 2 {
		t.Fatalf("no-param total=%d rows=%d, want 2/2", got.Total, len(got.Ratings))
	}
}

// TestRatingsRideIDFilterValidationAndAuth pins the edge contract: a malformed
// ride_id is a 422 VALIDATION_ERROR (not a Postgres cast 500), and the filtered
// route stays behind the same Bearer auth as the list.
func TestRatingsRideIDFilterValidationAndAuth(t *testing.T) {
	email := "rider.ratings.exist.bad@test.com"
	token := registerAndLogin(t, email, "+7908000001")

	resp := ts.DoRequest("GET", "/api/v1/rider/ratings?ride_id=not-a-uuid", token, nil)
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
	if !strings.Contains(string(resp.Body), "invalid ride_id") {
		t.Fatalf("body = %s, want 'invalid ride_id'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "not-a-uuid") {
		t.Fatalf("body echoes the bad value: %s", resp.Body)
	}

	resp = ts.DoRequest("GET", "/api/v1/rider/ratings?ride_id=11111111-2222-3333-4444-555555555555", "", nil)
	resp.AssertStatus(t, http.StatusUnauthorized)
}

func seedRatings(t *testing.T, ratings ...model.Rating) {
	t.Helper()
	for i := range ratings {
		r := ratings[i]
		if err := ts.RideRepo.CreateRating(&r); err != nil {
			t.Fatalf("seed rating: %v", err)
		}
	}
}
