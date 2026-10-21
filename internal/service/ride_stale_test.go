package service

import (
	"errors"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
)

// fakePendingRepo implements ONLY repository.PendingRideRepository — the narrow
// surface the sweeper needs (api_plans/[rides]_orphaned_pending_expiry.md). It
// deliberately does not implement the full RideRepository.
type fakePendingRepo struct {
	// mu makes the fake safe for the ticker tests, which read its state while
	// Start's goroutine is still calling into it.
	mu       sync.Mutex
	ttl      time.Duration
	statuses map[string]string
	created  map[string]time.Time

	pendingErr error
	staleErr   error
	eventErr   error

	// lostCAS makes the CAS report (false, nil) and move the row to accepted,
	// simulating a concurrent accept that won the race.
	lostCAS map[string]bool
	// closeCASErr makes the CAS for an id fail (a real repository failure).
	closeCASErr map[string]error

	bootListCalls int
	tickListCalls int
	casCalls      []casCall
	events        []*model.RideEvent
}

type casCall struct {
	id           string
	expectedFrom []string
	status       string
}

func newFakePendingRepo(ttl time.Duration) *fakePendingRepo {
	return &fakePendingRepo{
		ttl:         ttl,
		statuses:    map[string]string{},
		created:     map[string]time.Time{},
		lostCAS:     map[string]bool{},
		closeCASErr: map[string]error{},
	}
}

func (f *fakePendingRepo) seed(id, status string, age time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.statuses[id] = status
	f.created[id] = time.Now().Add(-age)
}

// statusOf, listCallCounts and eventCount snapshot state under the lock for the
// ticker tests, whose goroutine may still be sweeping.
func (f *fakePendingRepo) statusOf(id string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.statuses[id]
}

func (f *fakePendingRepo) listCallCounts() (boot, tick int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bootListCalls, f.tickListCalls
}

func (f *fakePendingRepo) eventCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.events)
}

