package service

import (
	"errors"
	"fmt"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type RideService struct {
	rideRepo repository.RideRepository
	userRepo repository.UserRepository
}

func NewRideService(rideRepo repository.RideRepository, userRepo repository.UserRepository) *RideService {
	return &RideService{rideRepo: rideRepo, userRepo: userRepo}
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
