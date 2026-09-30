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
	ended      bool
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
		RideID:     rideID,
		Candidates: a.candidates,
		Skips:      a.skips,
		SearchErr:  a.searchErr,
		Accepted:   a.accepted,
		NotPending: a.notPending,
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
