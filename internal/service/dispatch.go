package service

import (
	"errors"
	"fmt"
	"log"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

// DriverHub is the slice of *websocket.Hub that the offer path needs: push a
// message to one user, and ask whether they have a live socket.
//
// It is an interface rather than the concrete hub so the dispatch reliability
// tests can drive the exact timing the bug depends on — a socket that appears
// mid-reconnect-backoff, or never at all. Those states are the difference
// between "a driver was online" and "no drivers were nearby", and they cannot
// be reproduced reliably through a real WebSocket handshake.
//
// *websocket.Hub satisfies it, so production wiring is unchanged.
type DriverHub interface {
	IsConnected(userID string) bool
	SendToUser(userID string, msg interface{})
}

var _ DriverHub = (*websocket.Hub)(nil)

// activeOffer is one parked offer: the channel the accept/decline answer
// arrives on, the driver it was sent to, and the generation token that guards
// delete/replace when the same ride is re-offered to a later candidate. The
// driver id rides along so an accept/decline can be rejected unless it comes
// from the candidate the offer was actually sent to (api_plans
// [dispatch]_offer_path_fixes §A4).
type activeOffer struct {
	driverID string
	token    uint64
	ch       chan offerAnswer // buffered 1, so a late answer never blocks
}

// offerAnswer is the result of one accept attempt (or a decline/withdrawal).
// A non-nil err is an ACCEPT FAILURE (the funnel's assignment write failed);
// accepted=false with a nil err is an ordinary decline.
type offerAnswer struct {
	accepted bool
	err      error
}

// offerOutcome is the result of one offer attempt, so the sequential loop can
// act on the difference between "answered no", "never answered", and "never
// delivered" — the last one is the case the re-arm window exists for.
type offerOutcome int

const (
	// offerAccepted: the candidate answered yes; the caller must now write the
	// assignment.
	offerAccepted offerOutcome = iota
	// offerDeclined: the candidate answered no (recorded as skipDriverDeclined).
	offerDeclined
	// offerTimedOut: the offer was delivered and never answered (recorded as
	// skipOfferTimeout).
	offerTimedOut
	// offerSocketAbsent: the offer was never delivered — the hub had no live
	// socket for the candidate after the fast backoff. NOT recorded as a skip:
	// the caller may park the candidate for the re-arm window instead.
	offerSocketAbsent
	// offerAcceptFailed: the candidate answered yes but the authoritative
	// assignment write failed (a lost race or an outage).
	offerAcceptFailed
	// offerWithdrawn: a server-side stop (rider cancel) claimed the offer. The
	// whole dispatch loop must stop immediately.
	offerWithdrawn
)

type DispatchService struct {
	rideRepo        repository.RideRepository
	geoRepo         repository.GeoRepository
	userRepo        repository.UserRepository
	navSvc          *NavigationService
	hub             DriverHub
	offerChannels   map[string]activeOffer
	offerChannelsMu sync.Mutex
	// offerSeq is the generation source for activeOffer.token. It is advanced
	// under offerChannelsMu so a re-offer cannot be deleted or claimed by a
	// stale loop iteration.
	offerSeq uint64
	// traces records why every candidate was or was not offered the ride, so
	// "genuinely no drivers" is distinguishable from "drivers existed and were
	// skipped" (api_plans [dispatch]). See dispatch_observability.go. It is an
	// atomic pointer because observeDispatchTraces may swap it while a Dispatch
	// goroutine is reading it.
	traces atomic.Pointer[dispatchTraceRecorder]
}

func NewDispatchService(rideRepo repository.RideRepository, geoRepo repository.GeoRepository, userRepo repository.UserRepository, hub DriverHub, navSvc *NavigationService) *DispatchService {
	s := &DispatchService{
		rideRepo:      rideRepo,
		geoRepo:       geoRepo,
		userRepo:      userRepo,
		navSvc:        navSvc,
		hub:           hub,
		offerChannels: make(map[string]activeOffer),
	}
	s.traces.Store(newDispatchTraceRecorder(logDispatchTrace))
	return s
}

// traceRecorder returns the attempt recorder. Every method on it tolerates a nil
// receiver, so a service built without one still dispatches.
func (s *DispatchService) traceRecorder() *dispatchTraceRecorder {
	return s.traces.Load()
}

// observeDispatchTraces replaces the terminal-line observer. It is a TEST-ONLY
// hook, called before Dispatch: swapping the recorder while an attempt is in
// flight abandons that attempt's evidence, because the new recorder has never
// seen its begin(). Production leaves the logging observer in place.
func (s *DispatchService) observeDispatchTraces(observer func(dispatchTrace)) {
	s.traces.Store(newDispatchTraceRecorder(observer))
}

type RideRequest struct {
	RideID      string
	PickupLat   float64
	PickupLng   float64
	VehicleType string
}

func (s *DispatchService) Dispatch(ride *model.Ride) error {
	searchRadii := []float64{500, 1000, 2000, 5000, 10000}
	const maxLimit = 5

	for i, radius := range searchRadii {
		drivers, err := s.geoRepo.FindNearbyDrivers(ride.PickupLat, ride.PickupLng, radius, maxLimit)
		if err != nil {
			// A search failure is NOT "no drivers": reporting it as such would
			// tell support the service area was empty when the database was
			// unreachable. Record it as its own outcome and still let the
			// handler answer 5xx, which the ride service turns into a failed
			// create rather than a ride nobody will ever serve.
			s.traceRecorder().begin(ride.ID, 0)
			s.traceRecorder().noteSearchError(ride.ID, err)
			s.traceRecorder().end(ride.ID)
			return err
		}

		if len(drivers) > 0 {
			logSearchRounds(ride.ID, searchRadii[:i+1], len(drivers))
			s.traceRecorder().begin(ride.ID, len(drivers))
			go func() {
				// Safety net: if the offer loop unwinds without reaching one of
				// its explicit terminal states (a panic, or a future early
				// return), the attempt is still closed and published with a
				// terminal outcome instead of leaking. On the normal paths the
				// trace is already ended, so this is a no-op.
				defer s.traceRecorder().abortIfOpen(ride.ID, errDispatchAborted)
				s.sendRequestsSequentially(ride, drivers)
			}()
			return nil
		}
	}

	// Genuinely nobody: no online, fresh, in-radius driver at any radius.
	logSearchRounds(ride.ID, searchRadii, 0)
	s.traceRecorder().begin(ride.ID, 0)
	s.finishWithoutDriver(ride)
	return nil
}

// finishWithoutDriver closes out a ride that found nobody.
//
// The terminal trace is published from a defer, so it is emitted on EVERY path
// — including one where the status write fails — but only AFTER the write has
// settled, so a support query never sees a completed trace for an outcome that
// is still being decided. A failed write records its cause on the trace
// (terminal_err, outcome=terminal_write_failed), so the one support line can
// tell "our write failed" from a genuinely empty search.
//
// A failed write ABORTS here: the ride is still pending in the database, so
// pushing no_driver_available would tell the rider their ride is dead while the
// stored state says otherwise. Leaving it pending is what lets the ride service
// retry or expire it later.
func (s *DispatchService) finishWithoutDriver(ride *model.Ride) {
	defer func() {
		s.traceRecorder().end(ride.ID)
	}()

	updated, err := s.rideRepo.UpdateRideStatusFrom(ride.ID, []string{"pending"}, "no_driver_available", nil)
	if err != nil {
		s.traceRecorder().noteTerminalError(ride.ID, fmt.Errorf("persist no_driver_available: %w", err))
		log.Printf("ride %s: failed to persist no_driver_available: %v "+
			"(not pushing the rider a status the database does not hold)", ride.ID, err)
		return
	}
	if !updated {
		// The ride left pending while the search ran (an accept or a cancel
		// won). Do NOT push a no_driver_available the row does not hold.
		s.traceRecorder().noteNotPending(ride.ID)
		log.Printf("ride %s: no_driver_available not applied: ride is no longer pending", ride.ID)
		return
	}
	s.pushNoDriverAvailable(ride)
}

func (s *DispatchService) pushNoDriverAvailable(ride *model.Ride) {
	s.hub.SendToUser(ride.RiderID, websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:    ride.ID,
			Status:    "no_driver_available",
			Timestamp: time.Now(),
		},
	})
}

