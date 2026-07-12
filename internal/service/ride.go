package service

import (
	"errors"
	"fmt"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

type RideService struct {
	rideRepo repository.RideRepository
	userRepo repository.UserRepository
	hub      *websocket.Hub
}

func NewRideService(rideRepo repository.RideRepository, userRepo repository.UserRepository, hub *websocket.Hub) *RideService {
	return &RideService{rideRepo: rideRepo, userRepo: userRepo, hub: hub}
}

var validTransitions = map[string][]string{
	"pending":       {"accepted", "cancelled", "no_driver_available"},
	"accepted":      {"driver_arrived", "cancelled"},
	"driver_arrived": {"in_progress", "cancelled"},
	"in_progress":   {"completed"},
	"completed":     {},
	"cancelled":     {},
}

func (s *RideService) RequestRide(riderID string, pickupLat, pickupLng, dropoffLat, dropoffLng float64,
	pickupAddr, dropoffAddr, vehicleType, idempotencyKey string) (*model.Ride, error) {

	ride := &model.Ride{
		RiderID:        riderID,
		PickupLat:      pickupLat,
		PickupLng:      pickupLng,
		DropoffLat:     dropoffLat,
		DropoffLng:     dropoffLng,
		PickupAddress:  pickupAddr,
		DropoffAddress: dropoffAddr,
		VehicleType:    vehicleType,
		IdempotencyKey: idempotencyKey,
	}

	if err := s.rideRepo.CreateRide(ride); err != nil {
		return nil, fmt.Errorf("failed to create ride: %w", err)
	}

	s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     ride.ID,
		FromStatus: "",
		ToStatus:   "pending",
		Actor:      "rider",
	})

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

	s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: ride.Status,
		ToStatus:   "cancelled",
		Actor:      actor,
	})

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

	s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: ride.Status,
		ToStatus:   newStatus,
		Actor:      actor,
	})

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
