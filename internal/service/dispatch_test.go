package service

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lib/pq"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

// These are the unit-level proofs for api_plans
// [dispatch]_reliability_and_no_driver_false_negative. The end-to-end HTTP
// coverage lives in tests/dispatch_offer_test.go; what is proved HERE is the
// part that end-to-end tests cannot reach reliably — every skip reason, and the
// terminal trace, on a fake repository and a real (empty) hub.

// fakeGeoRepo is a minimal GeoRepository for the dispatch search. The methods
// the dispatch path actually calls are implemented; the rest are inert no-ops
// so a future dispatch change which starts using one of them does not silently
// look like it works.
type fakeGeoRepo struct {
	mu sync.Mutex
	// drivers is returned by every FindNearbyDrivers call that the search
	// makes; nil models "found nobody at any radius".
	drivers []model.NearbyDriverResult
	// findErr, when set, makes FindNearbyDrivers fail (the search-outage case).
	findErr error
	// findCalls counts search attempts: 5 means the radius search widened all
	// the way to 10km without finding anyone.
	findCalls int
	// sweeps counts MarkStaleDriversOffline calls (the sweeper's observable).
	sweeps int
	// onSweep, when set, fires on every MarkStaleDriversOffline call.
	onSweep func()
}

func (f *fakeGeoRepo) UpsertDriverPosition(string, float64, float64, float64, float64, string) error {
	return nil
}
func (f *fakeGeoRepo) UpsertRiderPosition(string, float64, float64) error { return nil }
func (f *fakeGeoRepo) FindNearbyDrivers(_, _ float64, _ float64, _ int) ([]model.NearbyDriverResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.findCalls++
	if f.findErr != nil {
		return nil, f.findErr
	}
	return f.drivers, nil
}
func (f *fakeGeoRepo) CountNearbyDrivers(_, _ float64, _ float64) (int, error) { return 0, nil }
func (f *fakeGeoRepo) GetDriverLocation(string) (*model.NearbyDriverResult, error) {
	return nil, repository.ErrNotFound
}
func (f *fakeGeoRepo) MarkStaleDriversOffline() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sweeps++
	return nil
}

func (f *fakeGeoRepo) TouchDriverPresence(driverID, status string) error {
	if driverID == "ghost" {
		return repository.ErrNotFound
	}
	return nil
}

func (f *fakeGeoRepo) findCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.findCalls
}

// fakeRideRepo is a RideRepository that records what Dispatch persisted and can
// be made to fail the writes, so the "a failed write never answers success"
// branches are reachable without a database.
type fakeRideRepo struct {
	mu sync.Mutex
	// status is what FindByID reports; keep it "pending" to let a ride fall
	// through to no_driver_available.
	status string
	// updateErr fails UpdateRideStatus (the persistence-outage case).
	updateErr error
	// assignErr fails AssignDriver (the accept-race case).
	assignErr error
	// findErr fails FindByID (the post-offer status-read outage case).
	findErr error

	statusUpdates []string
	assignments   []string
}

func (r *fakeRideRepo) CreateRide(*model.Ride) error { return nil }
func (r *fakeRideRepo) FindCurrentRideByRider(string) (*model.Ride, error) {
	return nil, repository.ErrNotFound
}
func (r *fakeRideRepo) FindCurrentRideByDriver(string) (*model.Ride, error) {
	return nil, repository.ErrNotFound
}
func (r *fakeRideRepo) FindRidesByRider(string, int, int) ([]model.Ride, int, error) {
	return nil, 0, nil
}
func (r *fakeRideRepo) FindRidesByDriver(string, int, int) ([]model.Ride, int, error) {
	return nil, 0, nil
}
func (r *fakeRideRepo) FindRatingsByRater(string, string, int, int) ([]model.Rating, int, error) {
	return nil, 0, nil
}
func (r *fakeRideRepo) CreateEvent(*model.RideEvent) error { return nil }
func (r *fakeRideRepo) CreateRating(*model.Rating) error   { return nil }
func (r *fakeRideRepo) FindStopsByRideID(string) ([]model.RideStop, error) {
	return nil, nil
}
func (r *fakeRideRepo) FindStopsByRideIDs([]string) (map[string][]model.RideStop, error) {
	return nil, nil
}
func (r *fakeRideRepo) ReplaceDestination(string, model.RideStop) error { return nil }
func (r *fakeRideRepo) FindVehicleByDriverID(string) (*model.DriverVehicle, error) {
	return nil, repository.ErrNotFound
}
func (r *fakeRideRepo) UpdateRideStatus(rideID, status string, _ *time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.updateErr != nil {
		return r.updateErr
	}
	r.statusUpdates = append(r.statusUpdates, status)
	r.status = status
	return nil
}
func (r *fakeRideRepo) AssignDriver(rideID, driverID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.assignErr != nil {
		return r.assignErr
	}
	r.assignments = append(r.assignments, driverID)
	return nil
}
func (r *fakeRideRepo) FindByID(id string) (*model.Ride, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.findErr != nil {
		return nil, r.findErr
	}
	status := r.status
	if status == "" {
		status = "pending"
	}
	return &model.Ride{ID: id, Status: status}, nil
}
func (r *fakeRideRepo) statusUpdateLog() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.statusUpdates...)
}

func (r *fakeRideRepo) assignmentLog() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.assignments...)
}

