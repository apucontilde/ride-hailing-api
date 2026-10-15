package handler_test

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	gorillaws "github.com/gorilla/websocket"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/handler"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
	"ride-hailing-api/internal/websocket"
	"ride-hailing-api/tests/testutil"
)

// Handler-level proofs for
// api_plans/[arrival]_proximity_arrival_geofence.md: the geo hot path runs the
// geofence, fills the additive driver.location fields, and never fails the
// location update when the ride lookup or the evaluator does. The service rules
// live in internal/service/arrival_test.go; the full router wiring and push
// delivery live in tests/arrival_geofence_test.go.
//
// This is an external test package (handler_test) so it can import the
// tests/testutil mock repositories without creating an import cycle.

const (
	geoPickupLat = 40.7
	geoPickupLng = -74.0
)

func geoFixAt(d float64) (lat, lng float64) {
	return geoPickupLat + d/111195.0, geoPickupLng
}

type geoRig struct {
	srv      *httptest.Server
	rideRepo *testutil.MockRideRepo
	ride     *model.Ride
}

func newGeoRig(t *testing.T) *geoRig {
	t.Helper()
	gin.SetMode(gin.TestMode)

	riderID, driverID := "rider-geo", "driver-geo"
	rideRepo := testutil.NewMockRideRepo()
	geoRepo := testutil.NewMockGeoRepo()
	hub := websocket.NewHub()

	ride := &model.Ride{
		RiderID:    riderID,
		DriverID:   &driverID,
		PickupLat:  geoPickupLat,
		PickupLng:  geoPickupLng,
		DropoffLat: 40.8,
		DropoffLng: -73.9,
	}
	if err := rideRepo.CreateRide(ride); err != nil {
		t.Fatalf("seed ride: %v", err)
	}
	if err := rideRepo.AssignDriver(ride.ID, driverID); err != nil {
		t.Fatalf("assign driver: %v", err)
	}

	rideSvc := service.NewRideService(rideRepo, nil, hub, nil)
	rideSvc.SetArrivalGeofence(config.Load().Arrival)
	h := handler.NewGeoHandler(geoRepo, rideRepo, hub, rideSvc)

	inject := func(userID, role string) gin.HandlerFunc {
		return func(c *gin.Context) {
			c.Set("user_id", userID)
			c.Set("role", role)
			c.Next()
		}
	}

	r := gin.New()
	r.PUT("/api/v1/geo/driver/location", inject(driverID, "driver"), h.UpdateDriverLocation)
	r.PUT("/api/v1/geo/driver/location/batch", inject(driverID, "driver"), h.UpdateDriverLocationBatch)
	r.PUT("/api/v1/geo/driver/location/noride", inject("driver-noride", "driver"), h.UpdateDriverLocation)
	r.GET("/ws/rider", inject(riderID, "rider"), hub.HandleWS)

	return &geoRig{
		srv:      httptest.NewServer(r),
		rideRepo: rideRepo,
		ride:     ride,
	}
}

func (g *geoRig) close() { g.srv.Close() }

func (g *geoRig) put(t *testing.T, path string, body interface{}) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodPut, g.srv.URL+path, jsonBody(t, body))
	if err != nil {
		t.Fatalf("build PUT %s: %v", path, err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PUT %s: %v", path, err)
	}
	defer func() { _ = resp.Body.Close() }()
	return resp.StatusCode
}

// jsonBody marshals body into an io.Reader for the request body.
func jsonBody(t *testing.T, body interface{}) *strings.Reader {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	return strings.NewReader(string(b))
}

func (g *geoRig) status(t *testing.T) string {
	t.Helper()
	ride, err := g.rideRepo.FindByID(g.ride.ID)
	if err != nil {
		t.Fatalf("reload ride: %v", err)
	}
	return ride.Status
}

// dialRider connects a rider WebSocket and waits until the hub registered it.
func (g *geoRig) dialRider(t *testing.T) *gorillaws.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(g.srv.URL, "http") + "/ws/rider"
	conn, _, err := gorillaws.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	if err := conn.WriteJSON(map[string]string{"type": "ping"}); err != nil {
		t.Fatalf("readiness ping: %v", err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	for {
		_, b, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("readiness read: %v", err)
		}
		var m map[string]interface{}
		if json.Unmarshal(b, &m) == nil && m["type"] == "pong" {
			return conn
		}
	}
}

