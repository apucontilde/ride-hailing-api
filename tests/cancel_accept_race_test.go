package tests

import (
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
	"ride-hailing-api/tests/testutil"
)

// These tests pin the HTTP/wire half of
// api_plans/[rides]_cancel_accept_race.md: cancel authorization/status maps,
// the accept funnel's 404/409/422 map, and the canonical WS frames.

// startOfferedRide builds a strict server ride that has reached the driver's
// live offer, returning live sockets for both parties.
func startOfferedRide(t *testing.T, srv *testutil.TestServer, seed int) (riderToken, driverToken, rideID string, riderConn, driverConn *websocket.Conn) {
	t.Helper()
	riderToken = strictRider(t, srv, seed)
	driverToken = strictDriver(t, srv, seed)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)
	srv.DoRequest("PUT", "/api/v1/driver/me/status", driverToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	riderConn = srv.DialWS(t, riderToken)
	t.Cleanup(func() { _ = riderConn.Close() })
	driverConn = srv.DialWS(t, driverToken)
	t.Cleanup(func() { _ = driverConn.Close() })

	createResp := srv.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	createResp.AssertStatus(t, http.StatusCreated)
	var created struct {
		Ride struct{ ID string } `json:"ride"`
	}
	testutil.ParseJSON(t, createResp.Body, &created)
	rideID = created.Ride.ID

	// Rider sees pending, driver sees the offer.
	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" {
		t.Fatalf("expected rider ride.updated pending, got %v", msg["type"])
	}
	offer := testutil.ReadWSMessage(t, driverConn)
	if offer["type"] != "ride.offer" {
		t.Fatalf("expected ride.offer, got %v", offer["type"])
	}
	return riderToken, driverToken, rideID, riderConn, driverConn
}

// readUntilType drains frames until one of typ arrives (skipping earlier
// frames such as ride.offer_closed).
func readUntilType(t *testing.T, conn *websocket.Conn, typ string, timeout time.Duration) map[string]interface{} {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		msg, err := testutil.TryReadWSMessage(conn, time.Until(deadline))
		if err != nil {
			t.Fatalf("websocket error waiting for %s: %v", typ, err)
		}
		if msg == nil {
			break
		}
		if msg["type"] == typ {
			return msg
		}
	}
	t.Fatalf("no %s frame within %s", typ, timeout)
	return nil
}

// createCancelRide books a ride on the shared server and returns its id. The
// unique seed keeps unrelated online drivers outside the dispatch radius.
func createCancelRide(t *testing.T, token string, seed int) string {
	t.Helper()
	pickupLat, pickupLng, dropoffLat, dropoffLng, _, _ := lifeCoords(t, seed)
	resp := ts.DoRequest("POST", "/api/v1/rides", token, map[string]float64{
		"pickup_lat": pickupLat, "pickup_lng": pickupLng,
		"dropoff_lat": dropoffLat, "dropoff_lng": dropoffLng,
	})
	resp.AssertStatus(t, http.StatusCreated)
	var created struct {
		Ride struct{ ID string } `json:"ride"`
	}
	testutil.ParseJSON(t, resp.Body, &created)
	return created.Ride.ID
}

func TestCancelRideHandlerMalformedID422(t *testing.T) {
	rider := registerAndLogin(t, "rider.cancelbad@test.com", "+1200098001")
	resp := ts.DoRequest("POST", "/api/v1/rides/not-a-uuid/cancel", rider, nil)
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
	resp.AssertJSONHas(t, "error.code", "VALIDATION_ERROR")
}

func TestCancelRideHandlerOwnership404(t *testing.T) {
	owner := registerAndLogin(t, "rider.cancelowner@test.com", "+1200098002")
	other := registerAndLogin(t, "rider.cancelother@test.com", "+1200098003")
	driver := registerDriver(t, "driver.cancelother@test.com", "+1200098004")

	rideID := createCancelRide(t, owner, 981)

	otherResp := ts.DoRequest("POST", "/api/v1/rides/"+rideID+"/cancel", other, nil)
	otherResp.AssertStatus(t, http.StatusNotFound)
	otherResp.AssertJSONHas(t, "error.code", "NOT_FOUND")

	// A pending ride has no driver, so no driver may cancel it.
	driverResp := ts.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/cancel", driver, nil)
	driverResp.AssertStatus(t, http.StatusNotFound)
	driverResp.AssertJSONHas(t, "error.code", "NOT_FOUND")

	// The ride must be untouched.
	after := ts.DoRequest("GET", "/api/v1/rides/"+rideID, owner, nil)
	after.AssertJSONHas(t, "ride.status", "pending")
}