// sendRequestsSequentially offers the ride to each candidate in turn. A
// candidate whose socket is absent after the fast backoff is PARKED for the
// re-arm window (socketRearmWindow) rather than dropped: the offer loop
// re-checks parked candidates between rounds, and only gives up — with one
// honest skipSocketNotConnected — when the window elapses without a socket.
// That is the server-side half of bug #11 (api_plans
// [dispatch]_offer_path_fixes §A3): a driver whose reconnect lands after the
// ~450 ms fast backoff but inside the window still gets the offer.
//
// The loop NEVER performs the accept write (api_plans
// [rides]_cancel_accept_race.md §4.1). HandleAccept is the only accept funnel;
// an offerAccepted answer means that funnel already committed the assignment.
// The loop only records the outcome and stops. Before EVERY send (first round
// and re-arm rounds) it re-reads the ride, so no later candidate is offered an
// already accepted/cancelled ride.
func (s *DispatchService) sendRequestsSequentially(ride *model.Ride, drivers []model.NearbyDriverResult) {
	rearmDeadline := time.Now().Add(socketRearmWindow)
	type parkedCandidate struct {
		driverID string
		attempt  int
	}
	var parked []parkedCandidate

	for i, d := range drivers {
		if !s.ridePendingOrStop(ride.ID) {
			return
		}
		attempt := i + 1
		switch s.offerRideToDriver(ride.ID, d.DriverID, attempt, len(drivers), true) {
		case offerAccepted:
			s.traceRecorder().noteAccepted(ride.ID)
			s.traceRecorder().end(ride.ID)
			return
		case offerWithdrawn:
			// A server-side stop (rider cancel) claimed the offer. Run the
			// post-loop re-read so the trace records the terminal state.
			s.finishAfterCandidates(ride)
			return
		case offerSocketAbsent:
			// Park instead of dropping: the reconnect may still land inside
			// the re-arm window. The park is logged with its own verb so the
			// socket-wait count and the skip tally both stay exact.
			logOfferRearm(ride.ID, d.DriverID, attempt, len(drivers),
				"socket absent after fast backoff; parked for the re-arm window")
			parked = append(parked, parkedCandidate{driverID: d.DriverID, attempt: attempt})
		case offerDeclined, offerTimedOut, offerAcceptFailed:
			// Recorded inside offerRideToDriver; keep going. The next
			// per-candidate pending check stops the loop if the ride was taken.
		}
	}

	// Re-arm rounds: re-check the parked candidates until the window elapses.
	// The deadline gates only the WAITING for a socket — a parked candidate
	// that shows up is offered regardless of how much of the window the
	// earlier candidates consumed.
	for len(parked) > 0 {
		remaining := time.Until(rearmDeadline)
		if remaining <= 0 {
			for _, p := range parked {
				s.recordSkip(ride.ID, p.driverID, p.attempt, len(drivers), skipSocketNotConnected,
					fmt.Sprintf("no socket after %d checks over %s; %s re-arm window elapsed",
						socketBackoffAttempts,
						time.Duration(socketBackoffAttempts-1)*socketBackoffDelay,
						socketRearmWindow))
			}
			break
		}
		wait := socketRearmPoll
		if remaining < wait {
			wait = remaining
		}
		time.Sleep(wait)

		var stillParked []parkedCandidate
		for _, p := range parked {
			if !s.hub.IsConnected(p.driverID) {
				stillParked = append(stillParked, p)
				continue
			}
			if !s.ridePendingOrStop(ride.ID) {
				return
			}
			// withBackoff=false: presence was just confirmed, so the fast
			// backoff would only add latency (and extra socket-wait lines).
			switch s.offerRideToDriver(ride.ID, p.driverID, p.attempt, len(drivers), false) {
			case offerAccepted:
				s.traceRecorder().noteAccepted(ride.ID)
				s.traceRecorder().end(ride.ID)
				return
			case offerWithdrawn:
				s.finishAfterCandidates(ride)
				return
			case offerSocketAbsent:
				// Disconnected again between the check and the send; keep it
				// parked for the rest of the window.
				stillParked = append(stillParked, p)
			case offerDeclined, offerTimedOut, offerAcceptFailed:
				// Recorded inside offerRideToDriver; drop from the parked set.
			}
		}
		parked = stillParked
	}

	s.finishAfterCandidates(ride)
}