// TestGeoArrivalFixAdvancesAndCarriesFields: a fix inside the arrive gate
// answers 204, transitions the ride, and carries the proximity fields on the
// driver.location event.
func TestGeoArrivalFixAdvancesAndCarriesFields(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()
	conn := rig.dialRider(t)
	defer func() { _ = conn.Close() }()

	lat, lng := geoFixAt(55)
	if code := rig.put(t, "/api/v1/geo/driver/location", map[string]float64{"lat": lat, "lng": lng}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}

	upd := testutil.ReadWSMessage(t, conn)
	if upd["type"] != "ride.updated" || upd["data"].(map[string]interface{})["status"] != "driver_arrived" {
		t.Fatalf("first message = %+v, want ride.updated driver_arrived", upd)
	}
	loc := testutil.ReadWSMessage(t, conn)
	if loc["type"] != "driver.location" {
		t.Fatalf("second message = %v, want driver.location", loc["type"])
	}
	data := loc["data"].(map[string]interface{})
	if data["near_pickup"] != true {
		t.Errorf("near_pickup = %v, want true", data["near_pickup"])
	}
	if _, ok := data["distance_to_pickup_m"].(float64); !ok {
		t.Errorf("distance_to_pickup_m missing: %+v", data)
	}
	if got := rig.status(t); got != "driver_arrived" {
		t.Fatalf("status = %q, want driver_arrived", got)
	}
}

