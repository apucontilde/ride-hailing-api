package service

import (
	"errors"
	"fmt"
	"log"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service/push"
	"ride-hailing-api/internal/websocket"
)

// PushNotifier is the backgrounded-notification seam. It returns nothing on
// purpose: a push is ancillary and must never be able to fail (or delay the
// return of) a ride transition. *push.Service implements it.
type PushNotifier interface {
	NotifyUser(userID string, msg push.Message)
}

type RideService struct {
	rideRepo    repository.RideRepository
	userRepo    repository.UserRepository
	hub         *websocket.Hub
	fareService *FareService
	push        PushNotifier
}

func NewRideService(rideRepo repository.RideRepository, userRepo repository.UserRepository, hub *websocket.Hub, fareSvc *FareService) *RideService {
	return &RideService{rideRepo: rideRepo, userRepo: userRepo, hub: hub, fareService: fareSvc}
}

// SetPushNotifier installs the backgrounded push pipeline. Separate from the
// constructor so the existing NewRideService call sites (and tests) keep
// compiling; a nil notifier is the documented "no push" mode.
func (s *RideService) SetPushNotifier(n PushNotifier) {
	s.push = n
}

// notifyOffline fires a push for userID only when they have no live WebSocket.
// This keeps the existing WS path authoritative for a connected client and uses
// the push channel only for a backgrounded one. It is fire-and-forget by
// design: the notification must not delay the response, and a nil hub or nil
// notifier is the no-push configuration.
func (s *RideService) notifyOffline(userID string, msg push.Message) {
	if s.push == nil || userID == "" {
		return
	}
	if s.hub != nil && s.hub.IsConnected(userID) {
		return
	}
	go s.push.NotifyUser(userID, msg)
}

// pushMessageForStatus builds the notification for a ride status. The rider is
// the recipient of the status pushes; `data.status` mirrors the WS payload so a
// client can route on the same keys it already uses.
func pushMessageForStatus(status, rideID string) push.Message {
	msg := push.Message{
		Data: map[string]string{
			"type":    "ride.updated",
			"status":  status,
			"ride_id": rideID,
		},
	}
	switch status {
	case "driver_arrived":
		msg.Title = "Driver arrived"
		msg.Body = "Your driver has arrived at the pickup point."
	case "in_progress":
		msg.Title = "Trip started"
		msg.Body = "Your trip has started."
	case "completed":
		msg.Title = "Trip completed"
		msg.Body = "Your trip is complete."
	case "cancelled":
		msg.Title = "Ride cancelled"
		msg.Body = "Your ride was cancelled."
	default:
		msg.Title = "Ride updated"
		msg.Body = "Your ride status changed."
	}
	return msg
}

var validTransitions = map[string][]string{
	"pending":        {"accepted", "cancelled", "no_driver_available"},
	"accepted":       {"driver_arrived", "cancelled"},
	"driver_arrived": {"in_progress", "cancelled"},
	"in_progress":    {"completed"},
	"completed":      {},
	"cancelled":      {},
}

// ErrDestinationLocked: the ride's status does not allow a destination change.
// A state conflict the caller can act on (pick a different ride), so the
// handler maps it to 409 CONFLICT — NOT a 4xx for an outage.
var ErrDestinationLocked = errors.New("ride destination cannot be changed in current status")

// ErrNotRideRider: the ride exists but belongs to somebody else. Modelled as
// its own sentinel so the handler can report it without inventing a third
// status code; both it and a genuinely missing ride answer 404, matching
// repository.ErrNotFound's "no row the caller is allowed to see" rule, so a
// caller cannot probe for the existence of other people's rides.
var ErrNotRideRider = errors.New("ride belongs to another rider")

// destinationChangeable lists the statuses in which the itinerary is still
// open. It is deliberately NOT validTransitions: a destination change is a
// data mutation, not a status transition, so it must not consume an edge of
// the state machine or write a ride_events row.
var destinationChangeable = map[string]bool{
	"pending":        true,
	"accepted":       true,
	"driver_arrived": true,
	"in_progress":    true,
}