// finishAfterCandidates is the shared post-loop decision: re-read the ride and
// either close it out (still pending) or record the not_pending/terminal
// outcome. It is called on normal exhaustion AND on a server-side withdrawal,
// so no exit path can leave the trace open.
func (s *DispatchService) finishAfterCandidates(ride *model.Ride) {
	current, err := s.rideRepo.FindByID(ride.ID)
	switch {
	case err != nil:
		// An unexpected exit: the status read failed, so we cannot know whether
		// the ride is still pending. Recording not_pending here would be a lie;
		// record the failure as this attempt's terminal outcome instead.
		s.traceRecorder().noteTerminalError(ride.ID, fmt.Errorf("check ride after dispatch: %w", err))
	case current.Status == "pending":
		s.finishWithoutDriver(ride)
		return
	default:
		// The ride is no longer pending (accepted elsewhere, cancelled): nobody
		// to tell, but the trace still has to be closed with its own outcome so
		// a support query does not wait forever on an open attempt.
		s.traceRecorder().noteNotPending(ride.ID)
	}
	s.traceRecorder().end(ride.ID)
}

// ridePendingOrStop is the per-candidate re-read (§3.4): the loop must never
// send a ride.offer for a ride that is no longer pending. It records the SAME
// not_pending / terminal_write_failed outcome the post-loop check records and
// closes the trace. Returns false when the loop must stop.
func (s *DispatchService) ridePendingOrStop(rideID string) bool {
	current, err := s.rideRepo.FindByID(rideID)
	switch {
	case err != nil:
		s.traceRecorder().noteTerminalError(rideID, fmt.Errorf("check ride before offer: %w", err))
		s.traceRecorder().end(rideID)
		return false
	case current.Status != "pending":
		s.traceRecorder().noteNotPending(rideID)
		s.traceRecorder().end(rideID)
		return false
	}
	return true
}

