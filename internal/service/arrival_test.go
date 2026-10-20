package service

import (
	"errors"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service/push"
	"ride-hailing-api/internal/websocket"
)

// These are the unit proofs for
// api_plans/[arrival]_proximity_arrival_geofence.md §2–§3. The handler half and
// the end-to-end half live in internal/handler/geo_arrival_test.go and
// tests/arrival_geofence_test.go.

const (
	arrivalTestPickupLat = 40.7
	arrivalTestPickupLng = -74.0
)

// atMetres returns a fix `d` straight-line metres NORTH of the test pickup.
// 0.001 deg of latitude is ~111.2 m, so the conversion is accurate enough for
// the 80/300 m gates.
func atMetres(d float64) (lat, lng float64) {
	return arrivalTestPickupLat + d/111195.0, arrivalTestPickupLng
}

func testGeofenceConfig() config.ArrivalGeofence {
	return config.ArrivalGeofence{
		Enabled:       true,
		NearbyRadiusM: 300,
		ArriveRadiusM: 80,
		HysteresisM:   30,
		MinMoveM:      10,
	}
}

// arrivalRideRepo is the minimum RideRepository the geofence path touches. It
// embeds the interface nil so any method the arrival path does not use panics,
// and it records the status updates and events so a test can prove exactly what
// the service persisted.
type arrivalRideRepo struct {
	repository.RideRepository
	mu             sync.Mutex
	ride           *model.Ride
	updateErr      error
	updateAttempts int
	// raceTo, when set, is applied to the stored ride immediately before the
	// CAS check, simulating a concurrent transition (e.g. a cancel) that wins.
	raceTo        string
	statusUpdates []string
	events        []*model.RideEvent
}

func (r *arrivalRideRepo) FindByID(id string) (*model.Ride, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ride == nil || r.ride.ID != id {
		return nil, repository.ErrNotFound
	}
	cp := *r.ride
	return &cp, nil
}

func (r *arrivalRideRepo) UpdateRideStatusFrom(rideID string, expectedFrom []string, status string, _ *time.Time) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.updateAttempts++
	if r.updateErr != nil {
		return false, r.updateErr
	}
	if r.raceTo != "" {
		r.ride.Status = r.raceTo
		r.raceTo = ""
	}
	matched := false
	for _, from := range expectedFrom {
		if r.ride.Status == from {
			matched = true
			break
		}
	}
	if !matched {
		return false, nil
	}
	r.statusUpdates = append(r.statusUpdates, status)
	r.ride.Status = status
	return true, nil
}

func (r *arrivalRideRepo) CreateEvent(event *model.RideEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *arrivalRideRepo) updates() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.statusUpdates...)
}

func (r *arrivalRideRepo) recordedEvents() []*model.RideEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]*model.RideEvent(nil), r.events...)
}

// recordingNotifier captures the backgrounded pushes fired by notifyOffline
// (which runs on a goroutine, hence waitForMessages).
type recordingNotifier struct {
	mu   sync.Mutex
	msgs []push.Message
}

func (n *recordingNotifier) NotifyUser(_ string, msg push.Message) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.msgs = append(n.msgs, msg)
}

func (n *recordingNotifier) snapshot() []push.Message {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]push.Message(nil), n.msgs...)
}

func waitForMessages(t *testing.T, n *recordingNotifier, want int) []push.Message {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		msgs := n.snapshot()
		if len(msgs) >= want {
			return msgs
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %d push(es), got %d", want, len(msgs))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func acceptedArrivalRide() *arrivalRideRepo {
	driverID := "driver-1"
	return &arrivalRideRepo{ride: &model.Ride{
		ID:        "ride-arrival",
		RiderID:   "rider-1",
		DriverID:  &driverID,
		Status:    "accepted",
		PickupLat: arrivalTestPickupLat,
		PickupLng: arrivalTestPickupLng,
	}}
}

func newArrivalService(repo repository.RideRepository) *RideService {
	svc := NewRideService(repo, nil, websocket.NewHub(), nil)
	svc.SetArrivalGeofence(testGeofenceConfig())
	return svc
}

// TestEvaluateArrivalFiresTransitionWithSystemActor: a fix inside the arrive
// gate advances accepted→driver_arrived with actor "system" and one event.
func TestEvaluateArrivalFiresTransitionWithSystemActor(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)

	lat, lng := atMetres(60)
	near, d := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)

	if !near {
		t.Error("near = false at 60 m, want true (60 m is inside the nearby radius too)")
	}
	if d < 55 || d > 65 {
		t.Errorf("distance = %.1f, want ~60 m", d)
	}
	if got := repo.updates(); len(got) != 1 || got[0] != "driver_arrived" {
		t.Fatalf("status updates = %v, want [driver_arrived]", got)
	}
	events := repo.recordedEvents()
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	if e := events[0]; e.FromStatus != "accepted" || e.ToStatus != "driver_arrived" || e.Actor != "system" {
		t.Fatalf("event = %+v, want accepted->driver_arrived actor system", e)
	}
}