// fakeUserRepo is a UserRepository that knows no drivers. AcceptRide
// dereferences userRepo to build the rider-facing driver card, so a nil
// interface there panics the offer goroutine — a fake that returns "no such
// driver" keeps that path exercised and nil-safe.
type fakeUserRepo struct {
	repository.UserRepository
}

func (fakeUserRepo) FindDriverByID(id string) (*model.Driver, error) {
	return nil, repository.ErrNotFound
}

func (fakeUserRepo) FindByID(id string) (*model.User, error) {
	return &model.User{ID: id, Role: "rider"}, nil
}

// stubNavRepo satisfies NavigationRepository so NewDispatchService can be built
// without a real routing graph. The ETA computation in AcceptRide is
// best-effort and logs on failure, so an erroring stub is the safe choice.
type stubNavRepo struct{}

func (stubNavRepo) GetShortestPath(_, _, _, _ float64) ([]repository.RouteResult, error) {
	return nil, errors.New("stub nav repo: no graph in unit tests")
}

// fakeHub is a DriverHub whose connectivity the test controls directly, so the
// reconnect race is deterministic instead of timing-dependent.
type fakeHub struct {
	mu sync.Mutex
	// connected is the set of users with a live socket.
	connected map[string]bool
	// sent records every push in order, for assertions.
	sent []websocket.OutgoingMessage
	// sendTo records the recipient of each push.
	sendTo []string
}

func newFakeHub(connected ...string) *fakeHub {
	h := &fakeHub{connected: make(map[string]bool, len(connected))}
	for _, u := range connected {
		h.connected[u] = true
	}
	return h
}

func (h *fakeHub) IsConnected(userID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.connected[userID]
}

func (h *fakeHub) SendToUser(userID string, msg interface{}) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sendTo = append(h.sendTo, userID)
	if om, ok := msg.(websocket.OutgoingMessage); ok {
		h.sent = append(h.sent, om)
	}
}

// connect registers a socket mid-flight, simulating a client that re-dials
// while the offer loop is in its reconnect backoff.
func (h *fakeHub) connect(userID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.connected[userID] = true
}

func (h *fakeHub) offersTo() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []string
	for _, om := range h.sent {
		if om.Type == "ride.offer" {
			if data, ok := om.Data.(map[string]string); ok {
				out = append(out, data["ride_id"])
			}
		}
	}
	return out
}

// rideUpdatesTo returns the ride.updated statuses pushed to userID, in order.
func (h *fakeHub) rideUpdatesTo(userID string) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []string
	for i, om := range h.sent {
		if h.sendTo[i] != userID || om.Type != "ride.updated" {
			continue
		}
		if data, ok := om.Data.(websocket.RideUpdateData); ok {
			out = append(out, data.Status)
		}
	}
	return out
}

// logCapture redirects the standard logger — the one the PRODUCTION terminal
// observer writes to — into a buffer, so a test can assert on the real emitted
// lines instead of replacing the observer and inspecting the trace object.
//
// It is a mutex-guarded buffer because the offer loop logs from its own
// goroutine while the test reads.
type logCapture struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (c *logCapture) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(p)
}

// linesContaining returns the captured lines holding substr.
func (c *logCapture) linesContaining(substr string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []string
	for _, line := range strings.Split(c.buf.String(), "\n") {
		if strings.Contains(line, substr) {
			out = append(out, line)
		}
	}
	return out
}

// captureLogs installs a capture on the standard logger for the test's
// duration. Tests in this package do not run in parallel, and the dispatcher
// goroutine's late writes simply land back on the real logger after restore.
func captureLogs(t *testing.T) *logCapture {
	t.Helper()
	c := &logCapture{}
	log.SetOutput(c)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return c
}

