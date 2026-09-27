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
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.driveraccept.rider@test.com",
		"phone":    "+9292929292",
		"password": "SecurePass1",
	})
	riderLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.driveraccept.rider@test.com",
		"password": "SecurePass1",
	})
	var riderLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, riderLogin.Body, &riderLoginResult)
	riderToken := riderLoginResult.AccessToken

	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.driveraccept.driver@test.com",
		"phone":    "+9393939393",
		"password": "SecurePass1",
	})
	driverLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.driveraccept.driver@test.com",
		"password": "SecurePass1",
	})
	var driverLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken := driverLoginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", driverToken, nil)

	driverLogin = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.driveraccept.driver@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken = driverLoginResult.AccessToken

	conn := ts.DialWS(t, riderToken)
	defer func() { _ = conn.Close() }()

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
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

	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	testutil.ParseJSON(t, createResp.Body, &createResult)

	acceptResp := ts.DoRequest("POST", "/api/v1/driver/rides/"+createResult.Ride.ID+"/accept", driverToken, nil)
	acceptResp.AssertStatus(t, http.StatusOK)

	msg = testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data = msg["data"].(map[string]interface{})
	if data["status"] != "accepted" {
		t.Errorf("expected status 'accepted', got %v", data["status"])
	}
	if data["ride_id"] != createResult.Ride.ID {
		t.Errorf("expected ride_id %s, got %v", createResult.Ride.ID, data["ride_id"])
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

func TestWSDriverLocationPush(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.location.rider@test.com",
		"phone":    "+9595959595",
		"password": "SecurePass1",
	})
	riderLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.location.rider@test.com",
		"password": "SecurePass1",
	})
	var riderLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, riderLogin.Body, &riderLoginResult)
	riderToken := riderLoginResult.AccessToken

	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.location.driver@test.com",
		"phone":    "+9696969696",
		"password": "SecurePass1",
	})
	driverLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.location.driver@test.com",
		"password": "SecurePass1",
	})
	var driverLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken := driverLoginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", driverToken, nil)

	driverLogin = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.location.driver@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken = driverLoginResult.AccessToken

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
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

	acceptResp := ts.DoRequest("POST", "/api/v1/driver/rides/"+createResult.Ride.ID+"/accept", driverToken, nil)
	acceptResp.AssertStatus(t, http.StatusOK)

	conn := ts.DialWS(t, riderToken)
	defer func() { _ = conn.Close() }()

	locResp := ts.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat":     40.7150,
		"lng":     -74.0080,
		"heading": 180,
		"speed":   25.5,
	})
	locResp.AssertStatus(t, http.StatusNoContent)

	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "driver.location" {
		t.Errorf("expected type 'driver.location', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["ride_id"] != createResult.Ride.ID {
		t.Errorf("expected ride_id %s, got %v", createResult.Ride.ID, data["ride_id"])
	}
	lat := data["lat"].(float64)
	if lat != 40.7150 {
		t.Errorf("expected lat 40.7150, got %f", lat)
	}
}

func TestWSRiderReceivesStatusTransition(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.lifecycle.rider@test.com",
		"phone":    "+9797979797",
		"password": "SecurePass1",
	})
	riderLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.lifecycle.rider@test.com",
		"password": "SecurePass1",
	})
	var riderLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, riderLogin.Body, &riderLoginResult)
	riderToken := riderLoginResult.AccessToken

	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "ws.lifecycle.driver@test.com",
		"phone":    "+9898989898",
		"password": "SecurePass1",
	})
	driverLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.lifecycle.driver@test.com",
		"password": "SecurePass1",
	})
	var driverLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken := driverLoginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", driverToken, nil)

	driverLogin = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "ws.lifecycle.driver@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken = driverLoginResult.AccessToken

	conn := ts.DialWS(t, riderToken)
	defer func() { _ = conn.Close() }()

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
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
	rideID := createResult.Ride.ID

	expected := []string{"pending", "accepted", "driver_arrived", "in_progress", "completed"}

	msg := testutil.ReadWSMessage(t, conn)
	checkStatus(t, msg, expected[0], rideID)

	acceptResp := ts.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil)
	acceptResp.AssertStatus(t, http.StatusOK)

	msg = testutil.ReadWSMessage(t, conn)
	checkStatus(t, msg, expected[1], rideID)

	transitions := []string{"driver_arrived", "in_progress", "completed"}
	for _, s := range transitions {
		advResp := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken, map[string]string{
			"status": s,
		})
		advResp.AssertStatus(t, http.StatusOK)

		msg = testutil.ReadWSMessage(t, conn)
		checkStatus(t, msg, s, rideID)
	}
}

func checkStatus(t *testing.T, msg map[string]interface{}, expectedStatus, expectedRideID string) {
	t.Helper()
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != expectedStatus {
		t.Errorf("expected status '%s', got %v", expectedStatus, data["status"])
	}
	if data["ride_id"] != expectedRideID {
		t.Errorf("expected ride_id %s, got %v", expectedRideID, data["ride_id"])
	}
}
