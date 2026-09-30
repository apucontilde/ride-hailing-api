package service

import (
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"ride-hailing-api/internal/repository"
)

// This file is the observability half of the dispatch false-negative fix (api_plans
// [dispatch]_reliability_and_no_driver_false_negative): "the rider got no driver
// though a driver was clearly online" is indistinguishable, from the outside,
// from a genuine service-area miss. So every skip is recorded on a closed set of
// reasons (not free text), and the ONE terminal line per attempt carries the
// candidate count plus the per-reason tally.

// offerSkipReason is the machine-readable "why did this driver not get the
// offer" value.
type offerSkipReason string

const (
	// skipSocketNotConnected: the search found the driver (online, fresh
	// position, in radius) but the hub had no live socket even after the
	// reconnect backoff.
	skipSocketNotConnected offerSkipReason = "socket_not_connected"
	// skipOfferTimeout: the offer was delivered and the driver never answered
	// within the offer window.
	skipOfferTimeout offerSkipReason = "offer_timeout"
	// skipDriverDeclined: the driver answered and said no.
	skipDriverDeclined offerSkipReason = "driver_declined"
	// skipAcceptFailed: the driver accepted but the assignment write failed,
	// usually because another driver won the race.
	skipAcceptFailed offerSkipReason = "accept_failed"
)

// offerSkip is one recorded skip of one candidate.
type offerSkip struct {
	DriverID string
	Reason   offerSkipReason
	// Detail is a short qualifier, server-log only — nothing here ever reaches
	// a client.
	Detail string
}

// dispatchTrace is everything one Dispatch attempt learned, and the single
// object the terminal log line and the tests are both built from. Candidate
// count is the load-bearing number: 0 means the search really found nobody; a
// positive count with skips means drivers existed and the offer path dropped
// them, which is the bug class this file exists to make visible.
type dispatchTrace struct {
	RideID     string
	Candidates int
	Skips      []offerSkip
	// SearchErr is set when FindNearbyDrivers itself failed, which is a
	// different failure from "found nobody" and must not be reported as the latter.
	SearchErr error
	// Accepted and NotPending are the terminal states the offer loop reports.
	// They are recorded rather than inferred from the skip tally, so the
	// published outcome can never contradict what the loop actually did.
	Accepted   bool
	NotPending bool
}

// Outcome names the terminal result for a trace, and is what a support query
// groups by.
//
// KNOWN LIMITATION — "no_candidates" is NOT proof that nobody was there. It is
// returned both for a search that really found no driver at any radius AND for
// an attempt whose terminal no_driver_available write failed; finishWithoutDriver
// tells the two apart only by the log.Printf it emits on the failure path
// (internal/service/dispatch.go), which is a separate line a support query has
// to go and find. So this field alone cannot answer "was the service area
// empty, or did our write fail?", which is a question this file exists to make
// answerable. Every other terminal state is recorded EXPLICITLY rather than
// inferred from the skip tally (SearchErr, Accepted, NotPending); the failed
// terminal write is the one exception.
//
// Closing it needs a fourth recorded terminal state — the write error itself —
// carried on the trace and given its own outcome. That is a code change in
// dispatch_traces.go + finishWithoutDriver, deliberately NOT made here: this
// pass is comments/docs only, and dispatch.go is being edited concurrently for
// an unrelated routing fix. Filed as api_plans/STATUS.md known bug #19.
func (t dispatchTrace) Outcome() string {
	switch {
	case t.SearchErr != nil:
		return "search_failed"
	case t.Accepted:
		return "accepted"
	case t.NotPending:
		return "not_pending"
	case t.Candidates == 0:
		return "no_candidates"
	case len(t.Skips) == 0:
		return "candidates_unprocessed"
	default:
		return "candidates_skipped"
	}
}

// ReasonCounts tallies the skips by reason, sorted so the rendering is stable.
func (t dispatchTrace) ReasonCounts() map[offerSkipReason]int {
	counts := make(map[offerSkipReason]int, len(t.Skips))
	for _, s := range t.Skips {
		counts[s.Reason]++
	}
	return counts
}

// String renders the trace as the single canonical log line. The shape is
// fixed so one grep answers "why did ride X get no driver".
//
//	[dispatch] ride=... outcome=no_candidates candidates=0 skipped=0 reasons={}
func (t dispatchTrace) String() string {
	reasons := t.ReasonCounts()
	keys := make([]string, 0, len(reasons))
	for r := range reasons {
		keys = append(keys, string(r))
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, reasons[offerSkipReason(k)]))
	}
	line := fmt.Sprintf("[dispatch] ride=%s outcome=%s candidates=%d skipped=%d reasons={%s}",
		t.RideID, t.Outcome(), t.Candidates, len(t.Skips), strings.Join(parts, " "))
	if t.SearchErr != nil {
		// The cause is logged here and nowhere a client can see it.
		line += fmt.Sprintf(" search_err=%v", t.SearchErr)
	}
	return line
}

