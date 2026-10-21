package tests

import (
	"net/http"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/tests/testutil"
)

// TestGetCurrentRideHidesStalePendingViaMock exercises the MockRideRepo parity
// twin of the real FindCurrentRideByRider age guard
// (api_plans/[rides]_orphaned_pending_expiry.md D4). It uses an isolated server
// so seeding rows does not leak into the shared ts. The stale row is created
// directly through the mock (no dispatch goroutine) and then aged, which is the
// only way CreateRide's always-now created_at can represent an orphan.
//
// If the mock filter is removed this fails (the stale pending is returned); if
// the real SQL filter is removed the DB-backed
// TestGetCurrentRideHidesStalePending in ride_current_stale_integration_test.go
// fails. Together they keep the mock and the SQL in lockstep.
func TestGetCurrentRideHidesStalePendingViaMock(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	defer srv.Close()

	const email = "rider.currentstale.mock@test.com"
	regResp := srv.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    email,
		"phone":    "+7905000991",
		"password": "SecurePass1",
	})
	regResp.AssertStatus(t, http.StatusCreated)

	var registered struct {
		User struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	testutil.ParseJSON(t, regResp.Body, &registered)
	if registered.User.ID == "" {
		t.Fatal("register response carried no user id")
	}

	loginResp := srv.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    email,
		"password": "SecurePass1",
	})
	var login struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &login)
	if login.AccessToken == "" {
		t.Fatal("login response carried no access token")
	}

	seedPending := func(age time.Duration) *model.Ride {
		t.Helper()
		ride := &model.Ride{RiderID: registered.User.ID}
		if err := srv.RideRepo.CreateRide(ride); err != nil {
			t.Fatalf("seed pending ride: %v", err)
		}
		if err := srv.RideRepo.SetRideCreatedAt(ride.ID, time.Now().Add(-age)); err != nil {
			t.Fatalf("age pending ride: %v", err)
		}
		return ride
	}

	currentRide := func() (*model.Ride, []model.RideStop) {
		t.Helper()
		resp := srv.DoRequest("GET", "/api/v1/rides/current", login.AccessToken, nil)
		resp.AssertStatus(t, http.StatusOK)
		var body struct {
			Ride  *model.Ride      `json:"ride"`
			Stops []model.RideStop `json:"stops"`
		}
		testutil.ParseJSON(t, resp.Body, &body)
		return body.Ride, body.Stops
	}

	stale := seedPending(11 * time.Minute)
	ride, stops := currentRide()
	if ride != nil {
		t.Fatalf("stale pending %s was returned as current: %+v (the mock age filter diverged from the SQL guard)", stale.ID, ride)
	}
	if stops == nil {
		t.Error("stops = nil, want a non-nil empty slice (JSON [])")
	}
	if len(stops) != 0 {
		t.Errorf("stops = %+v, want none for a hidden ride", stops)
	}

	fresh := seedPending(time.Second)
	ride, _ = currentRide()
	if ride == nil || ride.ID != fresh.ID {
		t.Fatalf("fresh pending = %+v, want the fresh ride %s", ride, fresh.ID)
	}
	if ride.Status != "pending" {
		t.Errorf("status = %q, want pending", ride.Status)
	}
}
