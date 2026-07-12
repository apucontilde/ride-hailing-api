package service

import (
	"log"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type DispatchService struct {
	rideRepo repository.RideRepository
	geoRepo  repository.GeoRepository
}

func NewDispatchService(rideRepo repository.RideRepository, geoRepo repository.GeoRepository) *DispatchService {
	return &DispatchService{rideRepo: rideRepo, geoRepo: geoRepo}
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

	for _, radius := range searchRadii {
		drivers, err := s.geoRepo.FindNearbyDrivers(ride.PickupLat, ride.PickupLng, radius, maxLimit)
		if err != nil {
			return err
		}

		if len(drivers) > 0 {
			go s.sendRequestsSequentially(ride, drivers)
			return nil
		}
	}

	s.rideRepo.UpdateRideStatus(ride.ID, "no_driver_available", nil)
	log.Printf("ride %s: no drivers found in service area", ride.ID)
	return nil
}

func (s *DispatchService) sendRequestsSequentially(ride *model.Ride, drivers []model.NearbyDriverResult) {
	for _, d := range drivers {
		ok := s.offerRideToDriver(ride.ID, d.DriverID)
		if ok {
			return
		}
	}

	s.rideRepo.UpdateRideStatus(ride.ID, "no_driver_available", nil)
	log.Printf("ride %s: all drivers declined", ride.ID)
}

func (s *DispatchService) offerRideToDriver(rideID, driverID string) bool {
	acceptCh := make(chan bool, 1)

	go func() {
		time.Sleep(30 * time.Second)
		acceptCh <- false
	}()

	select {
	case <-acceptCh:
		return false
	case <-time.After(100 * time.Millisecond):
		return false
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

	s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: "pending",
		ToStatus:   "accepted",
		Actor:      "driver",
	})

	return nil
}

var errConflict = &DispatchConflictError{Message: "ride was already accepted by another driver"}

type DispatchConflictError struct {
	Message string
}

func (e *DispatchConflictError) Error() string {
	return e.Message
}
