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

// spyPushProvider is an injectable push.Provider that records every send and
// signals it on a channel. It lets the notify-arrival test assert the PUSH half
// (zero sends when the rider is connected, exactly one when backgrounded), not
// just that the WebSocket message arrived. Production wiring is unchanged: the
// router already supports injecting a provider via router.WithPushProvider.
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
// spy provider, so this file can observe push delivery without touching the
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
	parseJSON(t, resp.Body, &login)
	return login.AccessToken, login.User.ID
}

func registerDriverOn(t *testing.T, srv *testutil.TestServer, email, phone string) (token, id string) {
	t.Helper()
	token, _ = registerOn(t, srv, email, phone)
	srv.DoRequest("POST", "/api/v1/driver/register", token, nil).AssertStatus(t, http.StatusCreated)
	return loginOn(t, srv, email)
}

func insertAssignedRideOn(t *testing.T, srv *testutil.TestServer, riderID, driverID string) *model.Ride {
	t.Helper()
	ride := &model.Ride{
		RiderID:    riderID,
		DriverID:   &driverID,
		PickupLat:  40.7,
		PickupLng:  -74.0,
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

// insertAssignedRide is the shared-server form used by the 404 tests.
func insertAssignedRide(t *testing.T, riderID, driverID string) *model.Ride {
	t.Helper()
	return insertAssignedRideOn(t, ts, riderID, driverID)
}

// TestNotifyArrivalSendsLiveUpdateToConnectedRider pins BOTH halves for a
// connected rider: the live ride.updated arrives AND no push is sent. The
// second assertion is the one the previous version lacked — it now fails if the
// handler starts pushing to a rider whose socket is live.
func TestNotifyArrivalSendsLiveUpdateToConnectedRider(t *testing.T) {
	provider := newSpyPushProvider()
	srv, deviceRepo := newArrivalTestServer(t, provider)
	riderToken, riderID := registerOn(t, srv, "push.arrival.rider@test.com", "+5100000013")
	driverToken, driverID := registerDriverOn(t, srv, "push.arrival.driver@test.com", "+5100000014")

	ride := insertAssignedRideOn(t, srv, riderID, driverID)

	// A token exists, so a push is possible; only the live socket must
	// suppress it.
	if _, err := deviceRepo.Register(riderID, "tok-connected-rider", "android"); err != nil {
		t.Fatalf("seed device token: %v", err)
	}

	conn := srv.DialWS(t, riderToken)
	defer func() { _ = conn.Close() }()

	resp := srv.DoRequest("POST", "/api/v1/driver/rides/"+ride.ID+"/notify-arrival", driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "message", "rider notified of arrival")

	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Fatalf("type = %v, want ride.updated", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != "driver_arrived" || data["ride_id"] != ride.ID {
		t.Fatalf("data = %+v, want driver_arrived for %s", data, ride.ID)
	}

	select {
	case sent := <-provider.ch:
		t.Fatalf("connected rider also received a push: %+v", sent)
	case <-time.After(300 * time.Millisecond):
	}
	if n := provider.count(); n != 0 {
		t.Fatalf("push provider recorded %d sends for a connected rider, want 0", n)
	}
}

// TestNotifyArrivalPushesExactlyOnceWhenRiderIsBackgrounded pins the other
// half: with no live socket and a registered token, the handler attempts
// exactly one push carrying the arrival status. Waiting on the provider channel
// makes this deterministic despite the handler's fire-and-forget goroutine.
func TestNotifyArrivalPushesExactlyOnceWhenRiderIsBackgrounded(t *testing.T) {
	provider := newSpyPushProvider()
	srv, deviceRepo := newArrivalTestServer(t, provider)
	_, riderID := registerOn(t, srv, "push.arrival.bg.rider@test.com", "+5100000019")
	driverToken, driverID := registerDriverOn(t, srv, "push.arrival.bg.driver@test.com", "+5100000020")

	ride := insertAssignedRideOn(t, srv, riderID, driverID)

	// No WS connection; a token gives the push a destination.
	if _, err := deviceRepo.Register(riderID, "tok-bg-rider", "android"); err != nil {
		t.Fatalf("seed device token: %v", err)
	}

	resp := srv.DoRequest("POST", "/api/v1/driver/rides/"+ride.ID+"/notify-arrival", driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)

	select {
	case sent := <-provider.ch:
		if sent.token != "tok-bg-rider" {
			t.Fatalf("push token = %q, want tok-bg-rider", sent.token)
		}
		if sent.msg.Data["status"] != "driver_arrived" || sent.msg.Data["ride_id"] != ride.ID {
			t.Fatalf("push data = %+v, want driver_arrived for %s", sent.msg.Data, ride.ID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no push was attempted for a backgrounded rider")
	}

	// And exactly one: no duplicate delivery.
	time.Sleep(150 * time.Millisecond)
	if n := provider.count(); n != 1 {
		t.Fatalf("push provider recorded %d sends, want exactly 1", n)
	}
}

func TestNotifyArrivalRejectsAnotherDriversRide(t *testing.T) {
	const riderEmail = "push.arrival2.rider@test.com"
	const ownerEmail = "push.arrival2.owner@test.com"
	const otherEmail = "push.arrival2.other@test.com"
	registerAndLogin(t, riderEmail, "+5100000015")
	_, riderID := loginUserID(t, riderEmail)
	registerDriver(t, ownerEmail, "+5100000016")
	_, ownerID := loginUserID(t, ownerEmail)
	otherToken := registerDriver(t, otherEmail, "+5100000017")

	ride := insertAssignedRide(t, riderID, ownerID)

	resp := ts.DoRequest("POST", "/api/v1/driver/rides/"+ride.ID+"/notify-arrival", otherToken, nil)
	resp.AssertStatus(t, http.StatusNotFound)
}

func TestNotifyArrivalUnknownRideIs404(t *testing.T) {
	const driverEmail = "push.arrival3.driver@test.com"
	driverToken := registerDriver(t, driverEmail, "+5100000018")

	resp := ts.DoRequest("POST", "/api/v1/driver/rides/00000000-0000-0000-0000-000000000000/notify-arrival", driverToken, nil)
	resp.AssertStatus(t, http.StatusNotFound)
}
