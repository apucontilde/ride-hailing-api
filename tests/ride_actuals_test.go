package tests

import (
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"ride-hailing-api/tests/testutil"
)

// advanceTo walks a ride to each status in order over the driver endpoint. The
// caller drains the rider's ride.updated messages separately.
func advanceTo(t *testing.T, driverToken, rideID string, statuses ...string) {
	t.Helper()
	for _, status := range statuses {
		ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken, map[string]string{
			"status": status,
		}).AssertStatus(t, http.StatusOK)
	}
}

// readCompletedUpdate drains the rider socket until the completed ride.updated
// arrives, returning its data. It tolerates interleaved driver.location events
// from the same ride.
func readCompletedUpdate(t *testing.T, riderConn *websocket.Conn, rideID string) map[string]interface{} {
	t.Helper()
	for i := 0; i < 20; i++ {
		msg := testutil.ReadWSMessage(t, riderConn)
		if msg["type"] != "ride.updated" {
			continue
		}
		data, _ := msg["data"].(map[string]interface{})
		if data["ride_id"] == rideID && data["status"] == "completed" {
			return data
		}
	}
	t.Fatal("never observed the completed ride.updated")
	return nil
}

// TestRideActualsPersistOnCompletion pins that a completed ride stores
// actual_duration_s from its timestamps and actual_distance_m summed from the
// in_progress trace, exposed both on the completion WS payload and the ride
// JSON.
func TestRideActualsPersistOnCompletion(t *testing.T) {
	riderConn, riderToken, driverToken, rideID, _ := setupAcceptedRide(t, 950)

	advanceTo(t, driverToken, rideID, "driver_arrived", "in_progress")
	// Drain the two ride.updated notifications produced above.
	testutil.ReadWSMessage(t, riderConn)
	testutil.ReadWSMessage(t, riderConn)

	// Seed a synthetic trace with CONTROLLED timestamps. The live geo endpoint
	// stamps fixes at receive time, which in a test is milliseconds apart and
	// would be gated as a teleport; seeding directly pins the summation without
	// racing the clock. ~11.1 m per second at latitude 40.
	base := time.Now().Add(-10 * time.Second)
	for i, lat := range []float64{40.0, 40.0001, 40.0002} {
		if err := ts.RideRepo.InsertRideTrackPoint(rideID, lat, -74.0, base.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatalf("seed track point: %v", err)
		}
	}

	advanceTo(t, driverToken, rideID, "completed")
	completed := readCompletedUpdate(t, riderConn, rideID)

	if _, ok := completed["actual_duration_s"]; !ok {
		t.Error("completed payload missing actual_duration_s")
	}
	d, ok := completed["actual_distance_m"].(float64)
	if !ok || d < 20 || d > 40 {
		t.Errorf("completed actual_distance_m = %v, want ~22 m from the trace", completed["actual_distance_m"])
	}

	// The read path carries the same additive fields (never a separate write).
	getResp := ts.DoRequest("GET", "/api/v1/rides/"+rideID, riderToken, nil)
	getResp.AssertStatus(t, http.StatusOK)
	getResp.AssertJSONHas(t, "ride.actual_duration_s")
	getResp.AssertJSONHas(t, "ride.actual_distance_m")
}

// TestRideActualsNullWithoutTrace pins the no-fabrication contract: a ride with
// no usable trace leaves actual_distance_m NULL (duration is still derivable
// from the timestamps).
func TestRideActualsNullWithoutTrace(t *testing.T) {
	riderConn, riderToken, driverToken, rideID, _ := setupAcceptedRide(t, 951)

	advanceTo(t, driverToken, rideID, "driver_arrived", "in_progress")
	testutil.ReadWSMessage(t, riderConn)
	testutil.ReadWSMessage(t, riderConn)

	advanceTo(t, driverToken, rideID, "completed")
	readCompletedUpdate(t, riderConn, rideID)

	getResp := ts.DoRequest("GET", "/api/v1/rides/"+rideID, riderToken, nil)
	getResp.AssertStatus(t, http.StatusOK)
	// Key present, value null: an unusable trace is never a fabricated 0.
	getResp.AssertJSONHas(t, "ride.actual_distance_m", nil)
	getResp.AssertJSONHas(t, "ride.actual_duration_s")
}

// TestDriverLocationRecordsTrackPointOnlyInProgress pins the endpoint seam: a
// fix is recorded for the trace only while the ride is in_progress, and the
// endpoint stays a 204 even though it now appends to the trace.
func TestDriverLocationRecordsTrackPointOnlyInProgress(t *testing.T) {
	riderConn, _, driverToken, rideID, _ := setupAcceptedRide(t, 952)

	advanceTo(t, driverToken, rideID, "driver_arrived", "in_progress")
	testutil.ReadWSMessage(t, riderConn)
	testutil.ReadWSMessage(t, riderConn)

	ts.DoRequest("PUT", "/api/v1/geo/driver/location", driverToken, map[string]float64{
		"lat": 40.7130, "lng": -74.0060, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	points, err := ts.RideRepo.FindRideTrackPoints(rideID)
	if err != nil {
		t.Fatalf("FindRideTrackPoints: %v", err)
	}
	if len(points) != 1 {
		t.Fatalf("track points = %d, want 1 recorded while in_progress", len(points))
	}
}
