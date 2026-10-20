package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/tests/testutil"
)

func TestWSRiderReceivesRideCreated(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.created@test.com",
		"phone":    "+9191919191",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.created@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	conn := ts.DialWS(t, token)
	defer func() { _ = conn.Close() }()

	createResp := ts.DoRequest("POST", "/api/v1/rides", token, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != "pending" {
		t.Errorf("expected status 'pending', got %v", data["status"])
	}
	if data["ride_id"] == "" {
		t.Error("expected ride_id to be non-empty")
	}
}

func TestWSRiderReceivesDriverAccept(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 961
	riderToken := strictRider(t, srv, seed)
	driverToken := strictDriver(t, srv, seed)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)
	srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()
	driverConn := srv.DialWS(t, driverToken)
	defer func() { _ = driverConn.Close() }()

	createResp := srv.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != "pending" {
		t.Errorf("expected status 'pending', got %v", data["status"])
	}

	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	testutil.ParseJSON(t, createResp.Body, &createResult)
	rideID := createResult.Ride.ID

	// The driver holds a live offer; HTTP accept is the primary path.
	offer := testutil.ReadWSMessage(t, driverConn)
	if offer["type"] != "ride.offer" {
		t.Fatalf("expected ride.offer, got %v", offer["type"])
	}
	acceptResp := srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil)
	acceptResp.AssertStatus(t, http.StatusOK)

	msg = testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data = msg["data"].(map[string]interface{})
	if data["status"] != "accepted" {
		t.Errorf("expected status 'accepted', got %v", data["status"])
	}
	if data["ride_id"] != rideID {
		t.Errorf("expected ride_id %s, got %v", rideID, data["ride_id"])
	}
}

func TestWSRiderReceivesCancel(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.cancel.rider@test.com",
		"phone":    "+9494949494",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.cancel.rider@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	conn := ts.DialWS(t, token)
	defer func() { _ = conn.Close() }()

	createResp := ts.DoRequest("POST", "/api/v1/rides", token, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	testutil.ParseJSON(t, createResp.Body, &createResult)

	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != "pending" {
		t.Errorf("expected status 'pending', got %v", data["status"])
	}

	cancelResp := ts.DoRequest("POST", "/api/v1/rides/"+createResult.Ride.ID+"/cancel", token, nil)
	cancelResp.AssertStatus(t, http.StatusOK)

	msg = testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data = msg["data"].(map[string]interface{})
	if data["status"] != "cancelled" {
		t.Errorf("expected status 'cancelled', got %v", data["status"])
	}
	if data["cancelled_by"] != "rider" {
		t.Errorf("expected cancelled_by 'rider', got %v", data["cancelled_by"])
	}
}