// awaitTerminalLines waits for the terminal line(s) of rideID to be captured and
// returns them. It cannot assert instantly: the recorder publishes to its
// observer AFTER releasing its lock, so the attempt can already be closed a
// moment before the line lands. Once one line arrives it waits a short quiet
// window before returning, because a second (duplicated) line is written by the
// same goroutine immediately after the first.
func awaitTerminalLines(t *testing.T, logs *logCapture, rideID string) []string {
	t.Helper()
	match := "ride=" + rideID + " outcome="
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if lines := logs.linesContaining(match); len(lines) > 0 {
			time.Sleep(50 * time.Millisecond)
			return logs.linesContaining(match)
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("no terminal dispatch line for ride %s within 5s; captured:\n%s",
		rideID, strings.Join(logs.linesContaining(rideID), "\n"))
	return nil
}

func newTestDispatch(geo *fakeGeoRepo, ride *fakeRideRepo, hub DriverHub) *DispatchService {
	// navSvc is wired to the erroring stub rather than left nil: the ETA lookup
	// in AcceptRide is best-effort and logs on failure, which keeps the offer
	// path realistic without a road graph.
	return NewDispatchService(ride, geo, fakeUserRepo{}, hub, NewNavigationService(stubNavRepo{}))
}

// awaitOfferAndAccept reproduces what the WebSocket handler does on an accept:
// it finds the parked offer channel and signals it. It polls because the
// offer is registered a moment after Dispatch returns.
func awaitOfferAndAccept(t *testing.T, svc *DispatchService, rideID, driverID string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		svc.offerChannelsMu.Lock()
		ch, ok := svc.offerChannels[rideID]
		svc.offerChannelsMu.Unlock()
		if ok {
			ch <- true
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Errorf("no offer was registered for ride %s to driver %s", rideID, driverID)
}

// awaitAssignments blocks until the fake repository records n assignments, or
// fails. Assignment is a WRITE, so its presence is the proof the ride was
// actually served rather than merely attempted.
func awaitAssignments(t *testing.T, ride *fakeRideRepo, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if got := len(ride.assignmentLog()); got >= n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Errorf("assignments = %v, want %d", ride.assignmentLog(), n)
}

// awaitNoOpenTraces blocks until every in-flight dispatch attempt has been
// closed and published. The offer loop records its assignment write before it
// closes the trace, so a test that waits only on the write races the
// bookkeeping and flakes under -race.
func awaitNoOpenTraces(t *testing.T, svc *DispatchService) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if svc.traceRecorder().pending() == 0 {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Errorf("open traces = %d after 5s, want 0", svc.traceRecorder().pending())
}

// awaitOfferChannel polls for the live offer channel of rideID and returns it
// together with a predicate that must hold before acting on it, so a test that
// answers two offers in a row never re-uses the first offer's stale channel
// (the loop deletes and re-registers it per candidate).
func awaitOfferChannel(t *testing.T, svc *DispatchService, rideID string, isNewerThan chan bool) chan bool {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		svc.offerChannelsMu.Lock()
		ch, ok := svc.offerChannels[rideID]
		svc.offerChannelsMu.Unlock()
		if ok && (isNewerThan == nil || ch != isNewerThan) {
			return ch
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("no offer was registered for ride %s", rideID)
	return nil
}

// declineThenAccept answers the first offer with a decline and the second with an
// accept, reproducing "the first candidate said no, the next one took it".
func declineThenAccept(t *testing.T, svc *DispatchService, rideID string) {
	t.Helper()
	first := awaitOfferChannel(t, svc, rideID, nil)
	first <- false
	second := awaitOfferChannel(t, svc, rideID, first)
	second <- true
}

func pendingRide(id string) *model.Ride {
	return &model.Ride{ID: id, RiderID: "rider-1", Status: "pending", PickupLat: 9.93, PickupLng: -84.08}
}

// collectTraces replaces the trace observer and returns a channel of traces, so
// a test can await the terminal line of a ride whose offer loop runs in a
// goroutine. The channel is buffered generously: the recorder publishes at
// most one trace per ride, but a leak check in several tests depends on that
// not blocking.
func collectTraces(s *DispatchService, n int) <-chan dispatchTrace {
	ch := make(chan dispatchTrace, n)
	s.observeDispatchTraces(func(t dispatchTrace) { ch <- t })
	return ch
}

func awaitTrace(t *testing.T, ch <-chan dispatchTrace) dispatchTrace {
	t.Helper()
	select {
	case tr := <-ch:
		return tr
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the terminal dispatch trace")
		return dispatchTrace{}
	}
}

// TestDispatchGenuinelyNoCandidatesWidensEveryRadius pins the honest "nobody
// around" case: the search must try all five radii and the trace must say
// candidates=0. This is the outcome that must NOT be confused with the bug.
func TestDispatchGenuinelyNoCandidatesWidensEveryRadius(t *testing.T) {
	geo := &fakeGeoRepo{}
	ride := &fakeRideRepo{}
	svc := newTestDispatch(geo, ride, newFakeHub())
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-empty")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	tr := awaitTrace(t, traces)

	if got := geo.findCount(); got != 5 {
		t.Errorf("FindNearbyDrivers called %d times, want 5 (500/1k/2k/5k/10km)", got)
	}
	if tr.Candidates != 0 {
		t.Errorf("Candidates = %d, want 0", tr.Candidates)
	}
	if tr.Outcome() != "no_candidates" {
		t.Errorf("Outcome = %q, want %q", tr.Outcome(), "no_candidates")
	}
	if len(tr.Skips) != 0 {
		t.Errorf("Skips = %v, want none: nobody was a candidate", tr.Skips)
	}
	// The terminal persistence must still happen, and only once.
	if got := ride.statusUpdateLog(); len(got) != 1 || got[0] != "no_driver_available" {
		t.Errorf("status updates = %v, want [no_driver_available]", got)
	}
}

// TestDispatchSearchErrorIsNotReportedAsNoDrivers is the "distinguish a genuine
// service-area miss from a failed search" requirement. A search failure must
// propagate as an error (so the ride create fails loudly) and must be recorded
// as its own outcome — never as "no drivers".
func TestDispatchSearchErrorIsNotReportedAsNoDrivers(t *testing.T) {
	geo := &fakeGeoRepo{findErr: errors.New("connection refused")}
	ride := &fakeRideRepo{}
	svc := newTestDispatch(geo, ride, newFakeHub())
	traces := collectTraces(svc, 1)

	err := svc.Dispatch(pendingRide("ride-searchfail"))
	if err == nil {
		t.Fatal("Dispatch must propagate the search error, not swallow it")
	}
	tr := awaitTrace(t, traces)

	if tr.Outcome() != "search_failed" {
		t.Errorf("Outcome = %q, want %q", tr.Outcome(), "search_failed")
	}
	if tr.SearchErr == nil {
		t.Error("SearchErr must be recorded on the trace")
	}
	if got := ride.statusUpdateLog(); len(got) != 0 {
		t.Errorf("status updates = %v, want none: a failed search must NOT be persisted as no_driver_available", got)
	}
}

// TestDispatchSkipsDriverWithNoSocketAndRetries is the core false-negative
// regression at the unit level. The search found a DB-fresh driver, but the hub
// had no socket, so the old code hard-skipped them; the ride then exhausted
// with no_driver_available even though "a driver was online".
//
// The fix has two parts and both are asserted here:
//  1. the skip is RETRIED against the hub before giving up, and
//  2. the reason is recorded, so candidates=1 + reason=socket_not_connected is
//     distinguishable from candidates=0.
func TestDispatchSkipsDriverWithNoSocketAndRetries(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-offline-socket"}}}
	ride := &fakeRideRepo{}
	svc := newTestDispatch(geo, ride, newFakeHub())
	traces := collectTraces(svc, 1)

	start := time.Now()
	if err := svc.Dispatch(pendingRide("ride-nosocket")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	tr := awaitTrace(t, traces)
	elapsed := time.Since(start)

	// The retry must actually cost time: a hard skip returned immediately.
	if elapsed < time.Duration(socketBackoffAttempts-1)*socketBackoffDelay {
		t.Errorf("skip took %s, want >= %s: the hub must be retried before giving up",
			elapsed, time.Duration(socketBackoffAttempts-1)*socketBackoffDelay)
	}
	// And it must stay far below the offer timeout, so the happy path is
	// unaffected.
	if elapsed >= offerTimeout {
		t.Errorf("skip took %s, must stay well under the %s offer timeout", elapsed, offerTimeout)
	}

	if tr.Candidates != 1 {
		t.Fatalf("Candidates = %d, want 1: the search found a driver, which is the whole point", tr.Candidates)
	}
	if tr.Outcome() != "candidates_skipped" {
		t.Errorf("Outcome = %q, want %q", tr.Outcome(), "candidates_skipped")
	}
	reasons := tr.ReasonCounts()
	// ONE skip per candidate: the reconnect retries are retry detail on that
	// skip, not four separate skips. A tally that counted retries would report
	// skipped=4 for a single driver, which is the kind of overstatement that
	// makes a support trace unreadable.
	if reasons[skipSocketNotConnected] != 1 {
		t.Errorf("ReasonCounts = %v, want exactly %d x %q (retries are detail, not extra skips)",
			reasons, 1, skipSocketNotConnected)
	}
	if len(tr.Skips) != 1 {
		t.Fatalf("Skips = %v, want exactly 1 entry for 1 candidate", tr.Skips)
	}
	// The retry count must still be visible in the detail, so the backoff is
	// auditable from the terminal line alone.
	if !strings.Contains(tr.Skips[0].Detail, "4") {
		t.Errorf("skip detail = %q, want it to record that 4 reconnect attempts were made", tr.Skips[0].Detail)
	}
	if got := ride.statusUpdateLog(); len(got) != 1 || got[0] != "no_driver_available" {
		t.Errorf("status updates = %v, want [no_driver_available]", got)
	}
}

// TestDispatchSocketRetrySucceedsWhenDriverConnectsDuringBackoff is the payoff
// case: the driver was in the search, the socket was mid-handshake, and the
// retry catches it. Under the old hard-skip this ride got no driver at all —
// the exact reported bug. Here the offer is delivered, so the ride must be
// accepted rather than exhausted.
func TestDispatchSocketRetrySucceedsWhenDriverConnectsDuringBackoff(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-reconnecting"}}}
	ride := &fakeRideRepo{}
	hub := newFakeHub() // not connected yet
	svc := newTestDispatch(geo, ride, hub)
	// The observer is a test that a reconnected driver is never reported as
	// "nobody around"; an accept publishes a different line than the
	// no_driver_available one, so it is captured rather than consumed.
	var outcomes []string
	var outcomeMu sync.Mutex
	svc.observeDispatchTraces(func(tr dispatchTrace) {
		outcomeMu.Lock()
		defer outcomeMu.Unlock()
		outcomes = append(outcomes, tr.Outcome())
	})

	// The driver re-dials while the offer loop is still in its reconnect
	// backoff — the race the old hard-skip lost every time.
	go func() {
		time.Sleep(socketBackoffDelay / 2)
		hub.connect("driver-reconnecting")
	}()

	if err := svc.Dispatch(pendingRide("ride-reconnect")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	// The offer is now parked in offerRideToDriver's select. Accept it, exactly
	// as the WS handler would.
	go awaitOfferAndAccept(t, svc, "ride-reconnect", "driver-reconnecting")

	// The ride is accepted, so the terminal trace must not say the driver was
	// skipped. The assignment is recorded BEFORE the offer loop closes the
	// trace, so waiting on the write alone races the bookkeeping — wait for the
	// recorder to go idle instead.
	awaitAssignments(t, ride, 1)
	awaitNoOpenTraces(t, svc)

	if got := hub.offersTo(); len(got) != 1 || got[0] != "ride-reconnect" {
		t.Errorf("offers delivered = %v, want [ride-reconnect] (the retry must reach the reconnected driver)", got)
	}
	if got := ride.assignmentLog(); len(got) != 1 || got[0] != "driver-reconnecting" {
		t.Errorf("assignments = %v, want [driver-reconnecting]", got)
	}
	if got := ride.statusUpdateLog(); len(got) != 0 {
		t.Errorf("status updates = %v, want none: an accepted ride must not be marked no_driver_available", got)
	}
	outcomeMu.Lock()
	defer outcomeMu.Unlock()
	for _, o := range outcomes {
		if o == "no_candidates" || o == "candidates_skipped" {
			t.Errorf("terminal outcome = %q: a driver who reconnected during the backoff "+
				"must not be recorded as dropped", o)
		}
	}
}

// TestDispatchNoDriverAvailableWhenPersistenceFails pins "a failed write never
// answers success": when the terminal no_driver_available write fails, the ride
// must NOT be left claiming a status it did not persist, and the failure must
// be reported as its OWN outcome — not as the honest no_candidates a genuinely
// empty search produces (bug #19).
func TestDispatchNoDriverAvailableWhenPersistenceFails(t *testing.T) {
	geo := &fakeGeoRepo{}
	ride := &fakeRideRepo{updateErr: errors.New("db down")}
	svc := newTestDispatch(geo, ride, newFakeHub())
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-writefail")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	tr := awaitTrace(t, traces)
	// The trace is published even though the write failed, so support can see
	// the ride really was empty rather than wondering where it went — and the
	// failed write is distinguishable from a clean empty search.
	if tr.Outcome() != "terminal_write_failed" {
		t.Errorf("Outcome = %q, want %q", tr.Outcome(), "terminal_write_failed")
	}
	if tr.TerminalErr == nil {
		t.Error("TerminalErr must be recorded so the failed write is not mistaken for no_candidates")
	}
	if got := ride.statusUpdateLog(); len(got) != 0 {
		t.Errorf("status updates = %v, want none recorded (the write failed)", got)
	}
}

// TestDispatchStatusReadFailureIsNotReportedAsNotPending covers the other
// unexpected exit: after the candidates were exhausted, FindByID (the check
// that decides between retrying and not_pending) fails. The old code recorded
// not_pending, claiming the ride was taken elsewhere when in fact we could not
// tell. It must instead publish a terminal_write_failed trace carrying the
// cause, so no exit path is left without an honest terminal outcome (bug #19).
func TestDispatchStatusReadFailureIsNotReportedAsNotPending(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	ride := &fakeRideRepo{findErr: errors.New("read timeout")}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, ride, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-readfail")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	// The candidate declines, so the loop reaches the status check.
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			svc.offerChannelsMu.Lock()
			ch, ok := svc.offerChannels["ride-readfail"]
			svc.offerChannelsMu.Unlock()
			if ok {
				ch <- false
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	tr := awaitTrace(t, traces)
	if tr.Outcome() != "terminal_write_failed" {
		t.Errorf("Outcome = %q, want %q: a failed status read must not be reported as not_pending",
			tr.Outcome(), "terminal_write_failed")
	}
	if tr.TerminalErr == nil {
		t.Error("TerminalErr must carry the status-read failure")
	}
}

// TestDispatchEveryExitPathHasATerminalOutcome is the bug #19 property:
// whatever way an attempt ends, the published trace names an explicit terminal
// outcome. "candidates_unprocessed" is the one value that means "this attempt
// was recorded without a terminal outcome"; no real exit path may produce it.
func TestDispatchEveryExitPathHasATerminalOutcome(t *testing.T) {
	terminal := map[string]bool{
		"search_failed":          true,
		"accepted":               true,
		"not_pending":            true,
		"terminal_write_failed":  true,
		"no_candidates":          true,
		"candidates_skipped":     true,
		"candidates_unprocessed": false,
	}
	cases := []struct {
		name   string
		geo    *fakeGeoRepo
		ride   *fakeRideRepo
		hub    *fakeHub
		accept bool
	}{
		{"search error", &fakeGeoRepo{findErr: errors.New("search down")}, &fakeRideRepo{}, newFakeHub(), false},
		{"no candidates, clean write", &fakeGeoRepo{}, &fakeRideRepo{}, newFakeHub(), false},
		{"no candidates, failed write", &fakeGeoRepo{}, &fakeRideRepo{updateErr: errors.New("db down")}, newFakeHub(), false},
		{"candidate dropped, clean write", &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "d"}}}, &fakeRideRepo{}, newFakeHub(), false},
		{"candidate dropped, failed write", &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "d"}}}, &fakeRideRepo{updateErr: errors.New("db down")}, newFakeHub(), false},
		{"candidate accepted", &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "d"}}}, &fakeRideRepo{}, newFakeHub("d"), true},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rideID := fmt.Sprintf("ride-exit-%d", i)
			svc := newTestDispatch(tc.geo, tc.ride, tc.hub)
			traces := collectTraces(svc, 1)
			// A search failure is the one path Dispatch returns an error on; the
			// trace is still published, so await it rather than aborting.
			_ = svc.Dispatch(pendingRide(rideID))
			if tc.accept {
				go awaitOfferAndAccept(t, svc, rideID, "d")
			}
			tr := awaitTrace(t, traces)
			if !terminal[tr.Outcome()] {
				t.Errorf("Outcome = %q, want a terminal outcome; %q means the attempt was "+
					"recorded with no terminal state", tr.Outcome(), "candidates_unprocessed")
			}
		})
	}
}

