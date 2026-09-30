package service

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// sweeperGeoRepo counts sweeps and can fail them, which is all the sweeper's
// behaviour depends on. It embeds fakeGeoRepo so the full GeoRepository
// interface stays satisfied without re-stating eleven no-op methods.
//
// sweeps counts COMPLETED sweeps, so a test that waits on the count knows the
// body (including onSweep) has already run. It also tracks in-flight sweeps, so
// a test can prove two sweeps never overlap rather than inferring it from a
// count.
type sweeperGeoRepo struct {
	fakeGeoRepo
	// sweepErr, when set, fails every sweep.
	sweepErr error
	// inFlight / maxInFlight bracket each sweep's body.
	inFlight    int
	maxInFlight int
}

func (s *sweeperGeoRepo) MarkStaleDriversOffline() error {
	s.mu.Lock()
	s.inFlight++
	if s.inFlight > s.maxInFlight {
		s.maxInFlight = s.inFlight
	}
	err := s.sweepErr
	s.mu.Unlock()

	// Stand in for the UPDATE so an overlap has a window to happen in.
	time.Sleep(time.Millisecond)
	if s.onSweep != nil {
		s.onSweep()
	}

	s.mu.Lock()
	s.inFlight--
	s.sweeps++
	s.mu.Unlock()
	return err
}

func (s *sweeperGeoRepo) sweepCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sweeps
}

// maxConcurrentSweeps is the high-water mark of simultaneously running sweeps.
func (s *sweeperGeoRepo) maxConcurrentSweeps() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.maxInFlight
}

