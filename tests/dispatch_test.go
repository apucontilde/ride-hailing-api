package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/tests/testutil"
)

func TestDriverRideQueue(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.queue@test.com",
		"phone":    "+2626262626",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.queue@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", token, nil)

	// Re-login after driver registration to get a JWT with role="driver"
	loginResp = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.queue@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token = loginResult.AccessToken

	resp := ts.DoRequest("GET", "/api/v1/driver/rides/queue", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "queue")
}

// TestDriverAcceptWithoutLiveOfferIs404 pins the canonical accept funnel: a
// driver who holds no live offer (expired, taken by another driver, or never
// offered) answers 404, never a false 200. The 409 branch (an offer still
// parked while the ride left pending) is covered by the service/handler suites.
func TestDriverAcceptWithoutLiveOfferIs404(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 960
	riderToken := strictRider(t, srv, seed)
	driverToken := strictDriver(t, srv, seed)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)
	srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	driverConn := srv.DialWS(t, driverToken)
	defer func() { _ = driverConn.Close() }()

	createResp := srv.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)
	var created struct {
		Ride struct{ ID string } `json:"ride"`
	}
	testutil.ParseJSON(t, createResp.Body, &created)
	rideID := created.Ride.ID

	// Consume the live offer so the ride is accepted; a second accept has no
	// offer for this (or any other) driver and must be a 404.
	offer := testutil.ReadWSMessage(t, driverConn)
	if offer["type"] != "ride.offer" {
		t.Fatalf("expected ride.offer, got %v", offer["type"])
	}
	srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil).
		AssertStatus(t, http.StatusOK)

	again := srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil)
	again.AssertStatus(t, http.StatusNotFound)
	again.AssertJSONHas(t, "error.code", "NOT_FOUND")
}