// TestEvaluateArrivalNoAdvanceWhenNotAccepted: any status other than accepted is
// skipped (and idempotent, so a re-arrival never re-fires).
func TestEvaluateArrivalNoAdvanceWhenNotAccepted(t *testing.T) {
	for _, status := range []string{"driver_arrived", "in_progress", "completed", "cancelled"} {
		t.Run(status, func(t *testing.T) {
			repo := acceptedArrivalRide()
			repo.ride.Status = status
			svc := newArrivalService(repo)

			lat, lng := atMetres(60)
			near, d := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)

			if near || d != 0 {
				t.Errorf("returned (%v, %v), want (false, 0) for status %q", near, d, status)
			}
			if got := repo.updates(); len(got) != 0 {
				t.Fatalf("status updates = %v, want none for status %q", got, status)
			}
		})
	}
}

// TestEvaluateArrivalNoAdvanceWhenDriverMismatch: a ride whose driver is not the
// caller must never advance.
func TestEvaluateArrivalNoAdvanceWhenDriverMismatch(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)

	lat, lng := atMetres(60)
	near, d := svc.EvaluateArrival(repo.ride, "someone-else", lat, lng)

	if near || d != 0 {
		t.Errorf("returned (%v, %v), want (false, 0) for a foreign driver", near, d)
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("status updates = %v, want none for a foreign driver", got)
	}
}

// TestEvaluateArrivalNearbyHysteresisRearms pins the near flag's lifecycle:
// set inside 300 m, held through the hysteresis band, cleared past 330 m, then
// re-armed on the next crossing.
func TestEvaluateArrivalNearbyHysteresisRearms(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)

	cases := []struct {
		metres float64
		want   bool
	}{
		{250, true},  // first crossing
		{320, true},  // inside the hysteresis band: holds
		{400, false}, // past 300+30: clears
		{250, true},  // re-arms
	}
	for _, tc := range cases {
		lat, lng := atMetres(tc.metres)
		near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)
		if near != tc.want {
			t.Errorf("near at %.0f m = %v, want %v", tc.metres, near, tc.want)
		}
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("nearby changed status: %v (must stay accepted)", got)
	}
}

// TestEvaluateArrivalMinMoveSuppressesNearbyNeverArrive: a huge MIN_MOVE freezes
// the nearby bookkeeping (so the flag does not clear on a big jump), yet the
// arrive gate still fires.
func TestEvaluateArrivalMinMoveSuppressesNearbyNeverArrive(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)
	cfg := testGeofenceConfig()
	cfg.MinMoveM = 1e9
	svc.SetArrivalGeofence(cfg)

	lat, lng := atMetres(250)
	if near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng); !near {
		t.Fatal("first fix at 250 m should be near")
	}
	// A 400 m fix would clear a non-suppressed flag, but MIN_MOVE suppresses the
	// bookkeeping, so the flag is reported unchanged.
	lat, lng = atMetres(400)
	if near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng); !near {
		t.Fatalf("near = false at 400 m with MIN_MOVE=1e9; the bookkeeping must be suppressed")
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("suppressed nearby advanced the ride: %v", got)
	}

	// The arrive gate is NOT gated by MIN_MOVE: a slow creep fires it.
	lat, lng = atMetres(60)
	if near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng); !near {
		t.Fatal("arrival fix should report near")
	}
	if got := repo.updates(); len(got) != 1 || got[0] != "driver_arrived" {
		t.Fatalf("status updates = %v, want [driver_arrived] (MIN_MOVE must not gate arrival)", got)
	}
}

