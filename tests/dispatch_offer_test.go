package tests

import (
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"ride-hailing-api/tests/testutil"
)

// These tests pin the "rider requests a ride, driver never sees the offer"
// bug class (US-D5 / US-D6).
//
// The pre-existing suite could not catch it because MockGeoRepo invents a
// driver when none is online (testutil.MockGeoRepo.FabricateNearbyDriver), so
// every ride was dispatched to a fictional "simulated-driver". These tests run
// against NewStrictTestServer instead, where a driver is only reachable if it
// genuinely went online, pushed a location inside the 30s liveness window, and
// holds a live /ws connection — exactly the three conditions the production
// query enforces (internal/repository/geo_repo.go:61-87) plus the hub's
// IsConnected gate (internal/service/dispatch.go:97).
//
// The e2e/browser suite in e2e/ covers the same story through the real UIs;
// this file is the fast, browser-free guard.

// strictDriver creates a driver account and returns a driver-role JWT.
func strictDriver(t *testing.T, srv *testutil.TestServer, seed int) string {
	t.Helper()
	email := fmt.Sprintf("offer.driver.%d@test.com", seed)
	srv.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
		"email":    email,
		"phone":    fmt.Sprintf("+86%08d", seed),
		"password": "SecurePass1",
	}).AssertStatus(t, http.StatusCreated)

	token := strictLogin(t, srv, email)
	srv.DoRequest("POST", "/api/v1/driver/register", token, nil).AssertStatus(t, http.StatusCreated)
	// Re-login: registering as a driver rotates the JWT so role becomes "driver".
	return strictLogin(t, srv, email)
}

func strictLogin(t *testing.T, srv *testutil.TestServer, email string) string {
	t.Helper()
	resp := srv.DoRequest("POST", "/api/v1/auth/login", "", map[string]string{
		"email":    email,
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusOK)
	var result struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, resp.Body, &result)
	return result.AccessToken
}

func strictRider(t *testing.T, srv *testutil.TestServer, seed int) string {
	t.Helper()
	email := fmt.Sprintf("offer.rider.%d@test.com", seed)
	srv.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
		"email":    email,
		"phone":    fmt.Sprintf("+87%08d", seed),
		"password": "SecurePass1",
	}).AssertStatus(t, http.StatusCreated)
	return strictLogin(t, srv, email)
}

// offerCoords returns a pickup/driver pair offset per seed so drivers left
// online by earlier tests stay outside the 10 km dispatch radius and cannot
// steal the current ride's offer.
//
// Seeds must stay near 900: the offset is in degrees, and 1 degree of latitude
// is ~111 km, so a large multiplier would walk the pickup out of the valid
// lat range and the location endpoint would answer 422. This mirrors
// lifeCoords in ride_lifecycle_test.go.
func offerCoords(seed int) (pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng float64) {
	offset := float64(seed-900) * 0.5
	pickupLat = 40.7128 + offset
	pickupLng = -74.0060
	dropoffLat = 40.7580 + offset
	dropoffLng = -73.9855
	driverLat = pickupLat + 0.0002 // ~22 m from the pickup
	driverLng = pickupLng
	return
}

// waitForNoOffer asserts the driver receives no offer within d. Used for the
// negative cases: silence is the pass condition.
func waitForNoOffer(t *testing.T, conn *websocket.Conn, d time.Duration) {
	t.Helper()
	msg, err := testutil.TryReadWSMessage(conn, d)
	if err != nil {
		t.Fatalf("unexpected websocket error while waiting for silence: %v", err)
	}
	if msg != nil {
		t.Fatalf("expected no ride.offer, got %v", msg["type"])
	}
}

// driverIDOf decodes the JWT subject by asking the server who we are, which
// avoids depending on the token's internal claim layout.
func driverIDOf(t *testing.T, srv *testutil.TestServer, token string) string {
	t.Helper()
	srv.DoRequest("GET", "/api/v1/driver/me", token, nil).AssertStatus(t, http.StatusOK)
	for _, id := range srv.GeoRepo.DriverIDs() {
		return id
	}
	t.Fatalf("no driver position recorded in the geo repo")
	return ""
}

// assertRiderToldNoDriver waits for the ride.updated push that tells the
// rider nobody is available.
//
// It has to be the WebSocket: no_driver_available is deliberately NOT an
// "active" status in FindCurrentRideByRider (internal/repository/ride_repo.go:61),
// so GET /rides/current stops reporting the ride the moment dispatch gives up.
// The push is the only way the rider learns.
func assertRiderToldNoDriver(t *testing.T, riderConn *websocket.Conn, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		msg, err := testutil.TryReadWSMessage(riderConn, time.Until(deadline))
		if err != nil {
			t.Fatalf("websocket read failed: %v", err)
		}
		if msg == nil {
			break // read timed out with no further message
		}
		if msg["type"] != "ride.updated" {
			continue // skip the "pending" push from ride creation
		}
		data, ok := msg["data"].(map[string]interface{})
		if !ok {
			continue
		}
		if data["status"] == "no_driver_available" {
			return
		}
	}
	t.Errorf("rider was never told no_driver_available within %s", within)
}

