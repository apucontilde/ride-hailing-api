package service

import (
	"fmt"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type RouteInfo struct {
	DistanceMeters int
	DurationSecs   int
	Polyline       []model.LatLng
}

type NavigationService struct {
	navRepo repository.NavigationRepository
}

func NewNavigationService(navRepo repository.NavigationRepository) *NavigationService {
	return &NavigationService{navRepo: navRepo}
}

func (s *NavigationService) GetRoute(fromLat, fromLng, toLat, toLng float64) (*RouteInfo, error) {
	nodes, err := s.navRepo.GetShortestPath(fromLat, fromLng, toLat, toLng)
	if err != nil {
		return nil, err
	}
	if len(nodes) == 0 {
		return nil, fmt.Errorf("no route found")
	}

	var polyline []model.LatLng
	for _, n := range nodes {
		polyline = append(polyline, model.LatLng{
			Lat: n.Lat,
			Lng: n.Lng,
		})
	}

	totalDistance := int(nodes[len(nodes)-1].AggCost)
	// Simple approximation: average speed 11 m/s (~40 km/h)
	totalDuration := totalDistance / 11

	return &RouteInfo{
		DistanceMeters: totalDistance,
		DurationSecs:   totalDuration,
		Polyline:       polyline,
	}, nil
}
