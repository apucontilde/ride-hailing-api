package tests

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/router"
	"ride-hailing-api/internal/service/push"
	"ride-hailing-api/tests/testutil"
)

// This file is the end-to-end proof of
// api_plans/[arrival]_proximity_arrival_geofence.md. It replaces the old
// notify-arrival test (D5 removed that route): the server now owns arrival on
// the geo driver-location hot path, so the assertions live on that path.
//
// spyPushProvider is an injectable push.Provider that records every send and
// signals it on a channel, so each test can assert exactly how many pushes a
// rider received (zero while connected, exactly one while backgrounded).
type spyPushProvider struct {
	mu    sync.Mutex
	sends []spySend
	ch    chan spySend
}

type spySend struct {
	token    string
	platform string
	msg      push.Message
}

func newSpyPushProvider() *spyPushProvider {
	return &spyPushProvider{ch: make(chan spySend, 8)}
}

func (p *spyPushProvider) Send(_ context.Context, token, platform string, msg push.Message) error {
	s := spySend{token: token, platform: platform, msg: msg}
	p.mu.Lock()
	p.sends = append(p.sends, s)
	p.mu.Unlock()
	select {
	case p.ch <- s:
	default:
	}
	return nil
}

func (p *spyPushProvider) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.sends)
}

// newArrivalTestServer boots the real router with mock repos and an injected
// spy provider, so these tests observe push delivery without touching the
// shared testutil server (whose provider is the no-op default).
func newArrivalTestServer(t *testing.T, provider push.Provider) (*testutil.TestServer, *testutil.MockDeviceTokenRepo) {
	t.Helper()
	cfg := config.Load()
	cfg.RateLimitRegister = 9999
	cfg.RateLimitLogin = 9999
	cfg.RateLimitGeneral = 9999
	cfg.RateLimitRide = 9999

	userRepo := testutil.NewMockUserRepo()
	rideRepo := testutil.NewMockRideRepo()
	geoRepo := testutil.NewMockGeoRepo()
	navRepo := testutil.NewMockNavigationRepo()
	placesRepo := testutil.NewMockPlacesRepo()
	deviceRepo := testutil.NewMockDeviceTokenRepo()
	feedbackRepo := testutil.NewMockFeedbackRepo()

	r := router.SetupWithRepos(cfg, userRepo, rideRepo, geoRepo, navRepo, placesRepo, nil,
		router.WithDeviceTokenRepository(deviceRepo),
		router.WithFeedbackRepository(feedbackRepo),
		router.WithPushProvider(provider),
	)

	srv := &testutil.TestServer{
		Server:       httptest.NewServer(r),
		Config:       cfg,
		AuthTokens:   map[string]string{},
		UserRepo:     userRepo,
		RideRepo:     rideRepo,
		GeoRepo:      geoRepo,
		PlacesRepo:   placesRepo,
		DeviceRepo:   deviceRepo,
		FeedbackRepo: feedbackRepo,
	}
	t.Cleanup(srv.Close)
	return srv, deviceRepo
}

func registerOn(t *testing.T, srv *testutil.TestServer, email, phone string) (token, id string) {
	t.Helper()
	srv.PostJSON("/api/v1/auth/register", map[string]string{
		"email": email, "phone": phone, "password": "SecurePass1",
	}).AssertStatus(t, http.StatusCreated)
	return loginOn(t, srv, email)
}