// TestGeoNearFixCarriesNearNoTransition: a fix in 80–300 m sets near_pickup but
// changes no status and emits no ride.updated.
func TestGeoNearFixCarriesNearNoTransition(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()
	conn := rig.dialRider(t)
	defer func() { _ = conn.Close() }()

	lat, lng := geoFixAt(222)
	if code := rig.put(t, "/api/v1/geo/driver/location", map[string]float64{"lat": lat, "lng": lng}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}

	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "driver.location" {
		t.Fatalf("message type = %v, want driver.location", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["near_pickup"] != true {
		t.Errorf("near_pickup = %v, want true at ~222 m", data["near_pickup"])
	}
	if got := rig.status(t); got != "accepted" {
		t.Fatalf("status = %q, want accepted (nearby never transitions)", got)
	}
	if extra, _ := testutil.TryReadWSMessage(conn, 200*time.Millisecond); extra != nil {
		t.Fatalf("unexpected extra message: %+v", extra)
	}
}

// TestGeoFarFixCarriesDistanceNoNear: a fix past the nearby radius carries the
// distance but omits near_pickup.
func TestGeoFarFixCarriesDistanceNoNear(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()
	conn := rig.dialRider(t)
	defer func() { _ = conn.Close() }()

	lat, lng := geoFixAt(556)
	if code := rig.put(t, "/api/v1/geo/driver/location", map[string]float64{"lat": lat, "lng": lng}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}

	msg := testutil.ReadWSMessage(t, conn)
	data := msg["data"].(map[string]interface{})
	if _, ok := data["near_pickup"]; ok {
		t.Errorf("near_pickup present (%v) past the nearby radius, want omitted", data["near_pickup"])
	}
	if _, ok := data["distance_to_pickup_m"].(float64); !ok {
		t.Errorf("distance_to_pickup_m missing on an accepted ride: %+v", data)
	}
}

// TestGeoNoActiveRideIsLegacy204: a driver with no active ride gets the legacy
// driver.location shape — actually, no event at all (there is no ride/rider).
func TestGeoNoActiveRideIsLegacy204(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()

	lat, lng := geoFixAt(55)
	if code := rig.put(t, "/api/v1/geo/driver/location/noride", map[string]float64{"lat": lat, "lng": lng}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}
	if got := rig.status(t); got != "accepted" {
		t.Fatalf("status = %q; a no-ride driver must not touch the seeded ride", got)
	}
}

// TestGeoFailedRideLookupIs204NoTransition: a failed FindCurrentRideByDriver
// must be swallowed and must never fabricate an arrival. Plan §2.5 tightens the
// logging contract: a benign ErrNotFound (no active ride) is silent, but any
// OTHER repo error is logged before the geofence is skipped.
func TestGeoFailedRideLookupIs204NoTransition(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()

	// Capture the handler's log output for this test only. This package's tests
	// are sequential (no t.Parallel), and each package is its own test process,
	// so swapping the global logger is safe here.
	var buf strings.Builder
	prevWriter := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prevWriter)

	lat, lng := geoFixAt(55)

	// A non-ErrNotFound outage: 204, no fabricated arrival, and LOGGED.
	rig.rideRepo.SetFailNext(errors.New("db down"))
	if code := rig.put(t, "/api/v1/geo/driver/location", map[string]float64{"lat": lat, "lng": lng}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 (a lookup outage must not change the endpoint contract)", code)
	}
	if got := rig.status(t); got != "accepted" {
		t.Fatalf("status = %q, want accepted (no fabricated arrival)", got)
	}
	if logged := buf.String(); !strings.Contains(logged, "failed to load active ride") || !strings.Contains(logged, "db down") {
		t.Fatalf("non-ErrNotFound lookup failure was not logged (plan §2.5); log = %q", logged)
	}

	// A benign ErrNotFound (no active ride) is silent and still 204/no advance.
	buf.Reset()
	rig.rideRepo.SetFailNext(repository.ErrNotFound)
	if code := rig.put(t, "/api/v1/geo/driver/location", map[string]float64{"lat": lat, "lng": lng}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 for a benign ErrNotFound", code)
	}
	if got := rig.status(t); got != "accepted" {
		t.Fatalf("status = %q, want accepted for ErrNotFound", got)
	}
	if logged := buf.String(); strings.Contains(logged, "failed to load active ride") {
		t.Fatalf("ErrNotFound must be silent; log = %q", logged)
	}
}

// TestGeoBatchEvaluatesFinalFixOnly: only the batch's final fix runs the
// geofence; an intermediate fix inside the arrive gate does not, and the final
// fix emits exactly one driver.location.
func TestGeoBatchEvaluatesFinalFixOnly(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()
	conn := rig.dialRider(t)
	defer func() { _ = conn.Close() }()

	insideLat, _ := geoFixAt(55)
	farLat, farLng := geoFixAt(556)

	// Intermediate inside the gate, final far away: nothing may advance.
	if code := rig.put(t, "/api/v1/geo/driver/location/batch", []map[string]float64{
		{"lat": insideLat, "lng": geoPickupLng},
		{"lat": farLat, "lng": farLng},
	}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}
	if got := rig.status(t); got != "accepted" {
		t.Fatalf("status = %q; the intermediate batch fix must not advance", got)
	}
	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "driver.location" {
		t.Fatalf("message type = %v, want one driver.location for the final fix", msg["type"])
	}
	if lat := msg["data"].(map[string]interface{})["lat"]; lat != farLat {
		t.Fatalf("driver.location lat = %v, want the final fix %v", lat, farLat)
	}
	// No second event (this negative read is last: a gorilla read timeout
	// corrupts the connection for any further read).
	if extra, _ := testutil.TryReadWSMessage(conn, 200*time.Millisecond); extra != nil {
		t.Fatalf("more than one driver.location emitted: %+v", extra)
	}
}

// TestGeoBatchFinalFixAdvances: a batch whose final fix is inside the gate
// advances the ride exactly once.
func TestGeoBatchFinalFixAdvances(t *testing.T) {
	rig := newGeoRig(t)
	defer rig.close()
	conn := rig.dialRider(t)
	defer func() { _ = conn.Close() }()

	insideLat, _ := geoFixAt(55)
	farLat, farLng := geoFixAt(556)

	if code := rig.put(t, "/api/v1/geo/driver/location/batch", []map[string]float64{
		{"lat": farLat, "lng": farLng},
		{"lat": insideLat, "lng": geoPickupLng},
	}); code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", code)
	}
	upd := testutil.ReadWSMessage(t, conn)
	if upd["type"] != "ride.updated" || upd["data"].(map[string]interface{})["status"] != "driver_arrived" {
		t.Fatalf("batch final fix = %+v, want ride.updated driver_arrived", upd)
	}
	if got := rig.status(t); got != "driver_arrived" {
		t.Fatalf("status = %q, want driver_arrived", got)
	}
}
