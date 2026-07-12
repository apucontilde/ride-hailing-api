package service

import (
	"fmt"
	"math"

	"ride-hailing-api/internal/repository"
)

type FareEstimate struct {
	BaseFare        float64
	DistanceFare    float64
	TimeFare        float64
	SurgeMultiplier float64
	Total           float64
}

type FareService struct {
	geoRepo repository.GeoRepository
	navSvc  *NavigationService
}

func NewFareService(geoRepo repository.GeoRepository, navSvc *NavigationService) *FareService {
	return &FareService{geoRepo: geoRepo, navSvc: navSvc}
}

func (s *FareService) CalculateEstimate(pickupLat, pickupLng, dropoffLat, dropoffLng float64, vehicleType string) (*FareEstimate, error) {
	route, err := s.navSvc.GetRoute(pickupLat, pickupLng, dropoffLat, dropoffLng)
	if err != nil {
		return nil, fmt.Errorf("failed to calculate route for fare: %w", err)
	}

	dist := float64(route.DistanceMeters)
	dur := float64(route.DurationSecs)

	base, distRate, timeRate := s.getRates(vehicleType)
	surge := s.calculateSurge(pickupLat, pickupLng)

	distFare := dist / 1000.0 * distRate
	timeFare := (dur / 60.0) * timeRate
	total := (base + distFare + timeFare) * surge

	return &FareEstimate{
		BaseFare:        base,
		DistanceFare:    distFare,
		TimeFare:        timeFare,
		SurgeMultiplier: surge,
		Total:           math.Round(total*100) / 100,
	}, nil
}

func (s *FareService) calculateSurge(lat, lng float64) float64 {
	// Surge radius: 2km
	drivers, err := s.geoRepo.CountNearbyDrivers(lat, lng, 2000)
	if err != nil {
		return 1.0
	}

	// Heuristic: if < 5 drivers, increase surge
	if drivers == 0 {
		return 2.0
	} else if drivers < 5 {
		return 1.5
	}
	return 1.0
}

func (s *FareService) getRates(vehicleType string) (base, distRate, timeRate float64) {
	switch vehicleType {
	case "suv":
		return 8.0, 2.0, 0.7
	case "luxury":
		return 12.0, 3.0, 1.0
	default: // sedan
		return 5.0, 1.5, 0.5
	}
}
