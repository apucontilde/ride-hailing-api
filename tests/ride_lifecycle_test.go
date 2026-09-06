package tests

import (
	"fmt"
	"net/http"
	"testing"

	"github.com/gorilla/websocket"

	"ride-hailing-api/tests/testutil"
)

func TestRideRequestCreatesPending(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.ride@test.com",
		"phone":    "+1010101010",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.ride@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	resp.AssertStatus(t, http.StatusCreated)
	resp.AssertJSONHas(t, "ride.status", "pending")
	resp.AssertJSONHas(t, "ride.id")
}

// TestRideShowsInDriverOptions covers the "waiting for a driver" loop
// (US-6) and the driver's ride-offer screen (US-D5/US-D6).
func TestRideShowsInDriverOptions(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.life.901@test.com", "+7901000001")
	driverToken := registerDriver(t, "driver.life.901@test.com", "+7901000002")

	// Go online with a live location so dispatch can find the driver (US-D4).
	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := lifeCoords(t, 901)
	ts.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	// Only drivers with a live /ws connection receive offers (US-6 notes).
	driverConn := ts.DialWS(t, driverToken)
	defer driverConn.Close()

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat":  pickupLat,
		"pickup_lng":  pickupLng,
		"dropoff_lat": dropoffLat,
		"dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)
	rideID := createResult.Ride.ID

	// The driver is offered the pending ride over WebSocket.
	offer := testutil.ReadWSMessage(t, driverConn)
	if offer["type"] != "ride.offer" {
		t.Fatalf("expected type 'ride.offer', got %v", offer["type"])
	}
	offerData := offer["data"].(map[string]interface{})
	if offerData["ride_id"] != rideID {
		t.Errorf("expected offer ride_id %s, got %v", rideID, offerData["ride_id"])
	}

	// The driver can pull the ride's details while it is still pending.
	detailResp := ts.DoRequest("GET", "/api/v1/driver/rides/"+rideID, driverToken, nil)
	detailResp.AssertStatus(t, http.StatusOK)
	detailResp.AssertJSONHas(t, "ride.status", "pending")
	detailResp.AssertJSONHas(t, "ride.pickup_lat")
	detailResp.AssertJSONHas(t, "ride.pickup_lng")

	// US-6 polling fallback: rides/current reflects the live request while searching.
	currentResp := ts.DoRequest("GET", "/api/v1/rides/current", riderToken, nil)
	currentResp.AssertStatus(t, http.StatusOK)
	currentResp.AssertJSONHas(t, "ride.id", rideID)

	// Decline so the dispatcher's offer loop finishes instead of lingering
	// (dispatch then marks the ride no_driver_available, per US-6).
	driverConn.WriteJSON(map[string]interface{}{
		"type": "ride.decline",
		"data": map[string]string{"ride_id": rideID},
	})
}

// TestDriverAcceptsRide covers US-6 (search → accepted) and US-D6.
func TestDriverAcceptsRide(t *testing.T) {
	_, _, _, rideID, accepted := setupAcceptedRide(t, 902)
	if rideID == "" {
		t.Fatal("expected a ride id")
	}

	if accepted["ride_id"] != rideID {
		t.Errorf("expected accepted ride_id %s, got %v", rideID, accepted["ride_id"])
	}
	if accepted["status"] != "accepted" {
		t.Errorf("expected status 'accepted', got %v", accepted["status"])
	}
	if accepted["eta_seconds"] != float64(454) {
		t.Errorf("expected eta_seconds 454 (mock route 5000m/11mps), got %v", accepted["eta_seconds"])
	}
	driver := accepted["driver"].(map[string]interface{})
	if driver["id"] == "" {
		t.Error("expected driver.id to be non-empty")
	}
	if driver["first_name"] != "Test" {
		t.Errorf("expected driver.first_name 'Test', got %v", driver["first_name"])
	}
	vehicle := driver["vehicle"].(map[string]interface{})
	if vehicle["make"] == "" || vehicle["plate_number"] == "" {
		t.Error("expected driver.vehicle to carry make and plate_number")
	}
}