// waitForSweeps polls until at least n sweeps have run, or fails. Polling
// rather than sleeping a fixed duration keeps the test fast and still robust on
// a loaded machine.
func waitForSweeps(t *testing.T, repo *sweeperGeoRepo, n int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if repo.sweepCount() >= n {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("sweeps after 3s = %d, want >= %d: the sweeper is not running", repo.sweepCount(), n)
}

// TestSweeperSweepsOnEveryTick is the wiring proof for the sweeper that
// MarkStaleDriversOffline never had. Before this, the method existed on the
// interface with zero production callers, so stored status was never reconciled.
func TestSweeperSweepsOnEveryTick(t *testing.T) {
	repo := &sweeperGeoRepo{}
	sw := NewDriverLivenessSweeper(repo, 5*time.Millisecond)
	sw.Start()
	t.Cleanup(sw.Stop)

	// The boot sweep must be immediate: a restart should not wait a full
	// interval to clean up drivers the previous instance abandoned.
	waitForSweeps(t, repo, 1)
	waitForSweeps(t, repo, 4)
}

// TestSweeperStopEndsTheLoop pins the lifecycle half, which matters because
// main defers Stop before closing the database: a sweep still running after
// db.Close() would be an UPDATE on a closed pool.
func TestSweeperStopEndsTheLoop(t *testing.T) {
	repo := &sweeperGeoRepo{}
	sw := NewDriverLivenessSweeper(repo, time.Millisecond)
	sw.Start()
	waitForSweeps(t, repo, 2)

	sw.Stop()
	after := repo.sweepCount()
	// Stop must be synchronous: no sweep may begin once it has returned.
	time.Sleep(20 * time.Millisecond)
	if got := repo.sweepCount(); got != after {
		t.Errorf("sweeps went %d -> %d after Stop; Stop must end the loop synchronously", after, got)
	}
	// And it must be safe to call twice (a defer plus an explicit shutdown).
	sw.Stop()
}

// TestSweeperToleratesNonPositiveInterval keeps a misconfiguration from
// becoming a hot loop that hammers the database.
func TestSweeperToleratesNonPositiveInterval(t *testing.T) {
	for _, interval := range []time.Duration{0, -time.Second} {
		sw := NewDriverLivenessSweeper(&sweeperGeoRepo{}, interval)
		if sw.Interval() != DefaultSweeperInterval {
			t.Errorf("NewDriverLivenessSweeper(%s).Interval() = %s, want the %s default",
				interval, sw.Interval(), DefaultSweeperInterval)
		}
	}
}

// TestSweeperSweepFailureDoesNotStopTheLoop pins the "a failed write never
// looks like success, and never escalates" behaviour: a failing sweep is
// swallowed-and-logged, the loop keeps running, and the next tick is the retry.
// Killing the loop on a transient database error would leave drivers stuck
// "online" forever — the exact drift the sweeper exists to remove.
func TestSweeperSweepFailureDoesNotStopTheLoop(t *testing.T) {
	repo := &sweeperGeoRepo{sweepErr: errors.New("db down")}
	sw := NewDriverLivenessSweeper(repo, 5*time.Millisecond)
	sw.Start()
	t.Cleanup(sw.Stop)

	// Several sweeps must still have been ATTEMPTED despite every one failing.
	waitForSweeps(t, repo, 3)
}

// TestSweeperNeverRunsConcurrentSweeps is the wiring proof for the sweeper that
// MarkStaleDriversOffline never had, plus the concurrency guard: the loop must
// keep running on every tick, and at no point may two sweeps overlap (a long
// UPDATE overlapping the next tick would double the write load for no benefit).
//
// The recorder counts in-flight sweeps on both sides of the sweep body, so an
// overlap is observed directly rather than inferred from the tick count.
func TestSweeperNeverRunsConcurrentSweeps(t *testing.T) {
	repo := &sweeperGeoRepo{}
	const interval = 2 * time.Millisecond
	sw := NewDriverLivenessSweeper(repo, interval)
	sw.Start()
	time.Sleep(60 * time.Millisecond)
	sw.Stop()

	got := repo.sweepCount()
	// 1 boot sweep + roughly 60ms/2ms ticks. Generously bounded, but it must
	// prove the loop actually ran repeatedly rather than once.
	if got < 3 {
		t.Errorf("sweeps = %d after ~60ms at %s intervals, want >= 3", got, interval)
	}
	if peak := repo.maxConcurrentSweeps(); peak > 1 {
		t.Errorf("concurrent sweeps peaked at %d, want 1: ticks must not overlap", peak)
	}
	// Stop is synchronous, so no sweep may be added after it returns.
	time.Sleep(20 * time.Millisecond)
	if after := repo.sweepCount(); after != got {
		t.Errorf("sweeps went %d -> %d after Stop", got, after)
	}
}

// TestSweeperStopIsSafeFromManyGoroutines pins the lifecycle's concurrency
// contract: shutdown may be triggered from more than one place (a defer plus an
// explicit shutdown, or two servers in one process), and a double close of the
// stop channel would panic the process during shutdown — the one moment nobody
// is watching.
func TestSweeperStopIsSafeFromManyGoroutines(t *testing.T) {
	repo := &sweeperGeoRepo{}
	sw := NewDriverLivenessSweeper(repo, time.Millisecond)
	sw.Start()
	waitForSweeps(t, repo, 2)

	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sw.Stop()
		}()
	}
	wg.Wait()
	if repo.sweepCount() < 2 {
		t.Errorf("sweeps = %d, want >= 2", repo.sweepCount())
	}
}

// TestSweeperSweepsThroughTheInjectedGeoRepo documents that the sweeper talks to
// the repository it was constructed with — the same GeoRepository the search
// uses — so the liveness rule cannot drift between the sweep and the query.
// (It says nothing about connections: the sweeper holds no pool of its own.)
func TestSweeperSweepsThroughTheInjectedGeoRepo(t *testing.T) {
	repo := &sweeperGeoRepo{}
	var mu sync.Mutex
	var swept bool
	repo.onSweep = func() { mu.Lock(); swept = true; mu.Unlock() }
	sw := NewDriverLivenessSweeper(repo, time.Millisecond)
	sw.Start()
	t.Cleanup(sw.Stop)
	waitForSweeps(t, repo, 1)
	mu.Lock()
	defer mu.Unlock()
	if !swept {
		t.Error("sweep did not reach the injected GeoRepository")
	}
}
