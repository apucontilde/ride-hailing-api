package service

import (
	"errors"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service/push"
	"ride-hailing-api/internal/websocket"
)

// These are the unit proofs for api_plans/[rides]_cancel_accept_race.md. The
// HTTP/WS halves live in tests/; what is proved HERE is the CAS semantics, the
// cancel authorization/idempotency rules, the accept ownership check, and the
// per-candidate "stop before offering a non-pending ride" rule.

// cancelRideRepo is a CAS-aware RideRepository for the cancel tests. It mutates
// the STORED ride and returns copies from FindByID, exactly like the real
// repository, so a service that forgets to re-read cannot pass a freshness
// assertion.
type cancelRideRepo struct {
	repository.RideRepository
	mu        sync.Mutex
	ride      *model.Ride
	events    []*model.RideEvent
	updates   []string
	updateErr error
	// onUpdate, when set, runs under the lock immediately before the CAS check
	// and models a concurrent transition that commits first.
	onUpdate func()
}

func (r *cancelRideRepo) FindByID(id string) (*model.Ride, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ride == nil || r.ride.ID != id {
		return nil, repository.ErrNotFound
	}
	cp := *r.ride
	return &cp, nil
}

func (r *cancelRideRepo) UpdateRideStatusFrom(rideID string, expectedFrom []string, status string, _ *time.Time) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.updateErr != nil {
		return false, r.updateErr
	}
	if r.onUpdate != nil {
		r.onUpdate()
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
	r.updates = append(r.updates, status)
	r.ride.Status = status
	r.ride.UpdatedAt = time.Now()
	if status == "cancelled" {
		now := time.Now()
		r.ride.CancelledAt = &now
	}
	return true, nil
}

func (r *cancelRideRepo) CreateEvent(event *model.RideEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *cancelRideRepo) snapshot() (updates []string, events []*model.RideEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.updates...), append([]*model.RideEvent(nil), r.events...)
}

type fakeWithdrawer struct {
	mu      sync.Mutex
	reasons []string
	driver  string
}

func (w *fakeWithdrawer) WithdrawOffer(rideID, reason string) string {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.reasons = append(w.reasons, reason)
	return w.driver
}

func (w *fakeWithdrawer) snapshot() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]string(nil), w.reasons...)
}

// recipientNotifier records which user each backgrounded push targeted.
type recipientNotifier struct {
	mu    sync.Mutex
	users []string
	msgs  []push.Message
}

func (n *recipientNotifier) NotifyUser(userID string, msg push.Message) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.users = append(n.users, userID)
	n.msgs = append(n.msgs, msg)
}

func (n *recipientNotifier) recipients() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]string(nil), n.users...)
}

func newCancelService(repo repository.RideRepository) *RideService {
	return NewRideService(repo, nil, websocket.NewHub(), nil)
}

func pendingCancelRide() *model.Ride {
	created := time.Now().Add(-time.Minute)
	return &model.Ride{
		ID:        "ride-cancel",
		RiderID:   "rider-1",
		Status:    "pending",
		CreatedAt: created,
		UpdatedAt: created,
	}
}

