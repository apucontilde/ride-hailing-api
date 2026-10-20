package service

import (
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

// barrierArrivalRepo is a CAS-aware RideRepository whose FindByID blocks every
// caller until the test releases it. That makes the accept-time evaluator and a
// concurrent live PUT both observe "accepted" before either can write, without
// sleeping: the race is deterministic.
type barrierArrivalRepo struct {
	repository.RideRepository
	mu        sync.Mutex
	ride      *model.Ride
	updates   []string
	events    []*model.RideEvent
	attempts  int
	conflicts int
	reached   chan struct{}
	release   chan struct{}
}

func (r *barrierArrivalRepo) FindByID(id string) (*model.Ride, error) {
	r.mu.Lock()
	if r.ride == nil || r.ride.ID != id {
		r.mu.Unlock()
		return nil, repository.ErrNotFound
	}
	cp := *r.ride
	r.mu.Unlock()

	// Every evaluator reads the ride first; hold it here until both readers
	// have the accepted snapshot.
	r.reached <- struct{}{}
	<-r.release
	return &cp, nil
}

func (r *barrierArrivalRepo) UpdateRideStatusFrom(rideID string, expectedFrom []string, status string, _ *time.Time) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts++
	matched := false
	for _, from := range expectedFrom {
		if r.ride.Status == from {
			matched = true
			break
		}
	}
	if !matched {
		// The [rides] CAS loser: no event, no broadcast, no push.
		r.conflicts++
		return false, nil
	}
	r.updates = append(r.updates, status)
	r.ride.Status = status
	return true, nil
}

func (r *barrierArrivalRepo) CreateEvent(event *model.RideEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *barrierArrivalRepo) snapshot() (updates []string, events int, attempts, conflicts int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.updates...), len(r.events), r.attempts, r.conflicts
}

// TestAcceptTimeEvaluationVsLivePutSingleTransition is the race required by
// api_plans/[arrival]_accept_time_evaluation.md §5/§9: the accept-time
// evaluator and a concurrent live PUT for the same accepted ride, both with an
// in-radius fix, produce EXACTLY ONE accepted→driver_arrived transition, one
// ride_events row, one driver_arrived broadcast per party, and one push per
// party. The loser returns ErrTransitionConflict from the landed [rides] CAS
// (recorded as a conflict) before any side effect, and both evaluator entry
// points still behave best-effort (no error escapes).
func TestAcceptTimeEvaluationVsLivePutSingleTransition(t *testing.T) {
	driverID := "driver-race"
	ride := &model.Ride{
		ID:        "ride-race",
		RiderID:   "rider-race",
		DriverID:  &driverID,
		Status:    "accepted",
		PickupLat: arrivalTestPickupLat,
		PickupLng: arrivalTestPickupLng,
	}
	repo := &barrierArrivalRepo{
		ride:    ride,
		reached: make(chan struct{}, 2),
		release: make(chan struct{}),
	}
	// A real hub with no connected clients: every transition fan-out also fires
	// its offline push, which the notifier observes.
	hub := websocket.NewHub()
	svc := NewRideService(repo, nil, hub, nil)
	svc.SetArrivalGeofence(testGeofenceConfig())
	notifier := &recordingNotifier{}
	svc.SetPushNotifier(notifier)

	lat, lng := atMetres(60) // inside the 80 m arrive gate

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		// Accept-time path.
		svc.EvaluateArrivalAtAccept(repo.ride, driverID, lat, lng)
	}()
	go func() {
		defer wg.Done()
		// Concurrent client PUT /geo/driver/location path.
		svc.EvaluateArrival(repo.ride, driverID, lat, lng)
	}()

	// Wait until both evaluators have read the accepted ride, then let them
	// write. Deterministic barrier, not a sleep.
	for i := 0; i < 2; i++ {
		select {
		case <-repo.reached:
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d/2 evaluators reached the status write barrier", i)
		}
	}
	close(repo.release)
	wg.Wait()

	updates, events, attempts, conflicts := repo.snapshot()
	if attempts != 2 {
		t.Fatalf("CAS attempts = %d, want 2", attempts)
	}
	if conflicts != 1 {
		t.Fatalf("CAS conflicts = %d, want exactly 1 (the loser)", conflicts)
	}
	if len(updates) != 1 || updates[0] != "driver_arrived" {
		t.Fatalf("committed updates = %v, want exactly [driver_arrived]", updates)
	}
	if events != 1 {
		t.Fatalf("ride_events = %d, want exactly 1", events)
	}

	// The successful transition fans out exactly one push per party; the CAS
	// loser produced none. (The HTTP/WS broadcast order and uniqueness are
	// pinned end-to-end in tests/arrival_geofence_test.go.)
	msgs := waitForMessages(t, notifier, 2)
	if len(msgs) != 2 {
		t.Fatalf("pushes = %d, want exactly 2 (one per party for the single transition)", len(msgs))
	}
	for _, msg := range msgs {
		if msg.Data["status"] != "driver_arrived" || msg.Data["type"] == "ride.nearby" {
			t.Fatalf("unexpected push after the race: %+v", msg)
		}
	}
}