// TestRiderReceivesDriverUpdates covers US-7: seeing the matched driver's
// live location once the trip is accepted.
func TestRiderReceivesDriverUpdates(t *testing.T) {
	riderConn, riderToken, driverToken, rideID, accepted := setupAcceptedRide(t, 903)

	driverInfo := accepted["driver"].(map[string]interface{})
	driverID, _ := driverInfo["id"].(string)
	if driverID == "" {
		t.Fatalf("expected accepted payload to carry driver.id, got %v", driverInfo["id"])
	}

	// Driver streams a location update; the rider receives driver.location.
	locResp := ts.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat":     40.7150,
		"lng":     -74.0080,
		"heading": 180,
		"speed":   25.5,
	})
	locResp.AssertStatus(t, http.StatusNoContent)

	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "driver.location" {
		t.Errorf("expected type 'driver.location', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["ride_id"] != rideID {
		t.Errorf("expected ride_id %s, got %v", rideID, data["ride_id"])
	}
	if lat, ok := data["lat"].(float64); !ok || lat != 40.7150 {
		t.Errorf("expected lat 40.7150, got %v", data["lat"])
	}
	if lng, ok := data["lng"].(float64); !ok || lng != -74.0080 {
		t.Errorf("expected lng -74.0080, got %v", data["lng"])
	}

	// US-7 polling fallback: GET /drivers/:id/location returns the position.
	pollResp := ts.DoRequest("GET", "/api/v1/drivers/"+driverID+"/location", riderToken, nil)
	pollResp.AssertStatus(t, http.StatusOK)
	pollResp.AssertJSONHas(t, "lat", 40.7150)
	pollResp.AssertJSONHas(t, "lng", -74.0080)
}

// TestDriverArrivesAtPickup covers US-8 / US-D8.
func TestDriverArrivesAtPickup(t *testing.T) {
	riderConn, _, driverToken, rideID, _ := setupAcceptedRide(t, 904)

	advResp := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken, map[string]string{
		"status": "driver_arrived",
	})
	advResp.AssertStatus(t, http.StatusOK)

	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != "driver_arrived" {
		t.Errorf("expected status 'driver_arrived', got %v", data["status"])
	}
	if data["ride_id"] != rideID {
		t.Errorf("expected ride_id %s, got %v", rideID, data["ride_id"])
	}
}

// TestRideStartsAndUpdates covers US-8 / US-D9 (in_progress).
func TestRideStartsAndUpdates(t *testing.T) {
	riderConn, _, driverToken, rideID, _ := setupAcceptedRide(t, 905)

	// US-8: driver_arrived first, then in_progress.
	for _, status := range []string{"driver_arrived", "in_progress"} {
		advResp := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken, map[string]string{
			"status": status,
		})
		advResp.AssertStatus(t, http.StatusOK)

		msg := testutil.ReadWSMessage(t, riderConn)
		if msg["type"] != "ride.updated" {
			t.Errorf("expected type 'ride.updated', got %v", msg["type"])
		}
		data := msg["data"].(map[string]interface{})
		if data["status"] != status {
			t.Errorf("expected status %q, got %v", status, data["status"])
		}
		if data["ride_id"] != rideID {
			t.Errorf("expected ride_id %s, got %v", rideID, data["ride_id"])
		}
	}
}

// TestRideFinishes covers US-9 / US-D9 (completed + fare + receipt).
func TestRideFinishes(t *testing.T) {
	riderConn, riderToken, driverToken, rideID, _ := setupAcceptedRide(t, 906)

	// US-8/US-9: walk through driver_arrived → in_progress → completed.
	for _, status := range []string{"driver_arrived", "in_progress", "completed"} {
		advResp := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken, map[string]string{
			"status": status,
		})
		advResp.AssertStatus(t, http.StatusOK)

		msg := testutil.ReadWSMessage(t, riderConn)
		if msg["type"] != "ride.updated" {
			t.Fatalf("expected type 'ride.updated', got %v", msg["type"])
		}
		data := msg["data"].(map[string]interface{})
		if data["status"] != status {
			t.Fatalf("expected status %q, got %v", status, data["status"])
		}
		if status == "completed" {
			fare := data["fare"].(map[string]interface{})
			if _, ok := fare["total"].(float64); !ok {
				t.Errorf("expected completed event to carry fare.total, got %v", fare["total"])
			}
			if fare["base_fare"] == nil {
				t.Error("expected completed event to carry fare.base_fare")
			}
		}
	}

	receiptResp := ts.DoRequest("GET", "/api/v1/rides/"+rideID+"/receipt", riderToken, nil)
	receiptResp.AssertStatus(t, http.StatusOK)
	receiptResp.AssertJSONHas(t, "receipt.base_fare")
	receiptResp.AssertJSONHas(t, "receipt.total")
}

// registerAndLogin creates a rider account and returns its access token.
func registerAndLogin(t *testing.T, email, phone string) string {
	t.Helper()
	regResp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    email,
		"phone":    phone,
		"password": "SecurePass1",
	})
	regResp.AssertStatus(t, http.StatusCreated)
	return loginToken(t, email)
}

func loginToken(t *testing.T, email string) string {
	t.Helper()
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    email,
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)
	return loginResult.AccessToken
}

// registerDriver creates a driver account and returns a JWT with role="driver".
func registerDriver(t *testing.T, email, phone string) string {
	t.Helper()
	token := registerAndLogin(t, email, phone)
	ts.DoRequest("POST", "/api/v1/driver/register", token, nil).AssertStatus(t, http.StatusCreated)
	return loginToken(t, email)
}

