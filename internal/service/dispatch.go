package service

import (
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

type DispatchService struct {
	rideRepo        repository.RideRepository
	geoRepo         repository.GeoRepository
	userRepo        repository.UserRepository
	navSvc          *NavigationService
	hub             *websocket.Hub
	offerChannels   map[string]chan bool
	offerChannelsMu sync.Mutex
}

func NewDispatchService(rideRepo repository.RideRepository, geoRepo repository.GeoRepository, userRepo repository.UserRepository, hub *websocket.Hub, navSvc *NavigationService) *DispatchService {
	return &DispatchService{
		rideRepo:      rideRepo,
		geoRepo:       geoRepo,
		userRepo:      userRepo,
		navSvc:        navSvc,
		hub:           hub,
		offerChannels: make(map[string]chan bool),
	}
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
	s.pushNoDriverAvailable(ride)
	return nil
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
	for _, d := range drivers {
		ok := s.offerRideToDriver(ride.ID, d.DriverID)
		if ok {
			if err := s.AcceptRide(ride.ID, d.DriverID); err != nil {
				log.Printf("failed to accept ride %s for driver %s: %v", ride.ID, d.DriverID, err)
				continue
			}
			return
		}
	}

	current, err := s.rideRepo.FindByID(ride.ID)
	if err == nil && current.Status == "pending" {
		s.rideRepo.UpdateRideStatus(ride.ID, "no_driver_available", nil)
		log.Printf("ride %s: all drivers declined", ride.ID)
		s.pushNoDriverAvailable(ride)
	}
}

func (s *DispatchService) offerRideToDriver(rideID, driverID string) bool {
	if !s.hub.IsConnected(driverID) {
		time.Sleep(100 * time.Millisecond)
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
		return result
	case <-time.After(30 * time.Second):
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

	s.rideRepo.CreateEvent(&model.RideEvent{
		RideID:     rideID,
		FromStatus: "pending",
		ToStatus:   "accepted",
		Actor:      "driver",
	})

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