func TestCancelRideHandlerTerminalIs409(t *testing.T) {
	rider := registerAndLogin(t, "rider.cancelterm@test.com", "+1200098005")
	rideID := createCancelRide(t, rider, 982)

	if ok, err := ts.RideRepo.UpdateRideStatusFrom(rideID, []string{"pending"}, "in_progress", nil); err != nil || !ok {
		t.Fatalf("seeding in_progress: (%v, %v)", ok, err)
	}

	resp := ts.DoRequest("POST", "/api/v1/rides/"+rideID+"/cancel", rider, nil)
	resp.AssertStatus(t, http.StatusConflict)
	resp.AssertJSONHas(t, "error.code", "CONFLICT")
}

func TestCancelRideHandlerRepeatIs200AndFresh(t *testing.T) {
	rider := registerAndLogin(t, "rider.cancelrepeat@test.com", "+1200098006")
	rideID := createCancelRide(t, rider, 983)

	first := ts.DoRequest("POST", "/api/v1/rides/"+rideID+"/cancel", rider, nil)
	first.AssertStatus(t, http.StatusOK)
	var body struct {
		Ride struct {
			Status      string     `json:"status"`
			CancelledAt *time.Time `json:"cancelled_at"`
			CreatedAt   time.Time  `json:"created_at"`
			UpdatedAt   time.Time  `json:"updated_at"`
		} `json:"ride"`
	}
	testutil.ParseJSON(t, first.Body, &body)
	if body.Ride.Status != "cancelled" {
		t.Errorf("status = %q, want cancelled", body.Ride.Status)
	}
	if body.Ride.CancelledAt == nil {
		t.Error("cancelled_at is null in the first cancel response")
	}
	if !body.Ride.UpdatedAt.After(body.Ride.CreatedAt) {
		t.Errorf("updated_at = %s, want it moved past created_at %s", body.Ride.UpdatedAt, body.Ride.CreatedAt)
	}
	firstCancelledAt := body.Ride.CancelledAt

	second := ts.DoRequest("POST", "/api/v1/rides/"+rideID+"/cancel", rider, nil)
	second.AssertStatus(t, http.StatusOK)
	testutil.ParseJSON(t, second.Body, &body)
	if body.Ride.Status != "cancelled" {
		t.Errorf("repeat status = %q, want cancelled", body.Ride.Status)
	}
	if body.Ride.CancelledAt == nil || !body.Ride.CancelledAt.Equal(*firstCancelledAt) {
		t.Errorf("repeat cancelled_at = %v, want the original %v (no second write)", body.Ride.CancelledAt, firstCancelledAt)
	}
}

func TestAcceptRideHandlerMalformedID422(t *testing.T) {
	driver := registerDriver(t, "driver.acceptbad@test.com", "+1200098007")
	resp := ts.DoRequest("POST", "/api/v1/driver/rides/not-a-uuid/accept", driver, nil)
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
	resp.AssertJSONHas(t, "error.code", "VALIDATION_ERROR")
}

func TestAcceptRideHandlerNoOffer404(t *testing.T) {
	driver := registerDriver(t, "driver.acceptnone@test.com", "+1200098008")
	resp := ts.DoRequest("POST",
		"/api/v1/driver/rides/00000000-0000-0000-0000-000000000000/accept", driver, nil)
	resp.AssertStatus(t, http.StatusNotFound)
	resp.AssertJSONHas(t, "error.code", "NOT_FOUND")
}

func TestAcceptRideHandlerRideNotPending409(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	_, driverToken, rideID, _, _ := startOfferedRide(t, srv, 984)

	// Bypass the cancel endpoint so the parked offer stays actionable while the
	// row leaves pending — the accept write then loses on status.
	if ok, err := srv.RideRepo.UpdateRideStatusFrom(rideID, []string{"pending"}, "cancelled", nil); err != nil || !ok {
		t.Fatalf("seeding cancelled: (%v, %v)", ok, err)
	}

	resp := srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil)
	resp.AssertStatus(t, http.StatusConflict)
	resp.AssertJSONHas(t, "error.code", "CONFLICT")
}

