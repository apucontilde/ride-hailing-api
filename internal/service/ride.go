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

// CoordinateOutOfRange names the first dimension of (lat, lng) that is outside
// its valid range — "latitude" for lat ∉ [-90, 90], then "longitude" for lng ∉
// [-180, 180] — or "" when both are real coordinates.
//
// It is the ONE definition of the coordinate bounds, shared by the top-level
// create pickup/dropoff pair, the change-destination pair and BuildItinerary's
// stops, so the four magic numbers cannot drift apart. Callers own the public
// wording; the returned token is for composing it (and labels the field when
// several coordinates are wrong).
func CoordinateOutOfRange(lat, lng float64) string {
	switch {
	case lat < -90 || lat > 90:
		return "latitude"
	case lng < -180 || lng > 180:
		return "longitude"
	default:
		return ""
	}
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
		if dim := CoordinateOutOfRange(in.Lat, in.Lng); dim != "" {
			return nil, invalidf("stop %d: %s out of range", i+1, dim)
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

	// Snapshot the booked card's identity alongside the money (migration 019).
	// Stage 02 recomputes from these, not from whatever card is active then.
	fareRegionID := estimate.RegionID
	fareRateID := estimate.RateID
	fareCurrency := estimate.Currency
	gradeUpliftPct := estimate.GradeUpliftPct
	// Snapshot the RAW ascent ONLY when an uplift was actually applied, so the
	// NULL column means "no climb priced this ride" rather than a fabricated 0.
	var gradeAscentM *float64
	if estimate.GradeUpliftPct > 0 {
		gradeAscentM = &estimate.AscentM
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
		FareRegionID:    &fareRegionID,
		FareRateID:      &fareRateID,
		FareCurrency:    &fareCurrency,
		GradeUpliftPct:  &gradeUpliftPct,
		GradeAscentM:    gradeAscentM,
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
		// Actuals (migration 021, api_plans/[tracking]_actual_trip_distance.md).
		// Duration is derived from the status timestamps; driven distance is
		// summed from the in_progress location trace with a noise/teleport gate.
		//
		// An unusable trace leaves ActualDistanceM nil (never a fabricated
		// number) and the fare recompute below falls back to the booked quote.
		// Actuals are only exposed once persisted, so a failed write never
		// advertises values a subsequent ride read would not return.
		actualDuration := ActualDurationSeconds(ride.StartedAt, &now)
		var actualDistance *float64
		if points, perr := s.rideRepo.FindRideTrackPoints(rideID); perr != nil {
			// The completion itself is already committed; a trace read failure
			// must not fail the transition. Distance stays NULL (honest "no
			// usable actual"), never a fabricated 0.
			log.Printf("ride %s: completed but track points could not be read; distance actual omitted: %v", rideID, perr)
		} else {
			actualDistance = DrivenDistanceMeters(points)
		}
		if aerr := s.rideRepo.SetRideActuals(rideID, actualDuration, actualDistance); aerr != nil {
			log.Printf("ride %s: completed but actuals could not be persisted: %v", rideID, aerr)
			actualDuration, actualDistance = nil, nil
		} else {
			ride.ActualDurationS = actualDuration
			ride.ActualDistanceM = actualDistance
		}

		// Final charge (migrations 022/023,
		// api_plans/01_[fare]_actuals_recompute_on_completion.md): recompute from
		// the ACTUALS against the BOOKED card and overwrite the money columns
		// with it, snapshotting the quote into quoted_*. Product decision
		// (2026-10-06): the recomputed actual REPLACES the quote uncapped and is
		// the only charge shown.
		//
		// The final starts as the booked quote and is replaced only by a real
		// recompute. Every failure — no usable actual, an unavailable booked
		// card, a persistence outage — keeps the quote as the charge rather than
		// fabricating one; a failed transition is never an option because the
		// completion is already committed. FinalizeRideFare still runs in the
		// fallback so every completed ride captures its quote exactly once; its
		// `quoted_total_fare IS NULL` guard, together with the status machine
		// rejecting completed -> completed, makes a retry a no-op for the fare.
		//
		// GradeUpliftPct follows the same quote->final split as the money: the
		// booked value is snapshotted by FinalizeRideFare into
		// quoted_grade_uplift_pct and the ADVANCED value is the uplift actually
		// used for the final distance leg, so the receipt/ride JSON
		// `grade_uplift_pct` reconciles with the charged distance_fare (defect 1
		// of the actuals review).
		bookedGradeUplift := ride.GradeUpliftPct
		finalBase, finalDistance := ride.BaseFare, ride.DistanceFare
		finalTime, finalTotal := ride.TimeFare, ride.TotalFare
		finalGradeUplift := bookedGradeUplift
		if s.fareService != nil {
			if est, rerr := s.fareService.RecomputeActualFare(ride); rerr != nil {
				log.Printf("ride %s: completed but actual fare recompute failed; charging the booked quote: %v", rideID, rerr)
			} else if est != nil {
				finalBase, finalDistance = est.BaseFare, est.DistanceFare
				finalTime, finalTotal = est.TimeFare, est.Total
				uplift := est.GradeUpliftPct
				finalGradeUplift = &uplift
			}
		}
		if _, ferr := s.rideRepo.FinalizeRideFare(rideID, finalBase, finalDistance, finalTime, finalTotal, finalGradeUplift); ferr != nil {
			log.Printf("ride %s: completed but final fare could not be persisted; charging the booked quote: %v", rideID, ferr)
		} else {
			// Reflect the final on the returned ride. GradeUpliftPct now carries
			// the APPLIED uplift (final), matching the persisted column and the
			// receipt; the booked value is retained only as the quoted audit.
			ride.BaseFare, ride.DistanceFare = finalBase, finalDistance
			ride.TimeFare, ride.TotalFare = finalTime, finalTotal
			ride.GradeUpliftPct = finalGradeUplift
			ride.QuotedGradeUpliftPct = bookedGradeUplift
		}

		fare := &websocket.FareInfo{
			BaseFare:        ride.BaseFare,
			DistanceFare:    ride.DistanceFare,
			TimeFare:        ride.TimeFare,
			SurgeMultiplier: ride.SurgeMultiplier,
			Total:           ride.TotalFare,
		}
		// Additive fare identity/applied fields so the driver app's reads of
		// `fare.currency` and `fare.grade_uplift_pct` are not dead (defect 4 of
		// the actuals review). currency/region_id are empty for a legacy ride
		// booked before 019; grade_uplift_pct is the APPLIED uplift (final for a
		// completed ride), never the raw booked one when a recompute ran.
		if ride.FareCurrency != nil {
			fare.Currency = *ride.FareCurrency
		}
		if ride.FareRegionID != nil {
			fare.RegionID = *ride.FareRegionID
		}
		if ride.GradeUpliftPct != nil {
			fare.GradeUpliftPct = *ride.GradeUpliftPct
		}

		msg.Data = websocket.RideUpdateData{
			RideID:          rideID,
			Status:          newStatus,
			Timestamp:       now,
			Fare:            fare,
			ActualDurationS: actualDuration,
			ActualDistanceM: actualDistance,
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
// It deliberately does NOT touch the fare snapshot: a destination change alone
// never moves the booked quote, and repricing a trip the driver has already
// started would silently change the agreed price. The completion recompute
// prices the ACTUAL driven trace against the booked card, so a mid-trip
// detour is charged by the distance actually driven, not by re-estimating the
// itinerary here. It also does not re-route: route cost stays meters and the
// routing contract is frozen, so the client re-requests
// GET /navigation/route for the new leg.
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
