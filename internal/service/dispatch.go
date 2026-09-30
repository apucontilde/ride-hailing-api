package service

import (
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

type DispatchService struct {
	rideRepo        repository.RideRepository
	geoRepo         repository.GeoRepository
	userRepo        repository.UserRepository
	navSvc          *NavigationService
	hub             DriverHub
	offerChannels   map[string]chan bool
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
		offerChannels: make(map[string]chan bool),
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
			go s.sendRequestsSequentially(ride, drivers)
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
// is still being decided.
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

func (s *DispatchService) sendRequestsSequentially(ride *model.Ride, drivers []model.NearbyDriverResult) {
	for i, d := range drivers {
		ok := s.offerRideToDriver(ride.ID, d.DriverID, i+1, len(drivers))
		if ok {
			if err := s.AcceptRide(ride.ID, d.DriverID); err != nil {
				// Accepting is a WRITE; a failure must not be reported as a
				// plain decline, and it must not leave the trace claiming the
				// driver was never offered.
				detail := "accept failed"
				if errIsConflict(err) {
					detail = "another driver already took the ride"
				}
				s.recordSkip(ride.ID, d.DriverID, i+1, len(drivers), skipAcceptFailed, detail)
				log.Printf("failed to accept ride %s for driver %s: %v", ride.ID, d.DriverID, err)
				continue
			}
			// Someone took the ride. The trace closes HERE with its own
			// outcome; the skips it still carries are the evidence for "the
			// first N candidates were dropped and the N+1th answered".
			s.traceRecorder().noteAccepted(ride.ID)
			s.traceRecorder().end(ride.ID)
			return
		}
	}

	current, err := s.rideRepo.FindByID(ride.ID)
	if err == nil && current.Status == "pending" {
		s.finishWithoutDriver(ride)
		return
	}
	// The ride is no longer pending (accepted elsewhere, cancelled): nobody to
	// tell, but the trace still has to be closed so a support query does not
	// wait forever on an open attempt.
	s.traceRecorder().noteNotPending(ride.ID)
	s.traceRecorder().end(ride.ID)
}

func (s *DispatchService) offerRideToDriver(rideID, driverID string, attempt, total int) bool {
	// A DB-fresh driver whose socket is not in the hub yet is RETRIED, not
	// skipped: the hub registers a client a moment after the /ws handshake, and
	// a reconnect re-enters that window. The hard skip is what made the search
	// and the offer loop disagree.
	if !s.waitForSocket(rideID, driverID, attempt, total) {
		return false
	}

	ch := make(chan bool, 1)

	s.offerChannelsMu.Lock()
	s.offerChannels[rideID] = ch
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
	case result := <-ch:
		if !result {
			s.recordSkip(rideID, driverID, attempt, total, skipDriverDeclined, "driver declined")
			return false
		}
		return true
	case <-time.After(offerTimeout):
		s.recordSkip(rideID, driverID, attempt, total, skipOfferTimeout,
			fmt.Sprintf("no answer within %s", offerTimeout))
		return false
	}
}

func (s *DispatchService) HandleAccept(driverID, rideID string) error {
	s.offerChannelsMu.Lock()
	ch, ok := s.offerChannels[rideID]
	s.offerChannelsMu.Unlock()
	if !ok {
		return fmt.Errorf("no active offer for ride %s", rideID)
	}
	ch <- true
	return nil
}

func (s *DispatchService) HandleDecline(driverID, rideID string) {
	s.offerChannelsMu.Lock()
	ch, ok := s.offerChannels[rideID]
	s.offerChannelsMu.Unlock()
	if ok {
		ch <- false
	}
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