// offerRideToDriver delivers the offer to one candidate and waits for the
// answer. withBackoff=true runs the fast hub poll first (round one); false is
// used by the re-arm rounds, where presence was just confirmed.
func (s *DispatchService) offerRideToDriver(rideID, driverID string, attempt, total int, withBackoff bool) offerOutcome {
	// A DB-fresh driver whose socket is not in the hub yet is RETRIED, not
	// skipped: the hub registers a client a moment after the /ws handshake, and
	// a reconnect re-enters that window. The hard skip is what made the search
	// and the offer loop disagree. Exhausting the fast backoff does NOT record
	// a skip — the caller decides between parking and giving up.
	if withBackoff && !s.waitForSocket(rideID, driverID, attempt, total) {
		return offerSocketAbsent
	}

	ch := make(chan offerAnswer, 1)

	s.offerChannelsMu.Lock()
	s.offerSeq++
	token := s.offerSeq
	offer := activeOffer{driverID: driverID, token: token, ch: ch}
	s.offerChannels[rideID] = offer
	s.offerChannelsMu.Unlock()

	// Delete only OUR generation: a re-offer for the same ride must not be
	// unregistered by the previous candidate's deferred cleanup.
	defer func() {
		s.offerChannelsMu.Lock()
		if cur, ok := s.offerChannels[rideID]; ok && cur.token == token {
			delete(s.offerChannels, rideID)
		}
		s.offerChannelsMu.Unlock()
	}()

	s.hub.SendToUser(driverID, websocket.OutgoingMessage{
		Type: "ride.offer",
		Data: map[string]string{"ride_id": rideID},
	})

	select {
	case answer := <-offer.ch:
		return s.resolveOfferAnswer(rideID, driverID, attempt, total, answer)
	case <-time.After(offerTimeout):
		// §4.1.1: time.After and the buffered answer channel can be ready at the
		// same instant, and Go picks among ready select cases pseudo-randomly.
		// An answer that already arrived wins over the timer: process it through
		// the same outcome switch without recording a timeout or sending a
		// frame.
		select {
		case answer := <-offer.ch:
			return s.resolveOfferAnswer(rideID, driverID, attempt, total, answer)
		default:
		}

		// Claim THIS generation under the mutex before declaring it expired.
		// The token is the linearizable answer to "may this generation still be
		// closed?" (the same claim HandleAccept and WithdrawOffer use).
		s.offerChannelsMu.Lock()
		cur, present := s.offerChannels[rideID]
		claimed := present && cur.token == token
		if claimed {
			delete(s.offerChannels, rideID)
		}
		s.offerChannelsMu.Unlock()

		switch {
		case claimed:
			// Genuinely unanswered: we own the generation, no accept can commit
			// afterwards (HandleAccept will find no offer).
			s.recordSkip(rideID, driverID, attempt, total, skipOfferTimeout,
				fmt.Sprintf("no answer within %s", offerTimeout))
			s.sendOfferClosed(driverID, rideID, "expired")
			return offerTimedOut
		case present:
			// A replacement generation owns the map entry; leave it untouched
			// and do not send a frame for it.
			return offerTimedOut
		default:
			// The entry is gone because a claimer already owns this generation
			// (HandleAccept deletes before acceptRide, WithdrawOffer deletes
			// before answering). Every claimer sends exactly one answer, so
			// block for it rather than re-checking or returning a false
			// timeout. Do NOT record a skip and do NOT send "expired".
			answer := <-offer.ch
			return s.resolveOfferAnswer(rideID, driverID, attempt, total, answer)
		}
	}
}