// TestAcceptRideHandlerWrappedConflict409 feeds the handler the PRODUCTION
// error shape (repository.ErrConflict wrapped by AssignDriver) and requires a
// 409 classified with errors.Is, never a 400/500.
func TestAcceptRideHandlerWrappedConflict409(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	_, driverToken, rideID, _, _ := startOfferedRide(t, srv, 985)
	srv.RideRepo.SetFailNext(fmt.Errorf("accept ride: %w", repository.ErrConflict))

	resp := srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil)
	resp.AssertStatus(t, http.StatusConflict)
	resp.AssertJSONHas(t, "error.code", "CONFLICT")
}

func TestAcceptRideHandlerSuccessOnlyAfterCommit(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	_, driverToken, rideID, _, _ := startOfferedRide(t, srv, 986)

	resp := srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)

	// The row is committed as accepted with this driver assigned.
	after := srv.DoRequest("GET", "/api/v1/driver/rides/"+rideID, driverToken, nil)
	after.AssertStatus(t, http.StatusOK)
	after.AssertJSONHas(t, "ride.status", "accepted")
	var body struct {
		Ride struct {
			DriverID *string `json:"driver_id"`
		} `json:"ride"`
	}
	testutil.ParseJSON(t, after.Body, &body)
	if body.Ride.DriverID == nil {
		t.Error("driver_id is null after a 200 accept")
	}
}

func TestWSAcceptFailedFrameOnExpiredOffer(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	_, driverToken, rideID, _, driverConn := startOfferedRide(t, srv, 987)

	// Decline closes the live offer; a later WS accept must report
	// OFFER_EXPIRED, never a false success.
	srv.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/decline", driverToken, nil).
		AssertStatus(t, http.StatusOK)
	if err := driverConn.WriteJSON(map[string]interface{}{
		"type": "ride.accept", "data": map[string]string{"ride_id": rideID},
	}); err != nil {
		t.Fatalf("send ride.accept: %v", err)
	}

	msg := readUntilType(t, driverConn, "ride.accept_failed", 3*time.Second)
	data := msg["data"].(map[string]interface{})
	if data["code"] != "OFFER_EXPIRED" {
		t.Errorf("code = %v, want OFFER_EXPIRED", data["code"])
	}
	if data["ride_id"] != rideID {
		t.Errorf("ride_id = %v, want %s", data["ride_id"], rideID)
	}
	if data["message"] == "" {
		t.Error("message is empty; a fixed public sentence is required")
	}
}

func TestWSAcceptFailedFrameNotOffered(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	const seed = 988
	riderToken := strictRider(t, srv, seed)
	// Only the offered driver is located inside the search radius. The other
	// driver holds a live socket but is never a candidate, so the ownership
	// check — not search order — is what this test exercises.
	offeredToken := strictDriver(t, srv, seed)
	otherToken := strictDriver(t, srv, seed+10)

	pickupLat, pickupLng, dropoffLat, dropoffLng, driverLat, driverLng := offerCoords(seed)
	srv.DoRequest("PUT", "/api/v1/driver/me/status", offeredToken,
		map[string]string{"status": "online"}).AssertStatus(t, http.StatusOK)
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", offeredToken, map[string]float64{
		"lat": driverLat, "lng": driverLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	offeredConn := srv.DialWS(t, offeredToken)
	defer func() { _ = offeredConn.Close() }()
	otherConn := srv.DialWS(t, otherToken)
	defer func() { _ = otherConn.Close() }()
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

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

	offer := testutil.ReadWSMessage(t, offeredConn)
	if offer["type"] != "ride.offer" {
		t.Fatalf("expected the located driver to receive ride.offer, got %v", offer["type"])
	}

	if err := otherConn.WriteJSON(map[string]interface{}{
		"type": "ride.accept", "data": map[string]string{"ride_id": rideID},
	}); err != nil {
		t.Fatalf("send ride.accept: %v", err)
	}
	failure := readUntilType(t, otherConn, "ride.accept_failed", 3*time.Second)
	data := failure["data"].(map[string]interface{})
	if data["code"] != "NOT_OFFERED" {
		t.Errorf("code = %v, want NOT_OFFERED", data["code"])
	}
}

