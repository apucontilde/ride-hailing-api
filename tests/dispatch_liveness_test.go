package tests

import (
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"ride-hailing-api/tests/testutil"
)

// putDriverStatus sets the driver's status and returns the driver user id from
// the response body. The id is read from the response rather than from the geo
// mock, because a driver who has never pushed a fix has no driver_positions
// row at all — which is precisely the state two of these tests set up.
func putDriverStatus(t *testing.T, srv *testutil.TestServer, driverToken, status string) string {
	t.Helper()
	resp := srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": status})
	resp.AssertStatus(t, http.StatusOK)

	var body struct {
		Driver struct {
			UserID string `json:"user_id"`
			Status string `json:"status"`
		} `json:"driver"`
	}
	if err := json.Unmarshal(resp.Body, &body); err != nil {
		t.Fatalf("decode status response: %v (body=%s)", err, resp.Body)
	}
	if body.Driver.Status != status {
		t.Errorf("status = %q, want %q", body.Driver.Status, status)
	}
	if body.Driver.UserID == "" {
		t.Fatal("status response carried no driver user_id")
	}
	return body.Driver.UserID
}

// onlyDriverRow returns the single seeded driver id from the geo mock, failing if
// the row is missing or ambiguous.
func onlyDriverRow(t *testing.T, srv *testutil.TestServer) string {
	t.Helper()
	ids := srv.GeoRepo.DriverIDs()
	if len(ids) != 1 {
		t.Fatalf("expected exactly 1 driver with a position row, got %d (%v)", len(ids), ids)
	}
	return ids[0]
}

// This file is the end-to-end proof for the GOING-ONLINE half of
// [dispatch]_reliability_and_no_driver_false_negative.
//
// TestNoOfferWhenDriverNeverPushedLocation (dispatch_offer_test.go) covers a
// driver who has NEVER sent a fix: there are no coordinates to dispatch to, so
// staying invisible is correct. This file covers the adjacent case that WAS the
// reported false negative — a driver with a perfectly good last known position
// whose row has simply aged past the 30s dispatch liveness window, because they
// parked. Going online again now re-arms that window from the last known
// coordinates (GeoRepository.TouchDriverPresence), so the driver is dispatchable
// again immediately instead of only after they next move.

// TestOfferToDriverWhoGoesOnlineWithoutMoving is the core regression. The
// driver pushes a fix, ages out of the liveness window, then goes online again
// while stationary. The ride must still reach them.
func TestOfferToDriverWhoGoesOnlineWithoutMoving(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 920
	riderToken := strictRider(t, srv, seed)
	driverToken := strictDriver(t, srv, seed)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)

	// The driver's last known position, then it ages past the liveness window:
	// they are parked and publishing nothing.
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	driverID := onlyDriverRow(t, srv)
	if !srv.GeoRepo.AgeDriverPresence(driverID, time.Hour) {
		t.Fatalf("driver %s has no position row to age", driverID)
	}
	age, ok := srv.GeoRepo.DriverPresenceAge(driverID)
	if !ok {
		t.Fatalf("driver %s has no position row", driverID)
	}
	if age < 30*time.Second {
		t.Fatalf("presence age = %s, want >= 30s so the driver starts outside the liveness window", age)
	}

	// The driver goes online again without moving. This must re-arm the window.
	srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)

	refreshed, hasRow := srv.GeoRepo.DriverPresenceAge(driverID)
	if !hasRow {
		t.Error("going online removed the driver's position row")
	} else if refreshed > 5*time.Second {
		t.Errorf("presence age after going online = %s, want < 5s: a status write of \"online\" must "+
			"refresh the liveness window from the last known position (the handler's check is "+
			"stateless — no offline-to-online transition is required)", refreshed)
	}

	// And the driver must now actually receive offers.
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
		t.Fatalf("expected a ride.offer within 5s for a driver who just went online, got nothing (err=%v). "+
			"A stationary just-online driver must be dispatchable from their last known position.", err)
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

// TestGoingOnlineWithoutAnyPositionIsStillNotDispatchable guards the boundary of
// the fix. TouchDriverPresence must never invent a position, so a driver who has
// NEVER sent a fix stays invisible — and the status change still succeeds, since
// "I have no coordinates" is not a client error.
//
// This pairs with TestNoOfferWhenDriverNeverPushedLocation: the two together pin
// the intended split between "aged out but locatable" (now fixed) and "never
// locatable" (still correctly invisible).
func TestGoingOnlineWithoutAnyPositionIsStillNotDispatchable(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 921
	driverToken := strictDriver(t, srv, seed)

	// Online with no fix, ever. The status change itself must still succeed:
	// "I have no coordinates" is not a client error.
	driverID := putDriverStatus(t, srv, driverToken, "online")

	if _, ok := srv.GeoRepo.DriverPresenceAge(driverID); ok {
		t.Error("going online invented a driver_positions row; the presence refresh " +
			"must only re-arm an EXISTING position and never fabricate coordinates")
	}
}

// TestGoingOfflineDoesNotTouchPresence pins the other direction of the
// handler's check: only a requested status of "online" re-arms the window, and
// the check is stateless — it never asks what the driver's previous status was.
// A driver going offline must not have their presence refreshed, or the
// liveness sweep could never reconcile them.
func TestGoingOfflineDoesNotTouchPresence(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 922
	driverToken := strictDriver(t, srv, seed)

	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": 40.7130, "lng": -74.0060, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)
	driverID := onlyDriverRow(t, srv)
	if !srv.GeoRepo.AgeDriverPresence(driverID, time.Hour) {
		t.Fatalf("driver %s has no position row", driverID)
	}

	if got := putDriverStatus(t, srv, driverToken, "offline"); got != driverID {
		t.Fatalf("user_id = %q, want %q", got, driverID)
	}

	age, ok := srv.GeoRepo.DriverPresenceAge(driverID)
	if !ok {
		t.Fatal("going offline removed the position row")
	}
	if age < 30*time.Second {
		t.Errorf("presence age after going offline = %s, want the aged value untouched: only a "+
			"requested status of \"online\" may re-arm the liveness window", age)
	}
}

// TestPresenceRefreshFailureKeepsTheStatusUpdateSucceeding pins the response
// contract for the new side effect. The driver's own status write committed, so
// the valid request must keep its 200 and unchanged body; the failed side
// effect is recorded as a gin error for the logs, never surfaced as a 5xx and
// never hidden by a fake success on a different write.
func TestPresenceRefreshFailureKeepsTheStatusUpdateSucceeding(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 923
	driverToken := strictDriver(t, srv, seed)

	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": 40.7130, "lng": -74.0060, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)
	driverID := onlyDriverRow(t, srv)

	// The next repository write fails, which lands on the presence refresh.
	srv.GeoRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"})
	resp.AssertStatus(t, http.StatusOK)

	var body struct {
		Driver struct {
			UserID string `json:"user_id"`
			Status string `json:"status"`
		} `json:"driver"`
	}
	parseJSON(t, resp.Body, &body)
	if body.Driver.Status != "online" {
		t.Errorf("status = %q, want %q", body.Driver.Status, "online")
	}
	if body.Driver.UserID != driverID {
		t.Errorf("user_id = %q, want %q: the response body shape must be unchanged", body.Driver.UserID, driverID)
	}
}