// logOfferSkip writes one skip line, emitted at the moment the skip is decided
// so a long-running ride is readable while it is still in progress:
//
//	[dispatch] ride=... skip driver=... attempt=n/total reason=... detail=...
//
// Only recordSkip calls this, so `grep -c "skip driver="` counts exactly the
// candidates the terminal line reports as dropped.
func logOfferSkip(rideID, driverID string, attempt, total int, reason offerSkipReason, detail string) {
	log.Printf("[dispatch] ride=%s skip driver=%s attempt=%d/%d reason=%s detail=%s",
		rideID, driverID, attempt, total, reason, detail)
}

// logOfferRetry writes one reconnect-wait progress line. The verb is
// deliberately NOT "skip": a driver who connects on the last poll was offered,
// and logging his successful recovery as a skip both contradicts the terminal
// line and inflates a one-candidate drop into N lines.
//
//	[dispatch] ride=... socket-wait driver=... attempt=n/total retry=i/N detail=...
func logOfferRetry(rideID, driverID string, attempt, total, retry int, detail string) {
	log.Printf("[dispatch] ride=%s socket-wait driver=%s attempt=%d/%d retry=%d/%d detail=%s",
		rideID, driverID, attempt, total, retry, socketBackoffAttempts, detail)
}

// logSearchRounds records what the widening search actually did, so an empty
// candidate set is explainable without guessing at the radii.
func logSearchRounds(rideID string, radii []float64, found int) {
	log.Printf("[dispatch] ride=%s search radii=%v found=%d", rideID, radii, found)
}

// logDispatchTrace writes the terminal line for an attempt. It is the observer
// the recorder is built with (see NewDispatchService), so the trace is
// published exactly once per attempt, from exactly one place. It is deliberately
// the SAME function the tests assert against, so a change to the wording cannot
// silently stop describing the real outcome.
func logDispatchTrace(t dispatchTrace) {
	log.Print(t.String())
}

var (
	// socketBackoffAttempts is how many times the offer loop re-checks the hub
	// before giving up on a DB-fresh driver: 4 checks with 3 sleeps between them
	// = 450ms of tolerance, far less than the 30s offer timeout, so the happy
	// path is unaffected.
	socketBackoffAttempts = 4
	socketBackoffDelay    = 150 * time.Millisecond
	// offerTimeout is how long a delivered offer waits for an accept/decline.
	offerTimeout = 30 * time.Second
)

// The driver-side requirements this gate implements (one live socket per online
// session, presence refreshed at least every repository.DriverLivenessWindow,
// no reliance on a server ping) live in
// driver_app_plans/01_[dispatch]_keepalive_and_offer_reliability.md, which
// driver-planner owns.

// waitForSocket polls the hub briefly instead of skipping a DB-fresh driver on
// the first miss: the hub registers a client a moment AFTER the /ws upgrade
// replies 101 (internal/websocket/hub.go:55-70), and a reconnect re-enters that
// window. Treating "not in the map" as a hard skip on the first miss is what
// made the search and the offer loop disagree.
//
// Each poll is logged as a retry, not a skip. Only the give-up decision is a
// skip, so the terminal tally counts one dropped candidate per driver rather
// than one per poll; the retry count rides in that single skip's detail.
func (s *DispatchService) waitForSocket(rideID, driverID string, attempt, total int) bool {
	for try := 1; try <= socketBackoffAttempts; try++ {
		if s.hub.IsConnected(driverID) {
			return true
		}
		detail := "hub has no socket"
		if try < socketBackoffAttempts {
			detail = fmt.Sprintf("hub has no socket; retrying in %s", socketBackoffDelay)
		}
		logOfferRetry(rideID, driverID, attempt, total, try, detail)
		if try < socketBackoffAttempts {
			time.Sleep(socketBackoffDelay)
		}
	}
	s.recordSkip(rideID, driverID, attempt, total, skipSocketNotConnected,
		fmt.Sprintf("no socket after %d checks over %s", socketBackoffAttempts,
			time.Duration(socketBackoffAttempts-1)*socketBackoffDelay))
	return false
}

// recordSkip is the single funnel for "this candidate did not get the offer":
// it both logs immediately and appends to the in-flight trace, so no skip can
// be silent and the terminal line can never disagree with the per-skip lines.
func (s *DispatchService) recordSkip(rideID, driverID string, attempt, total int, reason offerSkipReason, detail string) {
	logOfferSkip(rideID, driverID, attempt, total, reason, detail)
	s.traceRecorder().append(rideID, offerSkip{DriverID: driverID, Reason: reason, Detail: detail})
}

// errIsConflict reports whether an accept failed because another driver already
// won the ride — a benign race, but a different reason than a real failure.
//
// Both spellings are matched because production returns the repository one:
// AssignDriver's UPDATE ... WHERE status='pending' affects zero rows and reports
// fmt.Errorf("accept ride: %w: %w", repository.ErrConflict, sql.ErrNoRows)
// (internal/repository/ride_repo.go), while the in-process status check below
// returns *DispatchConflictError. Matching only the latter would classify every
// real accept race as a plain accept failure.
func errIsConflict(err error) bool {
	var conflict *DispatchConflictError
	return errors.Is(err, repository.ErrConflict) || errors.As(err, &conflict)
}
