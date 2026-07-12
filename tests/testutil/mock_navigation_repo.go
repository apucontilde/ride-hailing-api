package testutil

import (
	"ride-hailing-api/internal/repository"
)

type MockNavigationRepo struct {
	pathFunc func(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error)
}

func NewMockNavigationRepo() *MockNavigationRepo {
	return &MockNavigationRepo{
		pathFunc: func(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error) {
			return []repository.RouteResult{
				{NodeID: 1, AggCost: 0, Lat: fLat, Lng: fLng},
				{NodeID: 2, AggCost: 5000, Lat: tLat, Lng: tLng},
			}, nil
		},
	}
}

func (m *MockNavigationRepo) GetShortestPath(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error) {
	return m.pathFunc(fLat, fLng, tLat, tLng)
}
