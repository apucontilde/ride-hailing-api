package service

import (
	"sync"
)

// dispatchTraceRecorder collects the per-ride skip/terminal evidence while a
// Dispatch attempt is in flight, and publishes it to the observer exactly once
// when the attempt ends. It exists so the observability added for the dispatch
// false-negative fix is not only LOGGED but also reachable from a test: the
// "which reason was recorded" assertion is the only way to prove a skip branch
// is wired.
//
// A recorder is safe for concurrent use — Dispatch starts the offer loop in a
// goroutine — and the observer is invoked under no lock, so an observer that
// calls back into the service cannot deadlock.
type dispatchTraceRecorder struct {
	mu       sync.Mutex
	attempts map[string]*dispatchAttempt
	// observer receives the completed trace of every attempt. Nil means
	// "log only", which is the production default.
	observer func(dispatchTrace)
}

type dispatchAttempt struct {
	candidates int
	skips      []offerSkip
	searchErr  error
	accepted   bool
	notPending bool
	// terminalErr records an exit that reached no clean terminal state (a
	// failed terminal write, a failed status check, or an abandoned attempt).
	terminalErr error
	ended       bool
}

func newDispatchTraceRecorder(observer func(dispatchTrace)) *dispatchTraceRecorder {
	return &dispatchTraceRecorder{
		attempts: make(map[string]*dispatchAttempt),
		observer: observer,
	}
}

func (r *dispatchTraceRecorder) begin(rideID string, candidates int) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts[rideID] = &dispatchAttempt{candidates: candidates}
}

func (r *dispatchTraceRecorder) noteSearchError(rideID string, err error) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attempts[rideID]; ok {
		a.searchErr = err
	}
}

func (r *dispatchTraceRecorder) append(rideID string, skip offerSkip) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attempts[rideID]; ok {
		a.skips = append(a.skips, skip)
	}
}

// noteAccepted records the terminal state "a driver took the ride", so the
// published outcome is the one the loop reached rather than one inferred from
// the skip tally.
func (r *dispatchTraceRecorder) noteAccepted(rideID string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attempts[rideID]; ok {
		a.accepted = true
	}
}

// noteNotPending records the terminal state "the ride stopped being pending
// elsewhere (taken by another path, or cancelled)".
func (r *dispatchTraceRecorder) noteNotPending(rideID string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attempts[rideID]; ok {
		a.notPending = true
	}
}

// noteTerminalError records an exit that could not reach a clean terminal state
// — most importantly a failed no_driver_available write — so the published
// outcome names the failure instead of masquerading as "nobody was there". The
// first error wins: a later one must not erase the cause of the exit.
func (r *dispatchTraceRecorder) noteTerminalError(rideID string, err error) {
	if r == nil || err == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if a, ok := r.attempts[rideID]; ok && a.terminalErr == nil {
		a.terminalErr = err
	}
}

// abortIfOpen is the panic/early-return safety net: if an attempt is still open
// when its goroutine unwinds, it records err as the terminal state and
// publishes the trace, so no exit path can leave an attempt open (a support
// query waiting forever) or publish a terminal line with no outcome. It is a
// no-op once end has already published.
func (r *dispatchTraceRecorder) abortIfOpen(rideID string, err error) {
	if r == nil {
		return
	}
	r.mu.Lock()
	a, ok := r.attempts[rideID]
	if !ok || a.ended {
		r.mu.Unlock()
		return
	}
	if a.terminalErr == nil {
		a.terminalErr = err
	}
	r.mu.Unlock()
	// end locks again and publishes outside that lock; calling it here (rather
	// than duplicating its logic) keeps the "publish exactly once" rule in one
	// place.
	r.end(rideID)
}

// end closes the attempt and returns the completed trace, publishing it to the
// observer exactly once — the observer is the ONLY publisher of the terminal
// line, so the line can be neither duplicated nor contradicted by a second
// hand-written one. It is idempotent: a ride whose accept succeeded and whose
// no_driver_available path also ran must not be published twice.
func (r *dispatchTraceRecorder) end(rideID string) (dispatchTrace, bool) {
	if r == nil {
		return dispatchTrace{RideID: rideID}, false
	}
	r.mu.Lock()
	a, ok := r.attempts[rideID]
	if !ok {
		r.mu.Unlock()
		return dispatchTrace{RideID: rideID}, false
	}
	if a.ended {
		r.mu.Unlock()
		return dispatchTrace{RideID: rideID}, false
	}
	a.ended = true
	delete(r.attempts, rideID)
	trace := dispatchTrace{
		RideID:      rideID,
		Candidates:  a.candidates,
		Skips:       a.skips,
		SearchErr:   a.searchErr,
		Accepted:    a.accepted,
		NotPending:  a.notPending,
		TerminalErr: a.terminalErr,
	}
	observer := r.observer
	r.mu.Unlock()

	// Publishing outside the lock: an observer that touches the service (or
	// blocks) must not stall every other ride's bookkeeping.
	if observer != nil {
		observer(trace)
	}
	return trace, true
}

// pending reports how many attempts are still open — a leak check, and the hook
// a test uses to wait for quiescence.
func (r *dispatchTraceRecorder) pending() int {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.attempts)
}