func (f *fakePendingRepo) FindPendingRideIDs() ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.bootListCalls++
	if f.pendingErr != nil {
		return nil, f.pendingErr
	}
	var ids []string
	for id, st := range f.statuses {
		if st == "pending" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (f *fakePendingRepo) FindStalePendingRideIDs() ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tickListCalls++
	if f.staleErr != nil {
		return nil, f.staleErr
	}
	cutoff := time.Now().Add(-f.ttl)
	var ids []string
	for id, st := range f.statuses {
		if st == "pending" && !f.created[id].After(cutoff) {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (f *fakePendingRepo) UpdateRideStatusFrom(id string, expectedFrom []string, status string, _ *time.Time) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.casCalls = append(f.casCalls, casCall{id: id, expectedFrom: append([]string(nil), expectedFrom...), status: status})
	if err := f.closeCASErr[id]; err != nil {
		return false, err
	}
	if f.lostCAS[id] {
		f.statuses[id] = "accepted"
		return false, nil
	}
	matched := false
	for _, from := range expectedFrom {
		if f.statuses[id] == from {
			matched = true
			break
		}
	}
	if !matched {
		return false, nil
	}
	f.statuses[id] = status
	return true, nil
}

func (f *fakePendingRepo) CreateEvent(event *model.RideEvent) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.eventErr != nil {
		return f.eventErr
	}
	f.events = append(f.events, event)
	return nil
}

func TestPendingRideSweeperBootClosesEveryPendingRegardlessOfAge(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("fresh", "pending", time.Second)
	repo.seed("old", "pending", time.Hour)
	repo.seed("accepted", "accepted", time.Hour)

	NewPendingRideSweeper(repo, 10*time.Minute, time.Minute, true).sweepOnce("boot")

	for _, id := range []string{"fresh", "old"} {
		if got := repo.statuses[id]; got != "no_driver_available" {
			t.Errorf("status[%s] = %q, want no_driver_available", id, got)
		}
	}
	if got := repo.statuses["accepted"]; got != "accepted" {
		t.Errorf("accepted ride was touched: status = %q", got)
	}
	if repo.bootListCalls != 1 || repo.tickListCalls != 0 {
		t.Errorf("list calls = boot %d / tick %d, want boot 1 / tick 0", repo.bootListCalls, repo.tickListCalls)
	}
	if len(repo.casCalls) != 2 {
		t.Fatalf("CAS calls = %d, want exactly the two pending rows", len(repo.casCalls))
	}
	for _, call := range repo.casCalls {
		if len(call.expectedFrom) != 1 || call.expectedFrom[0] != "pending" {
			t.Errorf("CAS expectedFrom = %v, want exactly [pending]", call.expectedFrom)
		}
		if call.status != "no_driver_available" {
			t.Errorf("CAS target = %q, want no_driver_available", call.status)
		}
	}
	if len(repo.events) != 2 {
		t.Fatalf("events = %d, want 2", len(repo.events))
	}
	for _, e := range repo.events {
		if e.Actor != "system" || e.Reason != "boot_reconcile" {
			t.Errorf("event actor/reason = %q/%q, want system/boot_reconcile", e.Actor, e.Reason)
		}
		if e.FromStatus != "pending" || e.ToStatus != "no_driver_available" {
			t.Errorf("event transition = %s→%s, want pending→no_driver_available", e.FromStatus, e.ToStatus)
		}
	}
}

func TestPendingRideSweeperPeriodicClosesOnlyStale(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("young", "pending", 9*time.Minute)
	repo.seed("stale", "pending", 11*time.Minute)

	NewPendingRideSweeper(repo, 10*time.Minute, time.Minute, true).sweepOnce("tick")

	if got := repo.statuses["stale"]; got != "no_driver_available" {
		t.Errorf("stale status = %q, want no_driver_available", got)
	}
	if got := repo.statuses["young"]; got != "pending" {
		t.Errorf("young status = %q, want pending (never touched)", got)
	}
	if len(repo.events) != 1 || repo.events[0].RideID != "stale" {
		t.Fatalf("events = %+v, want exactly one for the stale ride", repo.events)
	}
	if repo.events[0].Reason != "stale_pending_sweep" {
		t.Errorf("reason = %q, want stale_pending_sweep", repo.events[0].Reason)
	}
	if repo.bootListCalls != 0 || repo.tickListCalls != 1 {
		t.Errorf("list calls = boot %d / tick %d, want boot 0 / tick 1", repo.bootListCalls, repo.tickListCalls)
	}
}

func TestPendingRideSweeperLostCASLeavesRowAndSkipsEvent(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("raced", "pending", time.Hour)
	repo.lostCAS["raced"] = true

	NewPendingRideSweeper(repo, 10*time.Minute, time.Minute, true).sweepOnce("tick")

	if got := repo.statuses["raced"]; got != "accepted" {
		t.Errorf("status = %q, want accepted (the concurrent accept wins)", got)
	}
	if len(repo.events) != 0 {
		t.Errorf("events = %+v, want none for a lost CAS", repo.events)
	}
	if len(repo.casCalls) != 1 {
		t.Errorf("CAS calls = %d, want 1", len(repo.casCalls))
	}
}

func TestPendingRideSweeperListErrorIsLoggedAndNonFatal(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("pending", "pending", time.Hour)
	repo.staleErr = errors.New("dial tcp: connection refused")

	s := NewPendingRideSweeper(repo, 10*time.Minute, time.Minute, true)
	s.sweepOnce("tick")

	if len(repo.casCalls) != 0 || len(repo.events) != 0 {
		t.Errorf("a list error wrote rows: cas=%d events=%d", len(repo.casCalls), len(repo.events))
	}
	if repo.tickListCalls != 1 {
		t.Fatalf("tick list calls = %d, want 1", repo.tickListCalls)
	}

	repo.staleErr = nil
	s.sweepOnce("tick")
	if repo.tickListCalls != 2 {
		t.Errorf("tick list calls after retry = %d, want 2", repo.tickListCalls)
	}
	if got := repo.statuses["pending"]; got != "no_driver_available" {
		t.Errorf("retry did not close the ride: status = %q", got)
	}
}

func TestPendingRideSweeperStartRunsBootBeforeReturning(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("pending", "pending", time.Hour)

	// A long interval keeps the ticker out of this test's assertions.
	s := NewPendingRideSweeper(repo, 10*time.Minute, time.Hour, true)
	s.Start()
	if repo.bootListCalls != 1 {
		t.Fatalf("boot list calls at Start return = %d, want 1 (boot runs synchronously)", repo.bootListCalls)
	}
	if got := repo.statuses["pending"]; got != "no_driver_available" {
		t.Errorf("boot reconcile had not closed the ride by the time Start returned: status = %q", got)
	}

	s.Stop()
	s.Stop() // idempotent, must not panic or deadlock
	if repo.bootListCalls != 1 {
		t.Errorf("boot list calls after Stop = %d, want 1", repo.bootListCalls)
	}
}

func TestPendingRideSweeperEventFailureDoesNotAbort(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("a", "pending", time.Hour)
	repo.seed("b", "pending", time.Hour)
	repo.eventErr = errors.New("ride_events insert failed")

	NewPendingRideSweeper(repo, 10*time.Minute, time.Minute, true).sweepOnce("boot")

	for _, id := range []string{"a", "b"} {
		if got := repo.statuses[id]; got != "no_driver_available" {
			t.Errorf("status[%s] = %q; an event failure must not block the status commit", id, got)
		}
	}
	if len(repo.casCalls) != 2 {
		t.Errorf("CAS calls = %d, want 2 (remaining ids still processed)", len(repo.casCalls))
	}
}

func TestPendingRideSweeperPerRowCASErrorContinues(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("bad", "pending", time.Hour)
	repo.seed("good", "pending", time.Hour)
	repo.closeCASErr["bad"] = errors.New("update ride status: connection reset")

	NewPendingRideSweeper(repo, 10*time.Minute, time.Minute, true).sweepOnce("boot")

	if got := repo.statuses["good"]; got != "no_driver_available" {
		t.Errorf("good status = %q; a per-row CAS failure must not abort the pass", got)
	}
	if len(repo.casCalls) != 2 {
		t.Errorf("CAS calls = %d, want 2", len(repo.casCalls))
	}
	if len(repo.events) != 1 || repo.events[0].RideID != "good" {
		t.Errorf("events = %+v, want only the successful row", repo.events)
	}
}

func TestPendingRideSweeperStartTwiceIsNoOp(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("pending", "pending", time.Hour)

	// A long interval keeps the ticker out of this test's assertions.
	s := NewPendingRideSweeper(repo, 10*time.Minute, time.Hour, true)
	s.Start()
	s.Start() // second call must not re-run boot or start a second goroutine
	defer s.Stop()

	if boot, _ := repo.listCallCounts(); boot != 1 {
		t.Errorf("boot list calls = %d, want 1 (second Start is a no-op)", boot)
	}
	if got := repo.statusOf("pending"); got != "no_driver_available" {
		t.Errorf("status = %q, want no_driver_available", got)
	}
}

func TestPendingRideSweeperStopBeforeStartDoesNotBlock(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)

	s := NewPendingRideSweeper(repo, 10*time.Minute, time.Hour, true)
	stopped := make(chan struct{})
	go func() {
		s.Stop()
		close(stopped)
	}()

	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("Stop before Start blocked waiting for a done channel that never closes")
	}

	// The sweeper must still be usable after an early Stop.
	s.Start()
	s.Stop()
	if boot, _ := repo.listCallCounts(); boot != 1 {
		t.Errorf("boot list calls = %d, want 1 after a later Start", boot)
	}
}

