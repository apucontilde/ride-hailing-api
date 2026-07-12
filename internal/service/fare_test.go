package service

import (
	"testing"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type mockGeoRepo struct {
	countFunc func(lat, lng float64, radiusM float64) (int, error)
}

func (m *mockGeoRepo) UpsertDriverPosition(driverID string, lat, lng, heading, speed float64, status string) error { return nil }
func (m *mockGeoRepo) UpsertRiderPosition(riderID string, lat, lng float64) error { return nil }
func (m *mockGeoRepo) FindNearbyDrivers(lat, lng float64, radiusM float64, limit int) ([]model.NearbyDriverResult, error) { return nil, nil }
func (m *mockGeoRepo) GetDriverLocation(driverID string) (*model.NearbyDriverResult, error) { return nil, nil }
func (m *mockGeoRepo) MarkStaleDriversOffline() error { return nil }
func (m *mockGeoRepo) CountNearbyDrivers(lat, lng float64, radiusM float64) (int, error) {
	return m.countFunc(lat, lng, radiusM)
}

type mockNavRepo struct {
	pathFunc func(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error)
}

func (m *mockNavRepo) GetShortestPath(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error) {
	return m.pathFunc(fLat, fLng, tLat, tLng)
}

func TestFareService_CalculateEstimate(t *testing.T) {
	geoRepo := &mockGeoRepo{
		countFunc: func(lat, lng float64, radiusM float64) (int, error) {
			return 10, nil // No surge
		},
	}

	navRepo := &mockNavRepo{
		pathFunc: func(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error) {
			return []repository.RouteResult{
				{NodeID: 1, AggCost: 0},
				{NodeID: 2, AggCost: 5000}, // 5km
			}, nil
		},
	}
	navSvc := NewNavigationService(navRepo)
	fareSvc := NewFareService(geoRepo, navSvc)

	t.Run("Sedan estimate", func(t *testing.T) {
		est, err := fareSvc.CalculateEstimate(0, 0, 0, 0, "sedan")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		// Base 5.0 + 5km * 1.5 + (5000/11/60)*0.5 = 5.0 + 7.5 + 3.78 = 16.28
		expected := 16.28
		if est.Total != expected {
			t.Errorf("expected %f, got %f", expected, est.Total)
		}
	})

	t.Run("SUV surge estimate", func(t *testing.T) {
		geoRepo.countFunc = func(lat, lng float64, radiusM float64) (int, error) {
			return 2, nil // Surge 1.5
		}
		est, err := fareSvc.CalculateEstimate(0, 0, 0, 0, "suv")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		// Base 8.0 + 5km * 2.0 + (5000/11/60)*0.7 = 8.0 + 10.0 + 5.3 = 23.3
		// Total = 23.3 * 1.5 = 34.95
		expected := 34.95
		if est.Total != expected {
			t.Errorf("expected %f, got %f", expected, est.Total)
		}
	})
}