// resolveOfferAnswer maps one parked-offer answer to the loop outcome. It is
// shared by the normal answer branch and by the §4.1.1 timeout branch so an
// already-arrived (or claimed-generation) answer is processed identically.
func (s *DispatchService) resolveOfferAnswer(rideID, driverID string, attempt, total int, answer offerAnswer) offerOutcome {
	switch {
	case errors.Is(answer.err, ErrOfferWithdrawn):
		// The server claimed the offer (rider cancel). Stop the loop; the
		// post-loop re-read records the terminal state.
		return offerWithdrawn
	case answer.err != nil:
		detail := "accept failed"
		if errIsConflict(answer.err) {
			detail = "another driver already took the ride"
		}
		s.recordSkip(rideID, driverID, attempt, total, skipAcceptFailed, detail)
		log.Printf("failed to accept ride %s for driver %s: %v", rideID, driverID, answer.err)
		return offerAcceptFailed
	case !answer.accepted:
		s.recordSkip(rideID, driverID, attempt, total, skipDriverDeclined, "driver declined")
		return offerDeclined
	default:
		// HandleAccept already committed the assignment before sending
		// this answer; the loop must NOT write again.
		return offerAccepted
	}
}

// ErrNoActiveOffer is returned when an accept/decline names a ride with no
// offer parked for the asking driver — either the offer already
// expired/was answered/withdrawn, or it belongs to a different candidate.
// Handlers map it to 404; it must never become a 2xx lie (api_plans
// [dispatch]_offer_path_fixes §A4).
var ErrNoActiveOffer = errors.New("no active offer for ride")

// ErrNotOffered: a driver answered an offer that was parked for somebody else.
// It is distinct from ErrNoActiveOffer so the wire can say NOT_OFFERED, but
// both map to the same 404 body. The other driver's offer is left untouched.
var ErrNotOffered = errors.New("ride offer was not sent to this driver")

// ErrOfferWithdrawn wakes a parked dispatch loop when the server claims the
// offer (rider cancel). It never leaves the process: it is an internal signal.
var ErrOfferWithdrawn = errors.New("ride offer was withdrawn")

// acceptFailure carries the wire classification for an accept failure without
// making internal/websocket import internal/service (which would create an
// import cycle). The hub reads it through a small local interface; the HTTP
// handler still classifies the wrapped sentinels with errors.Is/errors.As.
type acceptFailure struct {
	code          string
	publicMessage string
	err           error
}

func (e *acceptFailure) Error() string {
	return fmt.Sprintf("accept ride (%s): %v", e.code, e.err)
}
func (e *acceptFailure) Unwrap() error { return e.err }
func (e *acceptFailure) AcceptFailureCode() (string, string) {
	return e.code, e.publicMessage
}

