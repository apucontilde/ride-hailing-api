package service

import (
	"strings"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
)

// TestDispatchSocketRetrySucceedsWhenDriverConnectsDuringRearm is the new
// behaviour: the fast backoff gives up (~450 ms) but the candidate is parked
// in the re-arm window. A driver that reconnects inside that window must be
// offered the ride (a late reconnect that was dropped by the old "hard-skip
// at 450 ms" path).
//
// It is the payoff for bug #11: the trace must not record the candidate as
// dropped, and an accept must reach the reconnected driver.
func TestDispatchSocketRetrySucceedsWhenDriverConnectsDuringRearm(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-late-3s"}}}
	ride := &fakeRideRepo{}
	hub := newFakeHub() // not connected yet
	svc := newTestDispatch(geo, ride, hub)
	var outcomes []string
	var outcomeMu sync.Mutex
	svc.observeDispatchTraces(func(tr dispatchTrace) {
		outcomeMu.Lock()
		defer outcomeMu.Unlock()
		outcomes = append(outcomes, tr.Outcome())
	})

	// The driver reconnects after the fast backoff but well inside the 3 s
	// re-arm window (and long after 450 ms) — the case that the old code
	// dropped.
	go func() {
		time.Sleep(time.Duration(socketBackoffAttempts) * socketBackoffDelay)
		time.Sleep(200 * time.Millisecond)
		hub.connect("driver-late-3s")
	}()

	if err := svc.Dispatch(pendingRide("ride-late-rearm")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	// The parked candidate is now connected: the re-arm loop must offer it.
	go awaitOfferAndAccept(t, svc, "ride-late-rearm", "driver-late-3s")

	awaitAssignments(t, ride, 1)
	awaitNoOpenTraces(t, svc)

	if got := hub.offersTo(); len(got) != 1 || got[0] != "ride-late-rearm" {
		t.Errorf("offers delivered = %v, want [ride-late-rearm] (the re-arm must reach the reconnected driver)", got)
	}
	if got := ride.assignmentLog(); len(got) != 1 || got[0] != "driver-late-3s" {
		t.Errorf("assignments = %v, want [driver-late-3s]", got)
	}
	if got := ride.statusUpdateLog(); len(got) != 0 {
		t.Errorf("status updates = %v, want none: an accepted ride must not be marked no_driver_available", got)
	}
	outcomeMu.Lock()
	defer outcomeMu.Unlock()
	for _, o := range outcomes {
		if o == "no_candidates" || o == "candidates_skipped" {
			t.Errorf("terminal outcome = %q: a driver who reconnected during the re-arm window "+
				"must not be recorded as dropped", o)
		}
	}
}

// TestDispatchRearmStillDropsDriverWhoNeverReconnects asserts the bounded
// window: a genuinely absent driver is parked, the window elapses, and we still
// record exactly one socket_not_connected skip — with the re-arm phrase in its
// detail so the 3 s budget is auditable.
func TestDispatchRearmStillDropsDriverWhoNeverReconnects(t *testing.T) {
	geo := &fakeGeoRepo{drivers: []model.NearbyDriverResult{{DriverID: "driver-never"}}}
	ride := &fakeRideRepo{}
	svc := newTestDispatch(geo, ride, newFakeHub())
	traces := collectTraces(svc, 1)
	logs := captureLogs(t)

	start := time.Now()
	if err := svc.Dispatch(pendingRide("ride-never-rearm")); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}
	tr := awaitTrace(t, traces)
	elapsed := time.Since(start)

	// The re-arm window must be exercised: elapsed >= the fast backoff.
	if elapsed < socketBackoffDelay*time.Duration(socketBackoffAttempts) {
		t.Errorf("elapsed %s, want >= %s (fast backoff)", elapsed,
			socketBackoffDelay*time.Duration(socketBackoffAttempts))
	}
	// The drop still happens inside the 5s test timeout (window is 3s).
	if elapsed >= 5*time.Second {
		t.Errorf("elapsed %s, want well under 5s: the re-arm window is bounded", elapsed)
	}

	if tr.Candidates != 1 {
		t.Fatalf("Candidates = %d, want 1", tr.Candidates)
	}
	if tr.Outcome() != "candidates_skipped" {
		t.Errorf("Outcome = %q, want %q", tr.Outcome(), "candidates_skipped")
	}
	if reasons := tr.ReasonCounts(); reasons[skipSocketNotConnected] != 1 {
		t.Errorf("ReasonCounts = %v, want exactly 1 x socket_not_connected", reasons)
	}
	if len(tr.Skips) != 1 {
		t.Fatalf("Skips = %v, want exactly 1", tr.Skips)
	}
	if !strings.Contains(tr.Skips[0].Detail, "re-arm window elapsed") {
		t.Errorf("skip detail = %q, want to name the re-arm window elapsed", tr.Skips[0].Detail)
	}
	if !strings.Contains(tr.Skips[0].Detail, "3s") && !strings.Contains(tr.Skips[0].Detail, "3 s") {
		t.Errorf("skip detail = %q, want to record the window budget", tr.Skips[0].Detail)
	}

	// socket-rearm line must be logged when parked.
	rearms := logs.linesContaining("ride=ride-never-rearm socket-rearm driver=")
	if len(rearms) != 1 {
		t.Errorf("socket-rearm lines = %d, want 1:\n%s", len(rearms), strings.Join(rearms, "\n"))
	}
}