// TestEvaluateArrivalClampsArriveToNearby: ARRIVE > NEARBY is clamped to NEARBY,
// so a fix between the two radii does not advance.
func TestEvaluateArrivalClampsArriveToNearby(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := NewRideService(repo, nil, websocket.NewHub(), nil)
	svc.SetArrivalGeofence(config.ArrivalGeofence{
		Enabled: true, NearbyRadiusM: 300, ArriveRadiusM: 500, HysteresisM: 30, MinMoveM: 10,
	})

	lat, lng := atMetres(350) // inside the raw ARRIVE=500 but outside the clamped NEARBY=300
	near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)
	if near {
		t.Errorf("near = true at 350 m (outside the 300 m nearby radius), want false")
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("status updates = %v, want none (ARRIVE clamped to NEARBY=300)", got)
	}

	lat, lng = atMetres(250)
	svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)
	if got := repo.updates(); len(got) != 1 || got[0] != "driver_arrived" {
		t.Fatalf("status updates = %v, want [driver_arrived] at 250 m", got)
	}
}

// TestEvaluateArrivalNearbyPushShape pins the canonical ride.nearby payload.
func TestEvaluateArrivalNearbyPushShape(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)
	notifier := &recordingNotifier{}
	svc.SetPushNotifier(notifier)

	lat, lng := atMetres(250)
	svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)

	msgs := waitForMessages(t, notifier, 1)
	if len(msgs) != 1 {
		t.Fatalf("pushes = %d, want exactly 1 (one crossing)", len(msgs))
	}
	msg := msgs[0]
	if msg.Title != "Driver nearby" || msg.Body != "Your driver is almost at the pickup point." {
		t.Errorf("push title/body = %q/%q", msg.Title, msg.Body)
	}
	if msg.Data["type"] != "ride.nearby" || msg.Data["status"] != "accepted" ||
		msg.Data["ride_id"] != repo.ride.ID || msg.Data["near_pickup"] != "true" {
		t.Fatalf("push data = %+v, want ride.nearby/accepted/%s/near_pickup=true", msg.Data, repo.ride.ID)
	}
}

// TestEvaluateArrivalTransitionFailureIsSwallowed: a persistence failure must be
// logged and swallowed — never returned, never a panic — and must not fabricate
// a status update.
func TestEvaluateArrivalTransitionFailureIsSwallowed(t *testing.T) {
	repo := acceptedArrivalRide()
	repo.updateErr = errors.New("db down")
	svc := newArrivalService(repo)

	lat, lng := atMetres(60)
	near, d := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)

	if !near {
		t.Error("near = false; the proximity fields must still be reported on a failed transition")
	}
	if d < 55 || d > 65 {
		t.Errorf("distance = %.1f, want ~60 m", d)
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("status updates = %v, want none (the write failed)", got)
	}
}

// --- Accept-time evaluation (api_plans/[arrival]_accept_time_evaluation.md) ---

// TestEvaluateArrivalAtAcceptAdvancesInsideRadius: the arrive-only entry point
// advances accepted→driver_arrived exactly once, with the same system actor and
// event as the live PUT path.
func TestEvaluateArrivalAtAcceptAdvancesInsideRadius(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)

	lat, lng := atMetres(60)
	if !svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
		t.Fatal("EvaluateArrivalAtAccept = false at 60 m, want true")
	}
	if got := repo.updates(); len(got) != 1 || got[0] != "driver_arrived" {
		t.Fatalf("status updates = %v, want [driver_arrived]", got)
	}
	events := repo.recordedEvents()
	if len(events) != 1 || events[0].FromStatus != "accepted" ||
		events[0].ToStatus != "driver_arrived" || events[0].Actor != "system" {
		t.Fatalf("events = %+v, want one accepted->driver_arrived/system", events)
	}

	// Idempotent: a second accept-time call on the now-arrived ride is a no-op.
	if svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
		t.Error("second EvaluateArrivalAtAccept = true, want false (ride is no longer accepted)")
	}
	if got := repo.updates(); len(got) != 1 {
		t.Fatalf("status updates after second call = %v, want exactly one", got)
	}
}