func newAcceptFailure(code, message string, err error) error {
	return &acceptFailure{code: code, publicMessage: message, err: err}
}

// HandleAccept is the ONLY accept entry point, shared by the WebSocket hub and
// POST /api/v1/driver/rides/:id/accept (api_plans
// [rides]_cancel_accept_race.md §4.1). It validates the offer owner, claims the
// offer under the lock, performs the one assignment write, answers the parked
// loop, and returns the authoritative outcome.
func (s *DispatchService) HandleAccept(driverID, rideID string) error {
	s.offerChannelsMu.Lock()
	offer, ok := s.offerChannels[rideID]
	if !ok {
		s.offerChannelsMu.Unlock()
		return newAcceptFailure(websocket.AcceptFailureOfferExpired, "this offer has expired", ErrNoActiveOffer)
	}
	if offer.driverID != driverID {
		// Do not touch another driver's offer and never assign on their
		// behalf; this closes the force-assign hole.
		s.offerChannelsMu.Unlock()
		return newAcceptFailure(websocket.AcceptFailureNotOffered, "this offer was not sent to you", ErrNotOffered)
	}
	// Claim it so it cannot be accepted twice. The token guards a re-offer.
	if cur, ok := s.offerChannels[rideID]; ok && cur.token == offer.token {
		delete(s.offerChannels, rideID)
	}
	s.offerChannelsMu.Unlock()

	err := s.acceptRide(rideID, driverID)

	// Tell the parked loop the authoritative outcome. Non-blocking: after a
	// timeout nobody is reading, and a late answer must not block the caller.
	select {
	case offer.ch <- offerAnswer{accepted: err == nil, err: err}:
	default:
	}

	if err != nil {
		// If the write lost to a cancel/another accept, the accepting driver
		// must still reach a terminal state (§3.3): tell them the current
		// status (e.g. cancelled). Never answer 200.
		if ride, rerr := s.rideRepo.FindByID(rideID); rerr == nil && ride.Status != "pending" {
			s.hub.SendToUser(driverID, websocket.OutgoingMessage{
				Type: "ride.updated",
				Data: websocket.RideUpdateData{
					RideID:    rideID,
					Status:    ride.Status,
					Timestamp: time.Now(),
				},
			})
		}
		return newAcceptFailure(websocket.AcceptFailureRideNotPending, "this ride is no longer available", err)
	}
	return nil
}

// WithdrawOffer closes the parked offer for rideID, if any: it deletes the
// matching generation, tells the offered driver, and wakes the dispatch loop
// immediately (rather than at the 30 s timeout). It returns the offered
// driver's ID, or "" when no offer was parked.
func (s *DispatchService) WithdrawOffer(rideID, reason string) string {
	s.offerChannelsMu.Lock()
	offer, ok := s.offerChannels[rideID]
	if !ok {
		s.offerChannelsMu.Unlock()
		return ""
	}
	delete(s.offerChannels, rideID)
	s.offerChannelsMu.Unlock()

	s.sendOfferClosed(offer.driverID, rideID, reason)
	// Buffered 1 and non-blocking: a loop that already answered/timed out must
	// not be blocked by a withdrawal racing it.
	select {
	case offer.ch <- offerAnswer{accepted: false, err: ErrOfferWithdrawn}:
	default:
	}
	return offer.driverID
}

// sendOfferClosed tells an offered driver that the server-side offer stopped
// being actionable. frame reasons: expired|declined|cancelled|accepted_elsewhere|withdrawn.
func (s *DispatchService) sendOfferClosed(driverID, rideID, reason string) {
	s.hub.SendToUser(driverID, websocket.OutgoingMessage{
		Type: "ride.offer_closed",
		Data: websocket.RideOfferClosedData{RideID: rideID, Reason: reason},
	})
}

// HandleDecline is the WebSocket adapter: a ride.decline frame is log-and-
// ignore, exactly as before, but it now goes through DeclineOffer so the WS
// and HTTP paths share one decline funnel (and one driver-match check).
func (s *DispatchService) HandleDecline(driverID, rideID string) {
	if err := s.DeclineOffer(driverID, rideID); err != nil {
		log.Printf("ride %s: websocket decline from driver %s ignored: %v", rideID, driverID, err)
	}
}