func loginOn(t *testing.T, srv *testutil.TestServer, email string) (token, id string) {
	t.Helper()
	resp := srv.PostJSON("/api/v1/auth/login", map[string]string{
		"email": email, "password": "SecurePass1",
	})
	var login struct {
		AccessToken string `json:"access_token"`
		User        struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	testutil.ParseJSON(t, resp.Body, &login)
	return login.AccessToken, login.User.ID
}

func registerDriverOn(t *testing.T, srv *testutil.TestServer, email, phone string) (token, id string) {
	t.Helper()
	token, _ = registerOn(t, srv, email, phone)
	srv.DoRequest("POST", "/api/v1/driver/register", token, nil).AssertStatus(t, http.StatusCreated)
	return loginOn(t, srv, email)
}

// insertAssignedRideOn seeds a ride already assigned to driverID (status
// accepted) with a pickup far from every other test's coordinates.
func insertAssignedRideOn(t *testing.T, srv *testutil.TestServer, riderID, driverID string) *model.Ride {
	t.Helper()
	ride := &model.Ride{
		RiderID:    riderID,
		DriverID:   &driverID,
		PickupLat:  arrivalPickupLat,
		PickupLng:  arrivalPickupLng,
		DropoffLat: 40.8,
		DropoffLng: -73.9,
	}
	if err := srv.RideRepo.CreateRide(ride); err != nil {
		t.Fatalf("seed ride: %v", err)
	}
	if err := srv.RideRepo.AssignDriver(ride.ID, driverID); err != nil {
		t.Fatalf("assign driver: %v", err)
	}
	return ride
}

// The pickup is unique to this file so no other suite's drivers/rides interfere.
const (
	arrivalPickupLat = 40.7
	arrivalPickupLng = -74.0
	// Latitude offsets from the pickup, in metres: 0.0001 deg lat ≈ 11.13 m.
	arrivalFixLat = 40.7005 // ≈ 55.6 m  (inside the 80 m arrive gate)
	nearFixLat    = 40.7020 // ≈ 222.5 m (inside the 300 m nearby radius, outside arrive)
	farFixLat     = 40.7050 // ≈ 556.3 m (outside both)
)

func putLatLng(t *testing.T, srv *testutil.TestServer, token string, lat, lng float64) {
	t.Helper()
	srv.DoRequest("PUT", "/api/v1/geo/driver/location", token, map[string]float64{
		"lat": lat, "lng": lng, "heading": 0, "speed": 5,
	}).AssertStatus(t, http.StatusNoContent)
}

func rideStatus(t *testing.T, srv *testutil.TestServer, rideID string) string {
	t.Helper()
	ride, err := srv.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("reload ride: %v", err)
	}
	return ride.Status
}

// TestProximityArrivalAdvancesBothAndPersists: an accepted ride with a fix
// inside the arrive gate advances to driver_arrived, broadcasts ride.updated to
// BOTH parties, carries the proximity fields on driver.location, and never
// re-advances on the next fix.
func TestProximityArrivalAdvancesBothAndPersists(t *testing.T) {
	provider := newSpyPushProvider()
	srv, _ := newArrivalTestServer(t, provider)
	riderToken, riderID := registerOn(t, srv, "arrival.e2e.rider@test.com", "+5200000013")
	driverToken, driverID := registerDriverOn(t, srv, "arrival.e2e.driver@test.com", "+5200000014")

	ride := insertAssignedRideOn(t, srv, riderID, driverID)
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()
	driverConn := srv.DialWS(t, driverToken)
	defer func() { _ = driverConn.Close() }()

	putLatLng(t, srv, driverToken, arrivalFixLat, arrivalPickupLng)

	// Rider: ride.updated first (the geofence broadcast), then driver.location.
	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "ride.updated" {
		t.Fatalf("rider first message type = %v, want ride.updated", msg["type"])
	}
	rdata := msg["data"].(map[string]interface{})
	if rdata["status"] != "driver_arrived" || rdata["ride_id"] != ride.ID {
		t.Fatalf("rider ride.updated = %+v, want driver_arrived for %s", rdata, ride.ID)
	}

	// Driver: also gets the ride.updated (both parties).
	dmsg := testutil.ReadWSMessage(t, driverConn)
	if dmsg["type"] != "ride.updated" {
		t.Fatalf("driver message type = %v, want ride.updated", dmsg["type"])
	}
	if dmsg["data"].(map[string]interface{})["status"] != "driver_arrived" {
		t.Fatalf("driver ride.updated = %+v, want driver_arrived", dmsg["data"])
	}

	// Rider's second message: driver.location with the proximity fields.
	loc := testutil.ReadWSMessage(t, riderConn)
	if loc["type"] != "driver.location" {
		t.Fatalf("rider second message type = %v, want driver.location", loc["type"])
	}
	ldata := loc["data"].(map[string]interface{})
	if ldata["near_pickup"] != true {
		t.Errorf("driver.location.near_pickup = %v, want true on the arrival fix", ldata["near_pickup"])
	}
	if _, ok := ldata["distance_to_pickup_m"].(float64); !ok {
		t.Errorf("driver.location.distance_to_pickup_m missing on the arrival fix: %+v", ldata)
	}

	if got := rideStatus(t, srv, ride.ID); got != "driver_arrived" {
		t.Fatalf("persisted status = %q, want driver_arrived", got)
	}

	// Both sockets are live, so neither party needs a push.
	if n := provider.count(); n != 0 {
		t.Fatalf("pushes = %d, want 0 for two connected parties", n)
	}

	// Idempotent: a second fix inside the gate must NOT re-advance or re-broadcast.
	putLatLng(t, srv, driverToken, arrivalFixLat, arrivalPickupLng)
	next := testutil.ReadWSMessage(t, riderConn)
	if next["type"] != "driver.location" {
		t.Fatalf("second fix emitted %v, want only driver.location (no second transition)", next["type"])
	}
	if got := rideStatus(t, srv, ride.ID); got != "driver_arrived" {
		t.Fatalf("status after second fix = %q, want driver_arrived", got)
	}
	if n := provider.count(); n != 0 {
		t.Fatalf("pushes after second fix = %d, want 0", n)
	}
}