// setupAcceptedRide walks a ride from request to accepted over the WebSocket
// (US-D6 primary path) and returns the established state for the lifecycle
// tests.
func setupAcceptedRide(t *testing.T, seed int) (*websocket.Conn, string, string, string, map[string]interface{}) {
	t.Helper()
	riderToken := registerAndLogin(t, fmt.Sprintf("rider.life.%d@test.com", seed), fmt.Sprintf("+7%d0001", seed))
	driverToken := registerDriver(t, fmt.Sprintf("driver.life.%d@test.com", seed), fmt.Sprintf("+7%d0002", seed))

	// Driver sets up their profile so the accept payload carries real info (US-D3).
	ts.DoRequest("PUT", "/api/v1/driver/me", driverToken, map[string]string{
		"first_name": "Test",
		"last_name":  "Driver",
	}).AssertStatus(t, http.StatusOK)

	// Online + broadcasting location so dispatch finds them (US-D4).
	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := lifeCoords(t, seed)
	ts.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	// Live /ws connections: required for the driver to be offered the ride.
	riderConn := ts.DialWS(t, riderToken)
	t.Cleanup(func() { riderConn.Close() })
	driverConn := ts.DialWS(t, driverToken)
	t.Cleanup(func() { driverConn.Close() })

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat":  pickupLat,
		"pickup_lng":  pickupLng,
		"dropoff_lat": dropoffLat,
		"dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)
	rideID := createResult.Ride.ID

	// Rider sees the pending push (US-5).
	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" || msg["data"].(map[string]interface{})["status"] != "pending" {
		t.Fatalf("expected pending ride.updated push, got %v", msg)
	}

	// The driver receives the offer and accepts over WebSocket (US-D5/US-D6).
	offer := testutil.ReadWSMessage(t, driverConn)
	if offer["type"] != "ride.offer" {
		t.Fatalf("expected ride.offer, got %v", offer["type"])
	}
	driverConn.WriteJSON(map[string]interface{}{
		"type": "ride.accept",
		"data": map[string]string{"ride_id": rideID},
	})

	msg = testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" {
		t.Fatalf("expected ride.updated, got %v", msg["type"])
	}
	accepted := msg["data"].(map[string]interface{})
	if accepted["status"] != "accepted" {
		t.Fatalf("expected status 'accepted', got %v", accepted["status"])
	}

	return riderConn, riderToken, driverToken, rideID, accepted
}

// lifeCoords returns ride + driver coordinates unique to a seed so that
// drivers left over from earlier lifecycle tests stay outside the dispatch
// search radius (which grows up to 10 km) instead of stealing the current
// ride's offer.
func lifeCoords(t *testing.T, seed int) (pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng float64) {
	t.Helper()
	offset := float64(seed-900) * 0.5
	pickupLat = 40.7128 + offset
	pickupLng = -74.0060
	dropoffLat = 40.7580 + offset
	dropoffLng = -73.9855
	driverLat = pickupLat + 0.0002
	driverLng = pickupLng
	return pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng
}

func TestRideCancelBeforeAccept(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.cancel@test.com",
		"phone":    "+1212121212",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.cancel@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	createResp := ts.DoRequest("POST", "/api/v1/rides", token, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	resp := ts.DoRequest("POST", "/api/v1/rides/"+createResult.Ride.ID+"/cancel", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "ride.status", "cancelled")
}

func TestRideCurrentReturnsNullWhenIdle(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.idle@test.com",
		"phone":    "+1313131313",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.idle@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/rides/current", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "ride")
}

func TestRideRequestRejectsMissingFields(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.missing@test.com",
		"phone":    "+1414141414",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.missing@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]string{
		"pickup_lat": "invalid",
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestRideHistoryPagination(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.pages@test.com",
		"phone":    "+1515151515",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.pages@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/rides/history?page=1&per_page=10", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "total")
	resp.AssertJSONHas(t, "page", float64(1))
}

func TestRideTipStub(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.tip@test.com",
		"phone":    "+1616161616",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.tip@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	createResp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.006,
		"dropoff_lat": 40.758,
		"dropoff_lng": -73.9855,
	})
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	resp := ts.DoRequest("POST", "/api/v1/rides/"+createResult.Ride.ID+"/tip", loginResult.AccessToken, map[string]float64{"amount": 5.0})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "status", "stub")
}

func TestRideReceipt(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.receipt@test.com",
		"phone":    "+1717171717",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.receipt@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	createResp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.006,
		"dropoff_lat": 40.758,
		"dropoff_lng": -73.9855,
	})
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	resp := ts.DoRequest("GET", "/api/v1/rides/"+createResult.Ride.ID+"/receipt", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "receipt.base_fare")
}