func TestPendingRideSweeperStopTwiceDoesNotBlock(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("pending", "pending", time.Hour)

	s := NewPendingRideSweeper(repo, 10*time.Minute, time.Hour, true)
	s.Start()

	stopped := make(chan struct{})
	go func() {
		s.Stop()
		s.Stop()
		close(stopped)
	}()

	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("repeated Stop blocked or panicked")
	}
}

func TestPendingRideSweeperTickerClosesStale(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("stale", "pending", 11*time.Minute)

	// Boot reconcile off so ONLY the ticker path can close the row: removing
	// `case <-ticker.C: s.sweepOnce("tick")` makes this test time out. The
	// interval is long enough that the pre-tick assertion is deterministic
	// (no race between Start returning and the first tick).
	s := NewPendingRideSweeper(repo, 10*time.Minute, 50*time.Millisecond, false)
	s.Start()
	defer s.Stop()

	if boot, _ := repo.listCallCounts(); boot != 0 {
		t.Fatalf("boot list calls = %d, want 0 with reconcileOnBoot=false", boot)
	}
	if got := repo.statusOf("stale"); got != "pending" {
		t.Fatalf("status right after Start = %q, want pending (the ticker has not run yet)", got)
	}

	// Wait for the status commit AND the audit event: the status flips before
	// CreateEvent lands, so polling only the status is flaky.
	deadline := time.Now().Add(2 * time.Second)
	for {
		status := repo.statusOf("stale")
		events := repo.eventCount()
		if status == "no_driver_available" && events == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("ticker did not close the stale ride and write its event within 2s (status = %q, events = %d, tick list calls = %d)",
				status, events, tickCalls(repo))
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, tick := repo.listCallCounts(); tick == 0 {
		t.Error("tick list calls = 0, want at least one ticker pass")
	}
}

func TestPendingRideSweeperBootReconcileOffSkipsBoot(t *testing.T) {
	repo := newFakePendingRepo(10 * time.Minute)
	repo.seed("fresh", "pending", time.Second)
	repo.seed("stale", "pending", 11*time.Minute)

	s := NewPendingRideSweeper(repo, 10*time.Minute, 10*time.Millisecond, false)
	s.Start()
	defer s.Stop()

	if boot, _ := repo.listCallCounts(); boot != 0 {
		t.Fatalf("boot list calls = %d, want 0 (RIDE_BOOT_RECONCILE=off)", boot)
	}
	// The fresh pending row proves no boot pass ran: only the ticker path runs,
	// and it closes only the stale row.
	deadline := time.Now().Add(2 * time.Second)
	for repo.statusOf("stale") != "no_driver_available" {
		if time.Now().After(deadline) {
			t.Fatalf("ticker did not close the stale ride within 2s (status = %q)", repo.statusOf("stale"))
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got := repo.statusOf("fresh"); got != "pending" {
		t.Errorf("fresh status = %q, want pending (boot reconcile must be off, ticker only closes stale)", got)
	}
	if boot, _ := repo.listCallCounts(); boot != 0 {
		t.Errorf("boot list calls = %d, want 0 after ticking", boot)
	}
}

func tickCalls(f *fakePendingRepo) int {
	_, tick := f.listCallCounts()
	return tick
}