// TestProximityNearbyEmitsFieldOnlyForConnectedRider: a fix in the 80–300 m band
// sets near_pickup on driver.location but changes no status and sends no push
// while the rider is connected.
func TestProximityNearbyEmitsFieldOnlyForConnectedRider(t *testing.T) {
	provider := newSpyPushProvider()
	srv, _ := newArrivalTestServer(t, provider)
	riderToken, riderID := registerOn(t, srv, "arrival.near.rider@test.com", "+5200000015")
	driverToken, driverID := registerDriverOn(t, srv, "arrival.near.driver@test.com", "+5200000016")

	ride := insertAssignedRideOn(t, srv, riderID, driverID)
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

	putLatLng(t, srv, driverToken, nearFixLat, arrivalPickupLng)

	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "driver.location" {
		t.Fatalf("message type = %v, want driver.location", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["near_pickup"] != true {
		t.Errorf("near_pickup = %v, want true at ~222 m", data["near_pickup"])
	}
	if d, ok := data["distance_to_pickup_m"].(float64); !ok || d < 200 || d > 245 {
		t.Errorf("distance_to_pickup_m = %v, want ~222 m", data["distance_to_pickup_m"])
	}
	if got := rideStatus(t, srv, ride.ID); got != "accepted" {
		t.Fatalf("nearby changed status to %q; it must stay accepted", got)
	}
	// No transition ⇒ no ride.updated, and a connected rider gets no push.
	if extra, _ := testutil.TryReadWSMessage(riderConn, 250*time.Millisecond); extra != nil {
		t.Fatalf("unexpected extra WS message: %+v", extra)
	}
	if n := provider.count(); n != 0 {
		t.Fatalf("pushes = %d, want 0 for a connected rider", n)
	}
}

// TestProximityNearbyPushesBackgroundedRiderOnce: a backgrounded rider gets
// exactly one ride.nearby push on the first crossing, and none afterwards.
func TestProximityNearbyPushesBackgroundedRiderOnce(t *testing.T) {
	provider := newSpyPushProvider()
	srv, deviceRepo := newArrivalTestServer(t, provider)
	_, riderID := registerOn(t, srv, "arrival.nearbg.rider@test.com", "+5200000017")
	driverToken, driverID := registerDriverOn(t, srv, "arrival.nearbg.driver@test.com", "+5200000018")

	if _, err := deviceRepo.Register(riderID, "tok-nearbg-rider", "android"); err != nil {
		t.Fatalf("seed device token: %v", err)
	}
	insertAssignedRideOn(t, srv, riderID, driverID)

	putLatLng(t, srv, driverToken, nearFixLat, arrivalPickupLng)

	select {
	case sent := <-provider.ch:
		if sent.token != "tok-nearbg-rider" {
			t.Fatalf("push token = %q, want tok-nearbg-rider", sent.token)
		}
		if sent.msg.Data["type"] != "ride.nearby" || sent.msg.Data["status"] != "accepted" ||
			sent.msg.Data["near_pickup"] != "true" {
			t.Fatalf("nearby push data = %+v, want ride.nearby/accepted/near_pickup=true", sent.msg.Data)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no nearby push was attempted for a backgrounded rider")
	}

	// A second fix still inside the radius must not re-fire.
	putLatLng(t, srv, driverToken, nearFixLat+0.0001, arrivalPickupLng)
	time.Sleep(150 * time.Millisecond)
	if n := provider.count(); n != 1 {
		t.Fatalf("pushes = %d, want exactly 1 (one crossing)", n)
	}
}

// TestProximityArrivalPushesBackgroundedRiderOnce: a backgrounded rider gets
// exactly one driver_arrived push.
func TestProximityArrivalPushesBackgroundedRiderOnce(t *testing.T) {
	provider := newSpyPushProvider()
	srv, deviceRepo := newArrivalTestServer(t, provider)
	_, riderID := registerOn(t, srv, "arrival.arrbg.rider@test.com", "+5200000019")
	driverToken, driverID := registerDriverOn(t, srv, "arrival.arrbg.driver@test.com", "+5200000020")

	if _, err := deviceRepo.Register(riderID, "tok-arrbg-rider", "android"); err != nil {
		t.Fatalf("seed device token: %v", err)
	}
	insertAssignedRideOn(t, srv, riderID, driverID)

	putLatLng(t, srv, driverToken, arrivalFixLat, arrivalPickupLng)

	select {
	case sent := <-provider.ch:
		if sent.token != "tok-arrbg-rider" {
			t.Fatalf("push token = %q, want tok-arrbg-rider", sent.token)
		}
		if sent.msg.Data["status"] != "driver_arrived" {
			t.Fatalf("arrival push data = %+v, want driver_arrived", sent.msg.Data)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no arrival push was attempted for a backgrounded rider")
	}
	time.Sleep(150 * time.Millisecond)
	if n := provider.count(); n != 1 {
		t.Fatalf("pushes = %d, want exactly 1", n)
	}
}

// TestProximityBatchEvaluatesFinalFixOnly: the batch path evaluates the geofence
// on the FINAL fix only. An intermediate fix inside the arrive gate must not
// advance; only the final fix does, and it emits one driver.location.
func TestProximityBatchEvaluatesFinalFixOnly(t *testing.T) {
	provider := newSpyPushProvider()
	srv, _ := newArrivalTestServer(t, provider)
	riderToken, riderID := registerOn(t, srv, "arrival.batch.rider@test.com", "+5200000021")
	driverToken, driverID := registerDriverOn(t, srv, "arrival.batch.driver@test.com", "+5200000022")

	ride := insertAssignedRideOn(t, srv, riderID, driverID)
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

	// First fix inside the gate, final fix far away: only the final fix counts.
	srv.DoRequest("PUT", "/api/v1/geo/driver/location/batch", driverToken, []map[string]float64{
		{"lat": arrivalFixLat, "lng": arrivalPickupLng},
		{"lat": farFixLat, "lng": arrivalPickupLng},
	}).AssertStatus(t, http.StatusNoContent)

	if got := rideStatus(t, srv, ride.ID); got != "accepted" {
		t.Fatalf("status = %q; an intermediate batch fix must not advance", got)
	}
	msg := testutil.ReadWSMessage(t, riderConn)
	if msg["type"] != "driver.location" {
		t.Fatalf("message type = %v, want one driver.location for the final fix", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if lat, ok := data["lat"].(float64); !ok || lat != farFixLat {
		t.Fatalf("driver.location lat = %v, want the FINAL fix %v", data["lat"], farFixLat)
	}
	if _, ok := data["near_pickup"]; ok {
		t.Errorf("near_pickup present (%v) for a 556 m final fix; want absent", data["near_pickup"])
	}
	if _, ok := data["distance_to_pickup_m"].(float64); !ok {
		t.Errorf("distance_to_pickup_m missing for the final fix: %+v", data)
	}
	if extra, _ := testutil.TryReadWSMessage(riderConn, 250*time.Millisecond); extra != nil {
		t.Fatalf("more than one driver.location emitted for a batch: %+v", extra)
	}
}

// TestProximityBatchFinalFixAdvances: a batch whose final fix is inside the gate
// advances exactly once.
func TestProximityBatchFinalFixAdvances(t *testing.T) {
	provider := newSpyPushProvider()
	srv, _ := newArrivalTestServer(t, provider)
	riderToken, riderID := registerOn(t, srv, "arrival.batch2.rider@test.com", "+5200000023")
	driverToken, driverID := registerDriverOn(t, srv, "arrival.batch2.driver@test.com", "+5200000024")

	ride := insertAssignedRideOn(t, srv, riderID, driverID)
	riderConn := srv.DialWS(t, riderToken)
	defer func() { _ = riderConn.Close() }()

	srv.DoRequest("PUT", "/api/v1/geo/driver/location/batch", driverToken, []map[string]float64{
		{"lat": farFixLat, "lng": arrivalPickupLng},
		{"lat": arrivalFixLat, "lng": arrivalPickupLng},
	}).AssertStatus(t, http.StatusNoContent)

	upd := testutil.ReadWSMessage(t, riderConn)
	if upd["type"] != "ride.updated" || upd["data"].(map[string]interface{})["status"] != "driver_arrived" {
		t.Fatalf("batch final fix = %+v, want ride.updated driver_arrived", upd)
	}
	if got := rideStatus(t, srv, ride.ID); got != "driver_arrived" {
		t.Fatalf("status = %q, want driver_arrived", got)
	}
}