// ValidationError is a problem with what the client SENT, not with this server.
// Its Message is written for a human reading a Flutter form, so it is the one
// error in this package whose text is allowed to become the HTTP `message`.
// Everything else must be reported with a fixed sentence and its error text
// attached as a cause (see api_plans/[errors] and AGENTS.md fact 8).
type ValidationError struct {
	Message string
	cause   error
}

func (e *ValidationError) Error() string { return e.Message }
func (e *ValidationError) Unwrap() error { return e.cause }

// invalidf builds a ValidationError whose text names the offending stop and
// field. There is no wrapped cause: nothing internal failed, the request is
// simply wrong.
func invalidf(format string, args ...interface{}) *ValidationError {
	return &ValidationError{Message: fmt.Sprintf(format, args...)}
}

// BuildItinerary normalizes a client-sent `stops` array into the ordered stops
// a ride stores, and reports the first problem as a public sentence.
//
// THE FINAL DESTINATION IS DEFINED SOLELY BY THE TOP-LEVEL
// `dropoff_lat/dropoff_lng/dropoff_address`. Those coords are what
// rides.dropoff_* (authoritative for routing, fare and receipt) stores, so the
// itinerary's last row is appended from them and always agrees with that
// scalar. A client stop marked kind:"destination" is therefore REJECTED: if it
// were accepted with different coords, the authoritative scalar (top-level
// dropoff) and the last itinerary row would silently disagree. `DestinationKind`
// still exists for the persisted model and for ChangeDestination's internal
// use — it is simply not something a create request may set.
//
// rules, all of which a client can fix:
//   - sequence is DERIVED from array position (1-based), so "ordering" has a
//     single source of truth and cannot contradict itself;
//   - every client stop is an intermediate stop: `kind` may be omitted or
//     "stop", and anything else is rejected rather than silently coerced;
//   - lat/lng must be present and in range (0 and the antimeridian are real
//     coordinates, so presence is checked, not truthiness).
//
// The final destination is always present: the ride's own dropoff is appended
// last, so an empty array means "no intermediate stops", never "no destination".
//
// Every rejection is a *ValidationError; callers should answer 422 and may use
// its Message as the public text.
func BuildItinerary(reqStops []StopInput, dropoffLat, dropoffLng float64, dropoffAddr string) ([]model.RideStop, error) {
	stops := make([]model.RideStop, 0, len(reqStops)+1)

	for i, in := range reqStops {
		switch kind := in.Kind; kind {
		case "", model.StopKind:
			// Every accepted client stop is an intermediate waypoint.
		case model.DestinationKind:
			return nil, invalidf(
				"stop %d: the final destination is set by dropoff_lat/dropoff_lng/dropoff_address, not by a stop", i+1)
		default:
			return nil, invalidf("stop %d: kind must be omitted or %q", i+1, model.StopKind)
		}
		if in.Lat < -90 || in.Lat > 90 {
			return nil, invalidf("stop %d: latitude out of range", i+1)
		}
		if in.Lng < -180 || in.Lng > 180 {
			return nil, invalidf("stop %d: longitude out of range", i+1)
		}
		stops = append(stops, model.RideStop{
			Sequence: i + 1,
			Kind:     model.StopKind,
			Lat:      in.Lat,
			Lng:      in.Lng,
			Address:  in.Address,
		})
	}

	// Unconditionally the top-level dropoff, so the invariant
	// last_row == rides.dropoff_* holds by construction.
	stops = append(stops, model.RideStop{
		Sequence: len(stops) + 1,
		Kind:     model.DestinationKind,
		Lat:      dropoffLat,
		Lng:      dropoffLng,
		Address:  dropoffAddr,
	})
	return stops, nil
}

// StopInput is one client-supplied waypoint, already bound and range-checked by
// the handler. Sequence is not accepted from the client: see BuildItinerary.
type StopInput struct {
	Kind    string
	Lat     float64
	Lng     float64
	Address string
}