func TestWSAcceptFailedFrameRideNotPending(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	_, _, rideID, _, driverConn := startOfferedRide(t, srv, 989)
	// Leave the parked offer alone; only the ride row leaves pending.
	if ok, err := srv.RideRepo.UpdateRideStatusFrom(rideID, []string{"pending"}, "cancelled", nil); err != nil || !ok {
		t.Fatalf("seeding cancelled: (%v, %v)", ok, err)
	}

	if err := driverConn.WriteJSON(map[string]interface{}{
		"type": "ride.accept", "data": map[string]string{"ride_id": rideID},
	}); err != nil {
		t.Fatalf("send ride.accept: %v", err)
	}
	msg := readUntilType(t, driverConn, "ride.accept_failed", 3*time.Second)
	data := msg["data"].(map[string]interface{})
	if data["code"] != "RIDE_NOT_PENDING" {
		t.Errorf("code = %v, want RIDE_NOT_PENDING", data["code"])
	}
}

func TestWSOfferClosedAndCancelReachOfferedDriver(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	riderToken, _, rideID, _, driverConn := startOfferedRide(t, srv, 990)
	// The driver has only an offer: ride.driver_id is NULL.
	resp := srv.DoRequest("POST", "/api/v1/rides/"+rideID+"/cancel", riderToken, nil)
	resp.AssertStatus(t, http.StatusOK)

	closed := readUntilType(t, driverConn, "ride.offer_closed", 3*time.Second)
	closedData := closed["data"].(map[string]interface{})
	if closedData["reason"] != "cancelled" {
		t.Errorf("offer_closed reason = %v, want cancelled", closedData["reason"])
	}
	if closedData["ride_id"] != rideID {
		t.Errorf("offer_closed ride_id = %v, want %s", closedData["ride_id"], rideID)
	}

	update := readUntilType(t, driverConn, "ride.updated", 3*time.Second)
	data := update["data"].(map[string]interface{})
	if data["status"] != "cancelled" {
		t.Errorf("status = %v, want cancelled", data["status"])
	}
	if data["cancelled_by"] != "rider" {
		t.Errorf("cancelled_by = %v, want rider", data["cancelled_by"])
	}
}

// TestWSOfferClosedOnTimeout pins the wire frame when an offer is delivered
// and never answered: the driver's real WebSocket receives exactly one
// ride.offer_closed with reason "expired". The wait is shrunk via the
// service's test hook; production keeps the 30 s window.
func TestWSOfferClosedOnTimeout(t *testing.T) {
	srv := testutil.NewStrictTestServer(t)
	if srv == nil {
		return
	}
	defer srv.Close()

	restore := service.SetOfferTimeoutForTest(150 * time.Millisecond)
	defer restore()

	_, _, rideID, _, driverConn := startOfferedRide(t, srv, 991)

	closed := readUntilType(t, driverConn, "ride.offer_closed", 3*time.Second)
	data := closed["data"].(map[string]interface{})
	if data["reason"] != "expired" {
		t.Errorf("offer_closed reason = %v, want expired", data["reason"])
	}
	if data["ride_id"] != rideID {
		t.Errorf("offer_closed ride_id = %v, want %s", data["ride_id"], rideID)
	}

	// The offer is claimed by the timeout, so a late WS accept must fail as
	// OFFER_EXPIRED rather than falsely succeed.
	if err := driverConn.WriteJSON(map[string]interface{}{
		"type": "ride.accept", "data": map[string]string{"ride_id": rideID},
	}); err != nil {
		t.Fatalf("send ride.accept: %v", err)
	}
	failure := readUntilType(t, driverConn, "ride.accept_failed", 3*time.Second)
	failureData := failure["data"].(map[string]interface{})
	if failureData["code"] != "OFFER_EXPIRED" {
		t.Errorf("accept_failed code = %v, want OFFER_EXPIRED", failureData["code"])
	}
}