// TestCancelWinsAgainstConcurrentAccept is the accept-then-cancel ordering:
// AssignDriver commits first (the stored row becomes accepted with a driver),
// then the cancel's one conditional write still commits because "accepted" is
// in expectedFrom. The post-write re-read names the newly assigned driver, who
// receives the terminal cancellation.
func TestCancelWinsAgainstConcurrentAccept(t *testing.T) {
	repo := &cancelRideRepo{ride: pendingCancelRide()}
	driverID := "driver-1"
	repo.onUpdate = func() {
		repo.ride.Status = "accepted"
		repo.ride.DriverID = &driverID
	}
	notifier := &recipientNotifier{}
	withdrawer := &fakeWithdrawer{}
	svc := newCancelService(repo)
	svc.SetPushNotifier(notifier)
	svc.SetOfferWithdrawer(withdrawer)

	got, err := svc.CancelRide("ride-cancel", "rider", "rider-1")
	if err != nil {
		t.Fatalf("CancelRide: %v", err)
	}
	if got.Status != "cancelled" {
		t.Errorf("status = %q, want cancelled", got.Status)
	}
	if got.DriverID == nil || *got.DriverID != driverID {
		t.Errorf("driver_id = %v, want the concurrently assigned %q (from the fresh re-read)", got.DriverID, driverID)
	}
	if got.CancelledAt == nil {
		t.Error("cancelled_at is nil: the response is the stale pre-write struct")
	}
	updates, events := repo.snapshot()
	if len(updates) != 1 || updates[0] != "cancelled" {
		t.Errorf("conditional updates = %v, want [cancelled]", updates)
	}
	if len(events) != 1 || events[0].Actor != "rider" {
		t.Errorf("events = %+v, want one rider event", events)
	}
	if reasons := withdrawer.snapshot(); len(reasons) != 1 || reasons[0] != "cancelled" {
		t.Errorf("withdraw reasons = %v, want [cancelled]", reasons)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		recipients := notifier.recipients()
		if len(recipients) >= 2 {
			seen := map[string]bool{}
			for _, u := range recipients {
				seen[u] = true
			}
			if !seen["rider-1"] || !seen[driverID] {
				t.Errorf("push recipients = %v, want rider-1 and %s", recipients, driverID)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("push recipients = %v, want rider-1 and %s", notifier.recipients(), driverID)
}

// TestCancelReturnsFreshTimestamps proves the returned ride is the post-write
// row: the fake mutates only the stored struct, and FindByID hands back a copy.
func TestCancelReturnsFreshTimestamps(t *testing.T) {
	repo := &cancelRideRepo{ride: pendingCancelRide()}
	svc := newCancelService(repo)

	before := *repo.ride
	got, err := svc.CancelRide("ride-cancel", "rider", "rider-1")
	if err != nil {
		t.Fatalf("CancelRide: %v", err)
	}
	if got.CancelledAt == nil {
		t.Fatal("cancelled_at is nil in the response; the service returned the pre-write struct")
	}
	if !got.UpdatedAt.After(before.UpdatedAt) {
		t.Errorf("updated_at = %s, want a committed value after %s", got.UpdatedAt, before.UpdatedAt)
	}
}

// TestCancelIdempotentRepeatDoesNotDuplicate: a second cancel of an already
// cancelled ride is 200, writes no second event/update, and does not re-notify
// the rider. A phantom parked offer is still closed and its driver (a new
// recipient) IS notified.
func TestCancelIdempotentRepeatDoesNotDuplicate(t *testing.T) {
	now := time.Now()
	ride := pendingCancelRide()
	ride.Status = "cancelled"
	ride.CancelledAt = &now
	repo := &cancelRideRepo{ride: ride}
	withdrawer := &fakeWithdrawer{}
	notifier := &recipientNotifier{}
	svc := newCancelService(repo)
	svc.SetOfferWithdrawer(withdrawer)
	svc.SetPushNotifier(notifier)

	got, err := svc.CancelRide("ride-cancel", "rider", "rider-1")
	if err != nil {
		t.Fatalf("repeat CancelRide: %v", err)
	}
	if got.Status != "cancelled" {
		t.Errorf("status = %q, want cancelled", got.Status)
	}
	updates, events := repo.snapshot()
	if len(updates) != 0 {
		t.Errorf("updates = %v, want none on an idempotent repeat", updates)
	}
	if len(events) != 0 {
		t.Errorf("events = %d, want none on an idempotent repeat", len(events))
	}
	if reasons := withdrawer.snapshot(); len(reasons) != 1 {
		t.Errorf("withdraw calls = %v, want exactly one defensive call", reasons)
	}
	if recipients := notifier.recipients(); len(recipients) != 0 {
		t.Errorf("push recipients = %v, want none for an already-notified rider", recipients)
	}

	// A phantom offer found on the repeat is a NEW recipient: notify them only.
	withdrawer.driver = "offered-1"
	if _, err := svc.CancelRide("ride-cancel", "rider", "rider-1"); err != nil {
		t.Fatalf("repeat with phantom offer: %v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(notifier.recipients()) > 0 {
			if got := notifier.recipients(); len(got) != 1 || got[0] != "offered-1" {
				t.Errorf("recipients = %v, want only the newly discovered offered driver", got)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Error("a phantom offered driver was not notified")
}

// TestCancelAuthorization pins ownership: every mismatch is the sentinel that
// the handler maps to a missing ride's 404, and no write happens.
func TestCancelAuthorization(t *testing.T) {
	driverID := "driver-1"

	tests := []struct {
		name    string
		actor   string
		caller  string
		ride    *model.Ride
		wantErr error
	}{
		{
			name: "rider cannot cancel another rider's ride", actor: "rider", caller: "other-rider",
			ride: pendingCancelRide(), wantErr: ErrNotRideRider,
		},
		{
			name: "driver cannot cancel a pending ride (no driver)", actor: "driver", caller: driverID,
			ride: pendingCancelRide(), wantErr: ErrNotRideDriver,
		},
		{
			name: "driver cannot cancel somebody else's accepted ride", actor: "driver", caller: "other-driver",
			ride: func() *model.Ride {
				r := pendingCancelRide()
				r.Status = "accepted"
				r.DriverID = &driverID
				return r
			}(), wantErr: ErrNotRideDriver,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := &cancelRideRepo{ride: tc.ride}
			svc := newCancelService(repo)
			_, err := svc.CancelRide(tc.ride.ID, tc.actor, tc.caller)
			if !errors.Is(err, tc.wantErr) {
				t.Errorf("err = %v, want %v", err, tc.wantErr)
			}
			updates, events := repo.snapshot()
			if len(updates) != 0 || len(events) != 0 {
				t.Errorf("unauthorized cancel wrote updates=%v events=%d", updates, len(events))
			}
		})
	}
}

// TestCancelDriverOwnRideIsTerminal: a driver may cancel their own accepted
// ride; it becomes terminally cancelled with cancelled_by "driver".
func TestCancelDriverOwnRideIsTerminal(t *testing.T) {
	driverID := "driver-1"
	ride := pendingCancelRide()
	ride.Status = "driver_arrived"
	ride.DriverID = &driverID
	repo := &cancelRideRepo{ride: ride}
	svc := newCancelService(repo)

	got, err := svc.CancelRide(ride.ID, "driver", driverID)
	if err != nil {
		t.Fatalf("driver cancel: %v", err)
	}
	if got.Status != "cancelled" {
		t.Errorf("status = %q, want cancelled", got.Status)
	}
	_, events := repo.snapshot()
	if len(events) != 1 || events[0].Actor != "driver" {
		t.Errorf("events = %+v, want one driver event", events)
	}
}

// TestCancelTerminalStatusesAreConflicts: in_progress/completed/
// no_driver_available are 409 (ErrCannotCancel), never the old blanket 400.
func TestCancelTerminalStatusesAreConflicts(t *testing.T) {
	for _, status := range []string{"in_progress", "completed", "no_driver_available"} {
		t.Run(status, func(t *testing.T) {
			ride := pendingCancelRide()
			ride.Status = status
			repo := &cancelRideRepo{ride: ride}
			svc := newCancelService(repo)

			_, err := svc.CancelRide(ride.ID, "rider", "rider-1")
			if !errors.Is(err, ErrCannotCancel) {
				t.Errorf("err = %v, want ErrCannotCancel", err)
			}
			updates, _ := repo.snapshot()
			if len(updates) != 0 {
				t.Errorf("updates = %v, want none", updates)
			}
		})
	}
}

// TestTwoConcurrentCancelsWriteOneEvent: the conditional write lets exactly one
// cancel commit; the other re-reads the cancelled row and returns it without a
// second event.
func TestTwoConcurrentCancelsWriteOneEvent(t *testing.T) {
	repo := &cancelRideRepo{ride: pendingCancelRide()}
	svc := newCancelService(repo)

	var wg sync.WaitGroup
	results := make([]*model.Ride, 2)
	errs := make([]error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i], errs[i] = svc.CancelRide("ride-cancel", "rider", "rider-1")
		}(i)
	}
	wg.Wait()

	for i := 0; i < 2; i++ {
		if errs[i] != nil {
			t.Errorf("cancel %d: %v", i, errs[i])
			continue
		}
		if results[i] == nil || results[i].Status != "cancelled" {
			t.Errorf("cancel %d ride = %+v, want cancelled", i, results[i])
		}
	}
	updates, events := repo.snapshot()
	if len(updates) != 1 {
		t.Errorf("updates = %v, want exactly one committed cancellation", updates)
	}
	if len(events) != 1 {
		t.Errorf("events = %d, want exactly one", len(events))
	}
}

// TestCancelVsFinishWithoutDriver: a no_driver_available CAS that lost to a
// cancel returns false, pushes nothing, and the ride stays cancelled.
func TestCancelVsFinishWithoutDriver(t *testing.T) {
	ride := pendingCancelRide()
	ride.Status = "cancelled"
	repo := &fakeRideRepo{status: "cancelled"}
	hub := newFakeHub()
	svc := newTestDispatch(&fakeGeoRepo{}, repo, hub)
	traces := collectTraces(svc, 1)
	svc.traceRecorder().begin(ride.ID, 0)

	svc.finishWithoutDriver(ride)

	tr := awaitTrace(t, traces)
	if tr.Outcome() != "not_pending" {
		t.Errorf("outcome = %q, want not_pending", tr.Outcome())
	}
	if got := hub.rideUpdatesTo(ride.RiderID); len(got) != 0 {
		t.Errorf("rider ride.updated = %v, want none: the row was not pending", got)
	}
	if got := ride2Status(repo); got != "cancelled" {
		t.Errorf("stored status = %q, want cancelled", got)
	}
}

func ride2Status(repo *fakeRideRepo) string {
	repo.mu.Lock()
	defer repo.mu.Unlock()
	if repo.status == "" {
		return "pending"
	}
	return repo.status
}

// TestArrivalLostRaceIsLoggedAndSwallowed: a cancel winning accepted keeps the
// geofence non-fatal, with no driver_arrived event, broadcast, or push.
func TestArrivalLostRaceIsLoggedAndSwallowed(t *testing.T) {
	repo := acceptedArrivalRide()
	repo.raceTo = "cancelled"
	svc := newArrivalService(repo)
	notifier := &recordingNotifier{}
	svc.SetPushNotifier(notifier)
	logs := captureLogs(t)

	lat, lng := atMetres(60)
	near, _ := svc.EvaluateArrival(repo.ride, "driver-1", lat, lng)

	if !near {
		t.Error("near = false; the proximity fields must still be reported")
	}
	if got := repo.updates(); len(got) != 0 {
		t.Errorf("status updates = %v, want none on a lost CAS", got)
	}
	if events := repo.recordedEvents(); len(events) != 0 {
		t.Errorf("events = %d, want none on a lost CAS", len(events))
	}
	if msgs := notifier.snapshot(); len(msgs) != 0 {
		t.Errorf("pushes = %d, want none on a lost CAS", len(msgs))
	}
	if lines := logs.linesContaining("proximity arrival transition failed"); len(lines) != 1 {
		t.Errorf("log lines = %d, want exactly one swallowed-conflict line", len(lines))
	}
}

// --- accept funnel ---

// TestHandleAcceptRejectsOtherDriver closes the force-assign hole: a driver who
// was not offered the ride gets ErrNotOffered, the offered driver is NOT
// assigned, and the real offer remains acceptable by its owner.
func TestHandleAcceptRejectsOtherDriver(t *testing.T) {
	repo := &fakeRideRepo{}
	hub := newFakeHub("offered-driver")
	svc := newTestDispatch(&fakeGeoRepo{}, repo, hub)

	const rideID = "ride-other"
	svc.offerChannelsMu.Lock()
	svc.offerSeq++
	svc.offerChannels[rideID] = activeOffer{
		driverID: "offered-driver", token: svc.offerSeq, ch: make(chan offerAnswer, 1),
	}
	svc.offerChannelsMu.Unlock()

	err := svc.HandleAccept("intruder", rideID)
	if !errors.Is(err, ErrNotOffered) {
		t.Fatalf("HandleAccept(intruder) = %v, want ErrNotOffered", err)
	}
	if got := repo.assignmentLog(); len(got) != 0 {
		t.Fatalf("assignments = %v, want none: a foreign driver must never assign the offered driver", got)
	}
	svc.offerChannelsMu.Lock()
	_, stillParked := svc.offerChannels[rideID]
	svc.offerChannelsMu.Unlock()
	if !stillParked {
		t.Fatal("the parked offer was deleted by a foreign accept")
	}

	// The real owner can still accept, exactly once.
	if err := svc.HandleAccept("offered-driver", rideID); err != nil {
		t.Fatalf("owner HandleAccept: %v", err)
	}
	if got := repo.assignmentLog(); len(got) != 1 || got[0] != "offered-driver" {
		t.Errorf("assignments = %v, want [offered-driver]", got)
	}
}

// TestHandleAcceptNoOffer: an expired/withdrawn/answered offer is
// ErrNoActiveOffer (404), never a false success.
func TestHandleAcceptNoOffer(t *testing.T) {
	svc := newTestDispatch(&fakeGeoRepo{}, &fakeRideRepo{}, newFakeHub())
	err := svc.HandleAccept("driver-1", "ride-missing")
	if !errors.Is(err, ErrNoActiveOffer) {
		t.Fatalf("HandleAccept = %v, want ErrNoActiveOffer", err)
	}
}

// TestHandleAcceptLosesRaceReturnsConflict: the ride left pending before the
// assignment write, so HandleAccept returns a wrapped conflict, assigns nobody,
// and tells the accepting driver the terminal status.
func TestHandleAcceptLosesRaceReturnsConflict(t *testing.T) {
	repo := &fakeRideRepo{status: "cancelled"}
	hub := newFakeHub("driver-1")
	svc := newTestDispatch(&fakeGeoRepo{}, repo, hub)

	const rideID = "ride-lost"
	svc.offerChannelsMu.Lock()
	svc.offerSeq++
	offer := activeOffer{driverID: "driver-1", token: svc.offerSeq, ch: make(chan offerAnswer, 1)}
	svc.offerChannels[rideID] = offer
	svc.offerChannelsMu.Unlock()

	err := svc.HandleAccept("driver-1", rideID)
	if !errors.Is(err, repository.ErrConflict) && !errors.Is(err, errConflict) {
		t.Fatalf("HandleAccept = %v, want a conflict", err)
	}
	if got := repo.assignmentLog(); len(got) != 0 {
		t.Errorf("assignments = %v, want none", got)
	}
	select {
	case answer := <-offer.ch:
		if answer.err == nil {
			t.Error("the parked loop must be told the accept failed")
		}
	case <-time.After(time.Second):
		t.Fatal("no answer was sent to the parked loop")
	}
	if got := hub.rideUpdatesTo("driver-1"); len(got) != 1 || got[0] != "cancelled" {
		t.Errorf("accepting driver updates = %v, want [cancelled] (terminal state)", got)
	}
}

// TestAcceptAssignsExactlyOnce: a successful accept plus the loop's
// offerAnswer handling yields exactly ONE AssignDriver call and no false
// accept_failed skip.
func TestAcceptAssignsExactlyOnce(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	repo := &fakeRideRepo{}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, repo, hub)
	traces := collectTraces(svc, 1)
	logs := captureLogs(t)

	if err := svc.Dispatch(pendingRide("ride-once")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	go awaitOfferAndAccept(t, svc, "ride-once", "driver-a")

	tr := awaitTrace(t, traces)
	awaitAssignments(t, repo, 1)

	if got := repo.assignmentLog(); len(got) != 1 {
		t.Fatalf("assignments = %v, want exactly one", got)
	}
	if tr.Outcome() != "accepted" {
		t.Errorf("outcome = %q, want accepted", tr.Outcome())
	}
	if len(tr.Skips) != 0 {
		t.Errorf("skips = %v, want none: a successful accept must not record accept_failed", tr.Skips)
	}
	if lines := logs.linesContaining("failed to accept ride"); len(lines) != 0 {
		t.Errorf("failure log lines = %v, want none after a successful accept", lines)
	}
}

// TestDispatchLoopStopsPromptlyOnWithdraw: WithdrawOffer wakes the parked loop
// immediately (not after offerTimeout), sends ride.offer_closed, and the
// post-loop re-read records not_pending.
func TestDispatchLoopStopsPromptlyOnWithdraw(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	repo := &fakeRideRepo{}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, repo, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-withdraw")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	offer := awaitOfferChannel(t, svc, "ride-withdraw", nil)
	// The ride was cancelled by the rider; the loop must stop without offering
	// anybody else and without waiting for the 30 s timeout.
	repo.setStatus("cancelled")

	start := time.Now()
	offered := svc.WithdrawOffer("ride-withdraw", "cancelled")
	tr := awaitTrace(t, traces)
	elapsed := time.Since(start)

	if offered != offer.driverID {
		t.Errorf("offered driver = %q, want %q", offered, offer.driverID)
	}
	if elapsed >= 2*time.Second {
		t.Errorf("withdrawal took %s, want well under the %s offer timeout", elapsed, offerTimeout)
	}
	if tr.Outcome() != "not_pending" {
		t.Errorf("outcome = %q, want not_pending", tr.Outcome())
	}
	reasons := hub.offerClosedReasons()
	if len(reasons) != 1 || reasons[0] != "cancelled" {
		t.Errorf("ride.offer_closed reasons = %v, want [cancelled]", reasons)
	}
}

// TestNoOfferSentAfterAcceptOrCancel: after another transition commits between
// candidates, the per-candidate re-read stops the loop before the next offer.
func TestNoOfferSentAfterAcceptOrCancel(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{
		{DriverID: "driver-a"}, {DriverID: "driver-b"},
	}}
	repo := &fakeRideRepo{}
	hub := newFakeHub("driver-a", "driver-b")
	svc := newTestDispatch(geo, repo, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-nooffer")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	first := awaitOfferChannel(t, svc, "ride-nooffer", nil)
	// An accept committed elsewhere while candidate A's offer was parked.
	repo.setStatus("accepted")
	if err := svc.DeclineOffer(first.driverID, "ride-nooffer"); err != nil {
		t.Fatalf("DeclineOffer: %v", err)
	}

	tr := awaitTrace(t, traces)
	if tr.Outcome() != "not_pending" {
		t.Errorf("outcome = %q, want not_pending", tr.Outcome())
	}
	if got := hub.offersTo(); len(got) != 1 {
		t.Errorf("ride.offer deliveries = %d, want 1: no later candidate may be offered a non-pending ride", len(got))
	}
	if got := repo.assignmentLog(); len(got) != 0 {
		t.Errorf("assignments = %v, want none", got)
	}
}

// TestDispatchOfferClosedOnTimeout: the offerTimeout stop point sends
// ride.offer_closed reason "expired". The timeout is shrunk for the test.
func TestDispatchOfferClosedOnTimeout(t *testing.T) {
	old := offerTimeout
	offerTimeout = 20 * time.Millisecond
	t.Cleanup(func() { offerTimeout = old })

	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	repo := &fakeRideRepo{}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, repo, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-timeout")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	tr := awaitTrace(t, traces)
	if tr.Outcome() != "candidates_skipped" {
		t.Errorf("outcome = %q, want candidates_skipped (the candidate timed out)", tr.Outcome())
	}
	reasons := hub.offerClosedReasons()
	if len(reasons) != 1 || reasons[0] != "expired" {
		t.Errorf("ride.offer_closed reasons = %v, want [expired]", reasons)
	}
	// The offer is gone, so an accept afterwards is 404, never a false 200.
	if err := svc.HandleAccept("driver-a", "ride-timeout"); !errors.Is(err, ErrNoActiveOffer) {
		t.Errorf("late HandleAccept = %v, want ErrNoActiveOffer", err)
	}
}

// TestNoExpiredOfferClosedAfterCommittedAccept is the deterministic §4.1.1
// timeout-vs-accept boundary proof. The fake repository commits the assignment
// and then blocks until released, so the shrunk offerTimeout fires while the
// generation is already claimed (HandleAccept deleted it before acceptRide) and
// the accept answer has NOT been sent. The timeout branch must observe the
// claim, block on the parked channel for the claimant's guaranteed answer, and
// adopt it. It must never record skipOfferTimeout or send
// ride.offer_closed reason "expired", and the loop must finish accepted with
// exactly one assignment.
func TestNoExpiredOfferClosedAfterCommittedAccept(t *testing.T) {
	old := offerTimeout
	offerTimeout = 100 * time.Millisecond
	t.Cleanup(func() { offerTimeout = old })

	const rideID = "ride-boundary"
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	repo := &fakeRideRepo{
		assignCommitted: make(chan struct{}),
		assignRelease:   make(chan struct{}),
	}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, repo, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide(rideID)); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	awaitOfferChannel(t, svc, rideID, nil)

	// HandleAccept claims (deletes) the offer, then acceptRide commits the
	// assignment and blocks inside AssignDriver before the answer is sent.
	acceptErr := make(chan error, 1)
	go func() { acceptErr <- svc.HandleAccept("driver-a", rideID) }()

	select {
	case <-repo.assignCommitted:
	case <-time.After(5 * time.Second):
		t.Fatal("AssignDriver never committed")
	}

	// The timer fires while the generation is claimed and the answer is unsent.
	time.Sleep(3 * offerTimeout)

	var early dispatchTrace
	var haveEarly bool
	select {
	case early = <-traces:
		haveEarly = true
	default:
	}
	if haveEarly {
		t.Errorf("dispatch loop closed before the accept answer was released (outcome=%q); "+
			"the timeout branch must block for the claimant's answer", early.Outcome())
	}
	if reasons := hub.offerClosedReasons(); len(reasons) != 0 {
		t.Errorf("ride.offer_closed before the accept answer was released = %v, want none", reasons)
	}

	// Let the committed accept finish and send its answer.
	close(repo.assignRelease)

	select {
	case err := <-acceptErr:
		if err != nil {
			t.Fatalf("HandleAccept: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("HandleAccept did not return after the assignment was released")
	}

	tr := early
	if !haveEarly {
		tr = awaitTrace(t, traces)
	}
	if tr.Outcome() != "accepted" {
		t.Errorf("outcome = %q, want accepted (never a timeout skip)", tr.Outcome())
	}
	if tr.NotPending {
		t.Error("trace recorded not_pending; the timeout branch did not adopt the accept outcome")
	}
	for _, skip := range tr.Skips {
		if skip.Reason == skipOfferTimeout {
			t.Errorf("skip = %+v, want no skipOfferTimeout for a committed accept", skip)
		}
	}
	if got := repo.assignmentLog(); len(got) != 1 || got[0] != "driver-a" {
		t.Errorf("assignments = %v, want exactly [driver-a]", got)
	}
	for _, reason := range hub.offerClosedReasons() {
		if reason == "expired" {
			t.Errorf("ride.offer_closed reason = %q, want no expired frame after a committed accept", reason)
		}
	}
}