func (s *RideService) RequestRide(riderID string, pickupLat, pickupLng, dropoffLat, dropoffLng float64,
	pickupAddr, dropoffAddr, vehicleType, idempotencyKey string, stops []model.RideStop) (*model.Ride, error) {

	estimate, err := s.fareService.CalculateEstimate(pickupLat, pickupLng, dropoffLat, dropoffLng, vehicleType)
	if err != nil {
		return nil, fmt.Errorf("failed to calculate fare estimate: %w", err)
	}

	ride := &model.Ride{
		RiderID:         riderID,
		PickupLat:       pickupLat,
		PickupLng:       pickupLng,
		DropoffLat:      dropoffLat,
		DropoffLng:      dropoffLng,
		PickupAddress:   pickupAddr,
		DropoffAddress:  dropoffAddr,
		VehicleType:     vehicleType,
		IdempotencyKey:  idempotencyKey,
		BaseFare:        estimate.BaseFare,
		DistanceFare:    estimate.DistanceFare,
		TimeFare:        estimate.TimeFare,
		SurgeMultiplier: estimate.SurgeMultiplier,
		TotalFare:       estimate.Total,
		Stops:           stops,
	}

	if err := s.rideRepo.CreateRide(ride); err != nil {
		return nil, fmt.Errorf("failed to create ride: %w", err)
	}

	if err := s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     ride.ID,
		FromStatus: "",
		ToStatus:   "pending",
		Actor:      "rider",
	}); err != nil {
		// The ride row is already committed; a missing audit row must not fail
		// the request.
		log.Printf("ride %s: failed to record pending event: %v", ride.ID, err)
	}

	s.hub.SendToUser(riderID, websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:    ride.ID,
			Status:    "pending",
			Timestamp: time.Now(),
			Pickup: &websocket.PlaceInfo{
				Lat:     pickupLat,
				Lng:     pickupLng,
				Address: pickupAddr,
			},
			Dropoff: &websocket.PlaceInfo{
				Lat:     dropoffLat,
				Lng:     dropoffLng,
				Address: dropoffAddr,
			},
		},
	})

	return ride, nil
}

func (s *RideService) CancelRide(rideID, actor string) (*model.Ride, error) {
	ride, err := s.rideRepo.FindByID(rideID)
	if err != nil {
		return nil, err
	}

	allowed := validTransitions[ride.Status]
	if !contains(allowed, "cancelled") {
		return nil, errors.New("ride cannot be cancelled in current status")
	}

	now := time.Now()
	if err := s.rideRepo.UpdateRideStatus(rideID, "cancelled", &now); err != nil {
		return nil, err
	}

	if err := s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: ride.Status,
		ToStatus:   "cancelled",
		Actor:      actor,
	}); err != nil {
		log.Printf("ride %s: failed to record cancelled event: %v", rideID, err)
	}

	ride.Status = "cancelled"

	msg := websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:      rideID,
			Status:      "cancelled",
			Timestamp:   time.Now(),
			CancelledBy: actor,
		},
	}
	s.hub.SendToUser(ride.RiderID, msg)
	if ride.DriverID != nil {
		s.hub.SendToUser(*ride.DriverID, msg)
	}

	// A backgrounded rider (or driver) still needs to know their ride is off.
	s.notifyOffline(ride.RiderID, pushMessageForStatus("cancelled", rideID))
	if ride.DriverID != nil {
		s.notifyOffline(*ride.DriverID, pushMessageForStatus("cancelled", rideID))
	}

	return ride, nil
}