// TestOfferReachesDriverWhenOnlineAndLocated is the happy path: a driver who is
// online, has pushed a fresh fix, and holds a live socket receives the offer.
func TestOfferReachesDriverWhenOnlineAndLocated(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 901
	riderToken := strictRider(t, srv, seed)
	driverToken := strictDriver(t, srv, seed)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)

	// Driver is online and broadcasting a fresh location.
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
	parseJSON(t, createResp.Body, &created)

	msg, err := testutil.TryReadWSMessage(driverConn, 5*time.Second)
	if err != nil || msg == nil {
		t.Fatalf("expected a ride.offer within 5s, got nothing (err=%v)", err)
	}
	if msg["type"] != "ride.offer" {
		t.Fatalf("expected ride.offer, got %v", msg["type"])
	}
	data, ok := msg["data"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected offer data object, got %T", msg["data"])
	}
	if data["ride_id"] != created.Ride.ID {
		t.Errorf("expected offer for ride %s, got %v", created.Ride.ID, data["ride_id"])
	}
}

// TestNoOfferWhenDriverNeverPushedLocation is the primary regression guard for
// the reported bug. Toggling online does not create a driver_positions row —
// the row only appears when a GPS fix is pushed. A driver who is online but
// has never emitted a fix is therefore invisible to dispatch, and the rider's
// ride ends up no_driver_available with the driver never notified.
//
// This is the state the driver app lands in whenever the position stream is
// silent (geolocation denied in the browser, or a parked driver under the 10 m
// distanceFilter), because LocationService pushes only on a new fix.
func TestNoOfferWhenDriverNeverPushedLocation(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 902
	riderToken := strictRider(t, srv, seed)
	driverToken := strictDriver(t, srv, seed)

	// Online, but no PUT /geo/driver/location ever happens.
	srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)

	driverConn := srv.DialWS(t, driverToken)
	defer func() { _ = driverConn.Close() }()
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

	pickupLat, pickupLng, dropoffLat, dropoffLng, _, _ := offerCoords(seed)
	createResp := srv.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	waitForNoOffer(t, driverConn, 2*time.Second)

	// The ride must be closed out rather than left pending forever, so the
	// rider gets a definite answer.
	assertRiderToldNoDriver(t, riderConn, 8*time.Second)
}

// TestNoOfferWhenDriverLocationIsStale pins the 30-second liveness window.
// updated_at > NOW() - INTERVAL '30 seconds' is the only real gate on a
// driver's dispatchability (MarkStaleDriversOffline is dead code — nothing
// calls it), so a driver who stops moving stops receiving offers even while
// their profile still says "online".
func TestNoOfferWhenDriverLocationIsStale(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 903
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
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

	// The driver's last fix ages past the 30s window — a parked driver whose
	// geolocator stream went quiet.
	srv.GeoRepo.AgeDriverPosition(driverIDOf(t, srv, driverToken), 45*time.Second)

	createResp := srv.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	waitForNoOffer(t, driverConn, 2*time.Second)
	assertRiderToldNoDriver(t, riderConn, 8*time.Second)
}

// TestNoOfferWhenDriverSocketIsDown pins the hub's IsConnected gate. A driver
// with a fresh location but no live socket is skipped silently after 100 ms.
func TestNoOfferWhenDriverSocketIsDown(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 904
	riderToken := strictRider(t, srv, seed)
	driverToken := strictDriver(t, srv, seed)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)

	srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	// Deliberately no DialWS: the driver is online and located but offline
	// from the hub.

	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

	createResp := srv.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	// The rider is told nobody is available instead of waiting indefinitely.
	assertRiderToldNoDriver(t, riderConn, 8*time.Second)
}

// TestOfferIsNotFabricatedForUnknownDrivers guards the mock itself: with
// FabricateNearbyDriver off, an empty service area must yield an empty result
// set. If this regresses, every test in this file silently stops testing the
// real dispatch path.
func TestOfferIsNotFabricatedForUnknownDrivers(t *testing.T) {
	repo := testutil.NewStrictMockGeoRepo()
	drivers, err := repo.FindNearbyDrivers(40.7128, -74.0060, 10000, 5)
	if err != nil {
		t.Fatalf("FindNearbyDrivers: %v", err)
	}
	if len(drivers) != 0 {
		t.Fatalf("strict geo repo fabricated %d driver(s) with an empty service area", len(drivers))
	}

	// Sanity check that the lenient repo still fabricates, so the two modes
	// cannot be silently conflated.
	lenient := testutil.NewMockGeoRepo()
	drivers, err = lenient.FindNearbyDrivers(40.7128, -74.0060, 10000, 5)
	if err != nil {
		t.Fatalf("FindNearbyDrivers: %v", err)
	}
	if len(drivers) != 1 {
		t.Fatalf("expected the lenient repo to fabricate 1 driver, got %d", len(drivers))
	}
}