// TestDispatchFailedTerminalWriteDoesNotPushTheRider pins the sequential path:
// every candidate was offered and lost, the ride is still pending, and then the
// terminal no_driver_available write FAILS.
//
// The rider must NOT be told. The database still holds a pending ride, so a
// no_driver_available push tells the rider their ride is dead while the stored
// state says otherwise — and nothing ever retries the push. This is the branch
// the `return` after the failed persist used to guard in the sequential loop
// (and it is still reachable from the zero-candidate path, which pushes
// unconditionally at the pre-fix HEAD).
//
// The trace is still published: the ride really did run out of drivers, and
// support needs to see that even though the write did not land.
func TestDispatchFailedTerminalWriteDoesNotPushTheRider(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	ride := &fakeRideRepo{
		// The candidate accepts, then loses the assignment race — so the loop
		// exhausts its candidates with the ride still pending.
		assignErr: lostAcceptRaceErr(),
		// ...and the terminal write then fails.
		updateErr: errors.New("db down"),
	}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, ride, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-seqwritefail")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	go awaitOfferAndAccept(t, svc, "ride-seqwritefail", "driver-a")

	// The trace is published from a defer AFTER the write settles, so once it
	// arrives the push decision has already been made.
	tr := awaitTrace(t, traces)

	if len(tr.Skips) != 1 || tr.Skips[0].Reason != skipAcceptFailed {
		t.Fatalf("Skips = %v, want exactly 1 x %q (the candidate was offered)", tr.Skips, skipAcceptFailed)
	}
	if got := ride.statusUpdateLog(); len(got) != 0 {
		t.Errorf("status updates = %v, want none: the terminal write failed", got)
	}
	if got := hub.rideUpdatesTo("rider-1"); len(got) != 0 {
		t.Errorf("ride.updated pushed to the rider = %v, want none: the ride is still "+
			"pending in the database, so a failed write must not be announced as an outcome", got)
	}
}

