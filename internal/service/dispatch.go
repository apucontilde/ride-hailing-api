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
// arrives on, plus the driver it was sent to. The driver id rides along so a
// decline can be rejected unless it comes from the candidate the offer was
// actually sent to (api_plans [dispatch]_offer_path_fixes §A4).
type activeOffer struct {
	driverID string
	ch       chan bool
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
)

type DispatchService struct {
	rideRepo        repository.RideRepository
	geoRepo         repository.GeoRepository
	userRepo        repository.UserRepository
	navSvc          *NavigationService
	hub             DriverHub
	offerChannels   map[string]activeOffer
	offerChannelsMu sync.Mutex
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

	if err := s.rideRepo.UpdateRideStatus(ride.ID, "no_driver_available", nil); err != nil {
		s.traceRecorder().noteTerminalError(ride.ID, fmt.Errorf("persist no_driver_available: %w", err))
		log.Printf("ride %s: failed to persist no_driver_available: %v "+
			"(not pushing the rider a status the database does not hold)", ride.ID, err)
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
func (s *DispatchService) sendRequestsSequentially(ride *model.Ride, drivers []model.NearbyDriverResult) {
	rearmDeadline := time.Now().Add(socketRearmWindow)
	type parkedCandidate struct {
		driverID string
		attempt  int
	}
	var parked []parkedCandidate

	for i, d := range drivers {
		attempt := i + 1
		switch s.offerRideToDriver(ride.ID, d.DriverID, attempt, len(drivers), true) {
		case offerAccepted:
			if s.acceptOfferedRide(ride, d.DriverID, attempt, len(drivers)) {
				return
			}
		case offerSocketAbsent:
			// Park instead of dropping: the reconnect may still land inside
			// the re-arm window. The park is logged with its own verb so the
			// socket-wait count and the skip tally both stay exact.
			logOfferRearm(ride.ID, d.DriverID, attempt, len(drivers),
				"socket absent after fast backoff; parked for the re-arm window")
			parked = append(parked, parkedCandidate{driverID: d.DriverID, attempt: attempt})
		case offerDeclined, offerTimedOut:
			// Both were recorded inside offerRideToDriver; keep going.
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
			// withBackoff=false: presence was just confirmed, so the fast
			// backoff would only add latency (and extra socket-wait lines).
			switch s.offerRideToDriver(ride.ID, p.driverID, p.attempt, len(drivers), false) {
			case offerAccepted:
				if s.acceptOfferedRide(ride, p.driverID, p.attempt, len(drivers)) {
					return
				}
			case offerSocketAbsent:
				// Disconnected again between the check and the send; keep it
				// parked for the rest of the window.
				stillParked = append(stillParked, p)
			case offerDeclined, offerTimedOut:
				// Recorded inside offerRideToDriver; drop from the parked set.
			}
		}
		parked = stillParked
	}

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

// acceptOfferedRide runs the accept write for a candidate whose offer was
// answered yes. A failure is recorded as its own skip (never as a plain
// decline, and never leaving the trace claiming the driver was never offered).
// Returns true when the ride was assigned and the attempt is over.
func (s *DispatchService) acceptOfferedRide(ride *model.Ride, driverID string, attempt, total int) bool {
	if err := s.AcceptRide(ride.ID, driverID); err != nil {
		detail := "accept failed"
		if errIsConflict(err) {
			detail = "another driver already took the ride"
		}
		s.recordSkip(ride.ID, driverID, attempt, total, skipAcceptFailed, detail)
		log.Printf("failed to accept ride %s for driver %s: %v", ride.ID, driverID, err)
		return false
	}
	// Someone took the ride. The trace closes HERE with its own outcome; the
	// skips it still carries are the evidence for "the first N candidates were
	// dropped and the N+1th answered".
	s.traceRecorder().noteAccepted(ride.ID)
	s.traceRecorder().end(ride.ID)
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

	offer := activeOffer{driverID: driverID, ch: make(chan bool, 1)}

	s.offerChannelsMu.Lock()
	s.offerChannels[rideID] = offer
	s.offerChannelsMu.Unlock()

	defer func() {
		s.offerChannelsMu.Lock()
		delete(s.offerChannels, rideID)
		s.offerChannelsMu.Unlock()
	}()

	s.hub.SendToUser(driverID, websocket.OutgoingMessage{
		Type: "ride.offer",
		Data: map[string]string{"ride_id": rideID},
	})

	select {
	case result := <-offer.ch:
		if !result {
			s.recordSkip(rideID, driverID, attempt, total, skipDriverDeclined, "driver declined")
			return offerDeclined
		}
		return offerAccepted
	case <-time.After(offerTimeout):
		s.recordSkip(rideID, driverID, attempt, total, skipOfferTimeout,
			fmt.Sprintf("no answer within %s", offerTimeout))
		return offerTimedOut
	}
}

// ErrNoActiveOffer is returned when a decline names a ride with no offer
// parked for the asking driver — either the offer already expired/was answered,
// or it belongs to a different candidate. Handlers map it to 404; it must never
// become a 2xx lie (api_plans [dispatch]_offer_path_fixes §A4).
var ErrNoActiveOffer = errors.New("no active offer to decline")

func (s *DispatchService) HandleAccept(driverID, rideID string) error {
	s.offerChannelsMu.Lock()
	offer, ok := s.offerChannels[rideID]
	s.offerChannelsMu.Unlock()
	if !ok {
		return fmt.Errorf("no active offer for ride %s", rideID)
	}
	offer.ch <- true
	return nil
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
	offer.ch <- false
	return nil
}

func (s *DispatchService) AcceptRide(rideID, driverID string) error {
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
