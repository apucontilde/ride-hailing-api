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
	// Anchor the drawn line to the exact pins, not just the snapped nodes.
	polyline = appendPoint(polyline, model.LatLng{Lat: fromLat, Lng: fromLng})
	for _, n := range nodes {
		polyline = appendPoint(polyline, model.LatLng{Lat: n.Lat, Lng: n.Lng})
	}
	polyline = appendPoint(polyline, model.LatLng{Lat: toLat, Lng: toLng})

	totalDistance := int(nodes[len(nodes)-1].AggCost)
	// Simple approximation: average speed 11 m/s (~40 km/h)
	totalDuration := totalDistance / 11

	return &RouteInfo{
		DistanceMeters: totalDistance,
		DurationSecs:   totalDuration,
		Polyline:       polyline,
	}, nil
}

func appendPoint(points []model.LatLng, p model.LatLng) []model.LatLng {
	if len(points) > 0 {
		last := points[len(points)-1]
		if last.Lat == p.Lat && last.Lng == p.Lng {
			return points
		}
	}
	return append(points, p)
}