func (s *RideService) AdvanceStatus(rideID, newStatus, actor string) (*model.Ride, error) {
	ride, err := s.rideRepo.FindByID(rideID)
	if err != nil {
		return nil, err
	}

	allowed := validTransitions[ride.Status]
	if !contains(allowed, newStatus) {
		return nil, fmt.Errorf("cannot transition from %s to %s", ride.Status, newStatus)
	}

	now := time.Now()
	if err := s.rideRepo.UpdateRideStatus(rideID, newStatus, &now); err != nil {
		return nil, err
	}

	if err := s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: ride.Status,
		ToStatus:   newStatus,
		Actor:      actor,
	}); err != nil {
		log.Printf("ride %s: failed to record %s event: %v", rideID, newStatus, err)
	}

	ride.Status = newStatus

	msg := websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:    rideID,
			Status:    newStatus,
			Timestamp: time.Now(),
		},
	}
	if newStatus == "completed" {
		// The final fare is the booked estimate, unchanged. No GPS odometer or
		// completion duration is captured on the ride row (model.Ride carries the
		// booking-time fare snapshot and status timestamps only), so manufacturing
		// a different completion fare (e.g. a "10% markup") would be fabricated.
		// GPS-based completion fares stay deferred until real odometer/duration
		// telemetry exists; the same trigger is named in fare.go's getRates
		// comment for moving the tariff into a versioned fare_rates table.

		msg.Data = websocket.RideUpdateData{
			RideID:    rideID,
			Status:    newStatus,
			Timestamp: time.Now(),
			Fare: &websocket.FareInfo{
				BaseFare:        ride.BaseFare,
				DistanceFare:    ride.DistanceFare,
				TimeFare:        ride.TimeFare,
				SurgeMultiplier: ride.SurgeMultiplier,
				Total:           ride.TotalFare,
			},
		}
	}
	s.hub.SendToUser(ride.RiderID, msg)
	if ride.DriverID != nil {
		s.hub.SendToUser(*ride.DriverID, msg)
	}

	// Backgrounded clients: fire a push for the transition, but only for
	// whoever has no live socket, so a connected client is not double-notified.
	s.notifyOffline(ride.RiderID, pushMessageForStatus(newStatus, rideID))
	if ride.DriverID != nil {
		s.notifyOffline(*ride.DriverID, pushMessageForStatus(newStatus, rideID))
	}

	return ride, nil
}

// ChangeDestination moves a ride's final destination and returns the mutated
// ride. Only the ride's own rider may do it, and only while the itinerary is
// open (see destinationChangeable).
//
// It deliberately does NOT touch the fare snapshot: the booking-time estimate
// is what the completion path pays out, and repricing a trip the driver has
// already started would silently change the agreed price. It also does not
// re-route: route cost stays meters and the routing contract is frozen, so
// the client re-requests GET /navigation/route for the new leg.
func (s *RideService) ChangeDestination(rideID, riderID string, dest model.RideStop) (*model.Ride, error) {
	ride, err := s.rideRepo.FindByID(rideID)
	if err != nil {
		return nil, err
	}
	if ride.RiderID != riderID {
		return nil, ErrNotRideRider
	}
	if !destinationChangeable[ride.Status] {
		return nil, fmt.Errorf("%w: status=%s", ErrDestinationLocked, ride.Status)
	}

	if err := s.rideRepo.ReplaceDestination(rideID, dest); err != nil {
		return nil, err
	}

	ride.DropoffLat = dest.Lat
	ride.DropoffLng = dest.Lng
	ride.DropoffAddress = dest.Address
	// The row was just written; echo the same instant so the response does not
	// advertise a stale updated_at and invite a pointless conditional update.
	ride.UpdatedAt = time.Now()

	// The driver is the one who has to act on this, so both parties are told.
	// The status is echoed unchanged: this is a data mutation, not a
	// transition, and a client that keys off `status` must not see it move.
	msg := websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:    rideID,
			Status:    ride.Status,
			Timestamp: time.Now(),
			Dropoff: &websocket.PlaceInfo{
				Lat:     dest.Lat,
				Lng:     dest.Lng,
				Address: dest.Address,
			},
		},
	}
	s.hub.SendToUser(ride.RiderID, msg)
	if ride.DriverID != nil {
		s.hub.SendToUser(*ride.DriverID, msg)
	}

	return ride, nil
}

func (s *RideService) Rate(rideID, raterRole, raterID, rateeID string, score int, comment string) error {
	if score < 1 || score > 5 {
		return errors.New("score must be between 1 and 5")
	}

	rating := &model.Rating{
		RideID:    rideID,
		RaterRole: raterRole,
		RaterID:   raterID,
		RateeID:   rateeID,
		Score:     score,
		Comment:   comment,
	}

	return s.rideRepo.CreateRating(rating)
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}