// TestDispatchAcceptConflictKeepsSearching proves a lost accept race is recorded
// as its own reason and the loop moves on, rather than being swallowed as a
// plain decline (the old code logged it and continued, leaving the trace
// claiming the driver was never offered).
//
// The fake fails AssignDriver with the error the PRODUCTION repository returns
// for that race (repository.ErrConflict wrapped by ride_repo.go's
// "accept ride: %w: %w"), not with the service's own conflict type. Feeding the
// mock the service type would let a classifier that only matches that type pass
// while every real race was logged as a plain accept failure.
func TestDispatchAcceptConflictKeepsSearching(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-a"}}}
	ride := &fakeRideRepo{assignErr: lostAcceptRaceErr()}
	hub := newFakeHub("driver-a")
	svc := newTestDispatch(geo, ride, hub)
	traces := collectTraces(svc, 1)

	if err := svc.Dispatch(pendingRide("ride-conflict")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	// The driver ACCEPTS — the offer must be answered, or it would sit until the
	// 30s timeout and record the wrong reason. The failure comes from the
	// assignment write, which is the race being modelled.
	go awaitOfferAndAccept(t, svc, "ride-conflict", "driver-a")

	tr := awaitTrace(t, traces)

	reasons := tr.ReasonCounts()
	if reasons[skipAcceptFailed] != 1 {
		t.Errorf("ReasonCounts = %v, want %d x %q", reasons, 1, skipAcceptFailed)
	}
	// The lost race must be distinguishable from a decline.
	if reasons[skipDriverDeclined] != 0 {
		t.Errorf("ReasonCounts = %v: a lost accept race must not be recorded as a decline", reasons)
	}
	// And from a real accept failure: the detail is the only place the two are
	// told apart, and it is written by errIsConflict.
	if len(tr.Skips) != 1 {
		t.Fatalf("Skips = %v, want exactly 1", tr.Skips)
	}
	if got := tr.Skips[0].Detail; got != "another driver already took the ride" {
		t.Errorf("skip detail = %q, want %q: repository.ErrConflict must be classified "+
			"as a lost race, not as a plain accept failure", got, "another driver already took the ride")
	}
}

// lostAcceptRaceErr is the error the production repository returns when a second
// driver's AssignDriver loses the race: rows == 0 from
// `UPDATE rides ... WHERE id=$2 AND status='pending'` becomes
// fmt.Errorf("accept ride: %w: %w", ErrConflict, sql.ErrNoRows)
// (internal/repository/ride_repo.go AssignDriver).
func lostAcceptRaceErr() error {
	return fmt.Errorf("accept ride: %w: %w", repository.ErrConflict, sql.ErrNoRows)
}

// TestErrIsConflictMatchesTheRealRepositoryError pins the classifier to the
// errors the repository layer can actually produce, so the string "another driver
// already took the ride" is reachable for the case it was written for.
func TestErrIsConflictMatchesTheRealRepositoryError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"lost accept race", lostAcceptRaceErr(), true},
		{"in-process status check", errConflict, true},
		{"pq unique violation wrapped by wrapDB",
			fmt.Errorf("assign driver: %w: %w", repository.ErrConflict,
				&pq.Error{Code: "23505"}), true},
		{"real database outage", fmt.Errorf("assign driver: %w", errors.New("dial tcp: refused")), false},
		{"nil", nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := errIsConflict(tc.err); got != tc.want {
				t.Errorf("errIsConflict(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

// TestDispatchTraceRecorderIsIdempotentAndLeaksNothing guards the recorder
// itself: a ride must publish exactly one terminal trace, and no attempt may be
// left open (an open attempt would make a support query wait forever and would
// grow without bound).
func TestDispatchTraceRecorderIsIdempotentAndLeaksNothing(t *testing.T) {
	r := newDispatchTraceRecorder(func(dispatchTrace) {})
	r.begin("ride-1", 3)
	r.append("ride-1", offerSkip{DriverID: "d1", Reason: skipSocketNotConnected})
	r.append("ride-1", offerSkip{DriverID: "d2", Reason: skipDriverDeclined})

	first, ok := r.end("ride-1")
	if !ok {
		t.Fatal("first end must publish the trace")
	}
	if len(first.Skips) != 2 {
		t.Errorf("Skips = %d, want 2", len(first.Skips))
	}
	if first.Candidates != 3 {
		t.Errorf("Candidates = %d, want 3", first.Candidates)
	}
	// Ending twice (an accept racing the no-driver path) must not double-publish.
	if _, ok := r.end("ride-1"); ok {
		t.Error("second end must not publish again")
	}
	if r.pending() != 0 {
		t.Errorf("pending = %d, want 0: end must release the attempt", r.pending())
	}
	// Ending an unknown ride is inert, not a panic.
	if _, ok := r.end("never-began"); ok {
		t.Error("end of an unknown ride must not publish")
	}
}

// TestDispatchTraceRecorderAbortClosesAnOpenAttempt pins the safety net: an
// attempt that unwinds without a terminal state (a panic, or a future early
// return) is closed and published with a terminal outcome, and no attempt is
// left open. A second abort is inert.
func TestDispatchTraceRecorderAbortClosesAnOpenAttempt(t *testing.T) {
	var published []dispatchTrace
	r := newDispatchTraceRecorder(func(tr dispatchTrace) { published = append(published, tr) })
	r.begin("ride-abandoned", 2)
	r.abortIfOpen("ride-abandoned", errDispatchAborted)

	if len(published) != 1 {
		t.Fatalf("published = %d traces, want 1", len(published))
	}
	if got := published[0].Outcome(); got != "terminal_write_failed" {
		t.Errorf("Outcome = %q, want %q for an abandoned attempt", got, "terminal_write_failed")
	}
	if published[0].TerminalErr == nil {
		t.Error("TerminalErr must carry the abandonment cause")
	}
	if r.pending() != 0 {
		t.Errorf("pending = %d, want 0: an aborted attempt must not leak", r.pending())
	}
	r.abortIfOpen("ride-abandoned", errDispatchAborted)
	if len(published) != 1 {
		t.Errorf("published = %d traces after a second abort, want 1", len(published))
	}
}

// TestDispatchTraceStringIsStableAndComplete pins the log line a support query
// greps for. The exact wording is part of the contract, so it is asserted
// rather than eyeballed.
func TestDispatchTraceStringIsStableAndComplete(t *testing.T) {
	cases := []struct {
		name string
		tr   dispatchTrace
		want string
	}{
		{
			name: "genuinely empty",
			tr:   dispatchTrace{RideID: "r1", Candidates: 0},
			want: "[dispatch] ride=r1 outcome=no_candidates candidates=0 skipped=0 reasons={}",
		},
		{
			name: "candidates dropped",
			tr: dispatchTrace{RideID: "r2", Candidates: 2, Skips: []offerSkip{
				{DriverID: "d1", Reason: skipSocketNotConnected},
				{DriverID: "d2", Reason: skipSocketNotConnected},
			}},
			want: "[dispatch] ride=r2 outcome=candidates_skipped candidates=2 skipped=2 reasons={socket_not_connected=2}",
		},
		{
			name: "search failure carries the cause",
			tr:   dispatchTrace{RideID: "r3", SearchErr: errors.New("conn refused")},
			want: "[dispatch] ride=r3 outcome=search_failed candidates=0 skipped=0 reasons={} search_err=conn refused",
		},
		{
			name: "accepted carries the skips that preceded it",
			tr: dispatchTrace{RideID: "r4", Candidates: 2, Accepted: true, Skips: []offerSkip{
				{DriverID: "d1", Reason: skipDriverDeclined, Detail: "driver declined"},
			}},
			want: "[dispatch] ride=r4 outcome=accepted candidates=2 skipped=1 reasons={driver_declined=1}",
		},
		{
			name: "ride taken elsewhere",
			tr: dispatchTrace{RideID: "r5", Candidates: 2, NotPending: true, Skips: []offerSkip{
				{DriverID: "d1", Reason: skipSocketNotConnected},
			}},
			want: "[dispatch] ride=r5 outcome=not_pending candidates=2 skipped=1 reasons={socket_not_connected=1}",
		},
		{
			name: "failed terminal write carries the cause",
			tr:   dispatchTrace{RideID: "r6", TerminalErr: errors.New("db down")},
			want: "[dispatch] ride=r6 outcome=terminal_write_failed candidates=0 skipped=0 reasons={} terminal_err=db down",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.tr.String(); got != tc.want {
				t.Errorf("String() =\n  %q\nwant\n  %q", got, tc.want)
			}
		})
	}
}

// TestDispatchOutcomeNamesAreDistinct is the property the whole file exists to
// provide: support must be able to tell every terminal state apart at a glance,
// and none of them may share a name.
func TestDispatchOutcomeNamesAreDistinct(t *testing.T) {
	traces := []dispatchTrace{
		{RideID: "a", Candidates: 0},
		{RideID: "b", Candidates: 1, Skips: []offerSkip{{Reason: skipSocketNotConnected}}},
		{RideID: "c", SearchErr: errors.New("x")},
		{RideID: "d", Candidates: 2},
		{RideID: "e", Candidates: 2, Accepted: true},
		{RideID: "f", Candidates: 2, NotPending: true},
		{RideID: "g", TerminalErr: errors.New("write failed")},
	}
	seen := map[string]string{}
	for _, tr := range traces {
		out := tr.Outcome()
		if prev, dup := seen[out]; dup {
			t.Errorf("outcome %q is shared by %q and %q; outcomes must be distinguishable", out, prev, tr.RideID)
		}
		seen[out] = tr.RideID
	}
	if len(seen) != len(traces) {
		t.Errorf("got %d distinct outcomes for %d traces", len(seen), len(traces))
	}
}

// The three tests below deliberately KEEP the production observer
// (logDispatchTrace, installed by NewDispatchService). Every other dispatch test
// replaces it with collectTraces, which is why the duplicated terminal line —
// the observer publishing AND a hand-written log line at the same call site —
// was invisible to the suite. These read the real emitted lines instead.

// TestDispatchPublishesExactlyOneTerminalLine pins that an attempt ending with
// no candidates writes ONE terminal line. The observer publishes it; nothing
// else may.
func TestDispatchPublishesExactlyOneTerminalLine(t *testing.T) {
	geo := &fakeGeoRepo{}
	ride := &fakeRideRepo{}
	svc := newTestDispatch(geo, ride, newFakeHub())
	logs := captureLogs(t)

	if err := svc.Dispatch(pendingRide("ride-once")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	terminal := awaitTerminalLines(t, logs, "ride-once")
	if len(terminal) != 1 {
		t.Fatalf("terminal lines = %d, want exactly 1:\n%s", len(terminal), strings.Join(terminal, "\n"))
	}
	if !strings.Contains(terminal[0], "outcome=no_candidates") {
		t.Errorf("terminal line = %q, want outcome=no_candidates", terminal[0])
	}
}

// TestDispatchAcceptPublishesExactlyOneAcceptedTerminalLine pins the accept
// path: the trace must carry its own accepted outcome. The regression it
// guards is two contradictory lines under the same key — outcome=accepted from
// the offer loop and outcome=candidates_unprocessed from the observer, both
// claiming to be the terminal line of the same ride.
func TestDispatchAcceptPublishesExactlyOneAcceptedTerminalLine(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{
		{DriverID: "driver-a"}, {DriverID: "driver-b"},
	}}
	ride := &fakeRideRepo{}
	hub := newFakeHub("driver-a", "driver-b")
	svc := newTestDispatch(geo, ride, hub)
	logs := captureLogs(t)

	if err := svc.Dispatch(pendingRide("ride-accept-once")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	// The first candidate declines; the second accepts, so the trace must end
	// with one skip AND the accepted outcome.
	go declineThenAccept(t, svc, "ride-accept-once")

	awaitAssignments(t, ride, 1)
	awaitNoOpenTraces(t, svc)

	terminal := awaitTerminalLines(t, logs, "ride-accept-once")
	if len(terminal) != 1 {
		t.Fatalf("terminal lines = %d, want exactly 1:\n%s", len(terminal), strings.Join(terminal, "\n"))
	}
	if !strings.Contains(terminal[0], "outcome=accepted") {
		t.Errorf("terminal line = %q, want outcome=accepted: the accepted state is recorded "+
			"on the trace, not inferred from the skip tally", terminal[0])
	}
	if !strings.Contains(terminal[0], "skipped=1") {
		t.Errorf("terminal line = %q, want skipped=1 (the decline that preceded the accept)", terminal[0])
	}
}

// TestSocketWaitLogsRetriesWithoutTheSkipVerb pins the verb split. A driver who
// reconnects during the backoff IS offered the ride, so logging his recovery
// with the skip verb contradicts the terminal line and makes
// `grep -c "skip driver="` over-count the dropped candidates.
func TestSocketWaitLogsRetriesWithoutTheSkipVerb(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-late"}}}
	ride := &fakeRideRepo{}
	hub := newFakeHub() // not connected yet
	svc := newTestDispatch(geo, ride, hub)
	logs := captureLogs(t)

	go func() {
		time.Sleep(socketBackoffDelay / 2)
		hub.connect("driver-late")
	}()

	if err := svc.Dispatch(pendingRide("ride-reconnect-verb")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	go awaitOfferAndAccept(t, svc, "ride-reconnect-verb", "driver-late")
	awaitAssignments(t, ride, 1)
	awaitNoOpenTraces(t, svc)

	if skips := logs.linesContaining("ride=ride-reconnect-verb skip driver="); len(skips) != 0 {
		t.Errorf("skip lines = %d, want 0: the driver reconnected and was offered the ride:\n%s",
			len(skips), strings.Join(skips, "\n"))
	}
	if retries := logs.linesContaining("ride=ride-reconnect-verb socket-wait driver="); len(retries) == 0 {
		t.Error("no socket-wait progress line: the reconnect backoff must stay auditable")
	}
}

// TestSocketWaitRecordsOneSkipForADroppedDriver is the other half of the same
// invariant: a driver who never comes back IS one skip, and his N reconnect
// polls must not inflate it to N log lines.
func TestSocketWaitRecordsOneSkipForADroppedDriver(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-gone"}}}
	ride := &fakeRideRepo{}
	svc := newTestDispatch(geo, ride, newFakeHub())
	logs := captureLogs(t)

	if err := svc.Dispatch(pendingRide("ride-dropped-verb")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	awaitNoOpenTraces(t, svc)

	skips := logs.linesContaining("ride=ride-dropped-verb skip driver=")
	if len(skips) != 1 {
		t.Errorf("skip lines = %d, want exactly 1 for one dropped driver:\n%s",
			len(skips), strings.Join(skips, "\n"))
	}
	retries := len(logs.linesContaining("ride=ride-dropped-verb socket-wait driver="))
	if retries != socketBackoffAttempts {
		t.Errorf("socket-wait lines = %d, want %d (one per poll)", retries, socketBackoffAttempts)
	}
}