// TestEvaluateArrivalAtAcceptOutsideRadiusNeverTouchesNearby: an outside-arrive
// fix is a non-event at accept time. It must not emit a ride.nearby push, and
// crucially it must not prime the nearby hysteresis state: the live PUT path
// must still fire its own one-per-crossing nearby push afterwards.
func TestEvaluateArrivalAtAcceptOutsideRadiusNeverTouchesNearby(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)
	notifier := &recordingNotifier{}
	svc.SetPushNotifier(notifier)

	// 250 m is inside the 300 m nearby radius but outside the 80 m arrive gate.
	lat, lng := atMetres(250)
	if svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
		t.Fatal("EvaluateArrivalAtAccept = true at 250 m, want false (outside arrive)")
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("status updates = %v, want none outside the arrive gate", got)
	}
	// Nothing may have fired or been primed by the accept-time call.
	if msgs := notifier.snapshot(); len(msgs) != 0 {
		t.Fatalf("accept-time call emitted %d nearby push(es), want 0", len(msgs))
	}
	if n := len(svc.nearStates); n != 0 {
		t.Fatalf("nearStates entries = %d after accept-time call, want 0", n)
	}

	// The live PUT path must still see the FIRST crossing and push exactly once.
	if near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng); !near {
		t.Fatal("live EvaluateArrival = false at 250 m, want near")
	}
	msgs := waitForMessages(t, notifier, 1)
	if len(msgs) != 1 || msgs[0].Data["type"] != "ride.nearby" {
		t.Fatalf("pushes = %+v, want exactly one ride.nearby from the live path", msgs)
	}
	// A second live fix inside the radius stays one crossing.
	lat, lng = atMetres(260)
	svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)
	if n := len(notifier.snapshot()); n != 1 {
		t.Fatalf("pushes = %d, want exactly 1 (one crossing)", n)
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("nearby changed status: %v", got)
	}
}

// TestEvaluateArrivalAtAcceptNoOps pins the guards: disabled config, a foreign
// driver, and a ride that is not accepted all do nothing.
func TestEvaluateArrivalAtAcceptNoOps(t *testing.T) {
	lat, lng := atMetres(60)

	t.Run("disabled", func(t *testing.T) {
		repo := acceptedArrivalRide()
		svc := NewRideService(repo, nil, websocket.NewHub(), nil)
		// Zero-value geofence = off.
		if svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
			t.Error("returned true while the geofence is disabled")
		}
		if got := repo.updates(); len(got) != 0 {
			t.Fatalf("status updates = %v, want none", got)
		}
	})

	t.Run("wrong_driver", func(t *testing.T) {
		repo := acceptedArrivalRide()
		svc := newArrivalService(repo)
		if svc.EvaluateArrivalAtAccept(repo.ride, "someone-else", lat, lng) {
			t.Error("returned true for a foreign driver")
		}
		if got := repo.updates(); len(got) != 0 {
			t.Fatalf("status updates = %v, want none", got)
		}
	})

	t.Run("not_accepted", func(t *testing.T) {
		for _, status := range []string{"pending", "driver_arrived", "in_progress", "completed", "cancelled"} {
			repo := acceptedArrivalRide()
			repo.ride.Status = status
			svc := newArrivalService(repo)
			if svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
				t.Errorf("status %q: returned true, want false", status)
			}
			if got := repo.updates(); len(got) != 0 {
				t.Errorf("status %q: updates = %v, want none", status, got)
			}
		}
	})
}

// TestEvaluateArrivalAtAcceptSwallowsTransitionFailure: the evaluator returns a
// bool, never an error, and a failed write must not fabricate an update.
func TestEvaluateArrivalAtAcceptSwallowsTransitionFailure(t *testing.T) {
	repo := acceptedArrivalRide()
	repo.updateErr = errors.New("db down")
	svc := newArrivalService(repo)

	lat, lng := atMetres(60)
	if !svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
		t.Error("inside-radius result = false; the gate is geometric, independent of the write")
	}
	if got := repo.updates(); len(got) != 0 {
		t.Fatalf("status updates = %v, want none (the write failed)", got)
	}
}

// TestEvaluateArrivalAtAcceptHasNoAgeGate documents D1/D2's boundary: the
// evaluator has no age input, so freshness is entirely the dispatch gate's job
// (it reads the SQL-computed AgeS). A fix inside the arrive gate always
// evaluates here, regardless of how old the caller believes it is.
func TestEvaluateArrivalAtAcceptHasNoAgeGate(t *testing.T) {
	repo := acceptedArrivalRide()
	svc := newArrivalService(repo)
	lat, lng := atMetres(60)
	if !svc.EvaluateArrivalAtAccept(repo.ride, "driver-1", lat, lng) {
		t.Fatal("evaluator returned false inside the arrive gate")
	}
	if got := repo.updates(); len(got) != 1 {
		t.Fatalf("updates = %v, want exactly one", got)
	}
}