// DeclineOffer signals the active offer for rideID as declined, but only when
// the offer was sent to driverID: a different candidate (or a stranger) naming
// the ride gets ErrNoActiveOffer and the offer is left untouched. The WS path
// (HandleDecline) and the HTTP decline endpoint (handler.RideHandler.DeclineRide)
// both funnel through here, so one decline is recorded per offer either way.
func (s *DispatchService) DeclineOffer(driverID, rideID string) error {
	s.offerChannelsMu.Lock()
	offer, ok := s.offerChannels[rideID]
	s.offerChannelsMu.Unlock()
	if !ok || offer.driverID != driverID {
		return ErrNoActiveOffer
	}
	s.sendOfferClosed(driverID, rideID, "declined")
	select {
	case offer.ch <- offerAnswer{accepted: false}:
	default:
	}
	return nil
}

// acceptRide is the ONE assignment write. It is unexported on purpose:
// HandleAccept is the only caller, so no HTTP/WS path can bypass the offer
// ownership check and no dispatch-loop branch can assign a second time.
func (s *DispatchService) acceptRide(rideID, driverID string) error {
	ride, err := s.rideRepo.FindByID(rideID)
	if err != nil {
		return err
	}

	if ride.Status != "pending" {
		return errConflict
	}

	if err := s.rideRepo.AssignDriver(rideID, driverID); err != nil {
		return err
	}

	if err := s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: "pending",
		ToStatus:   "accepted",
		Actor:      "driver",
	}); err != nil {
		log.Printf("ride %s: failed to record accepted event: %v", rideID, err)
	}

	driver, _ := s.userRepo.FindDriverByID(driverID)
	// Real driver→pickup ETA (US-6): the rider sees how long until
	// the matched driver arrives, computed from the live route engine.
	// Falls back to the placeholder 300s only when routing or the driver
	// location is unavailable.
	etaSeconds := 300
	var driverInfo *websocket.DriverInfo
	if driver != nil {
		rating, _ := strconv.ParseFloat(driver.RatingSummary, 64)
		vehicle, _ := s.rideRepo.FindVehicleByDriverID(driverID)
		var vehicleInfo *websocket.VehicleInfo
		if vehicle != nil {
			vehicleInfo = &websocket.VehicleInfo{
				Make:        vehicle.Make,
				Model:       vehicle.Model,
				Color:       vehicle.Color,
				PlateNumber: vehicle.PlateNumber,
			}
		}
		loc, _ := s.geoRepo.GetDriverLocation(driverID)
		var locInfo *websocket.LatLng
		if loc != nil {
			locInfo = &websocket.LatLng{
				Lat:     loc.Lat,
				Lng:     loc.Lng,
				Heading: loc.Heading,
			}
			if route, err := s.navSvc.GetRoute(loc.Lat, loc.Lng, ride.PickupLat, ride.PickupLng); err == nil && route.DurationSecs > 0 {
				etaSeconds = route.DurationSecs
			}
		}
		driverInfo = &websocket.DriverInfo{
			ID:        driver.UserID,
			FirstName: driver.FirstName,
			PhotoURL:  driver.PhotoURL,
			Rating:    rating,
			Vehicle:   vehicleInfo,
			Location:  locInfo,
		}
	}

	pickup := &websocket.PlaceInfo{Lat: ride.PickupLat, Lng: ride.PickupLng, Address: ride.PickupAddress}
	dropoff := &websocket.PlaceInfo{Lat: ride.DropoffLat, Lng: ride.DropoffLng, Address: ride.DropoffAddress}

	msg := websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:     rideID,
			Status:     "accepted",
			Timestamp:  time.Now(),
			Driver:     driverInfo,
			Pickup:     pickup,
			Dropoff:    dropoff,
			EtaSeconds: etaSeconds,
		},
	}
	s.hub.SendToUser(ride.RiderID, msg)
	s.hub.SendToUser(driverID, msg)

	return nil
}

var errConflict = &DispatchConflictError{Message: "ride was already accepted by another driver"}

type DispatchConflictError struct {
	Message string
}

func (e *DispatchConflictError) Error() string {
	return e.Message
}
