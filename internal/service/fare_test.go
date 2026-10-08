package service

import (
	"math"
	"testing"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type mockGeoRepo struct {
	countFunc func(lat, lng float64, radiusM float64) (int, error)
}

func (m *mockGeoRepo) UpsertDriverPosition(driverID string, lat, lng, heading, speed float64, status string) error {
	return nil
}
func (m *mockGeoRepo) UpsertRiderPosition(riderID string, lat, lng float64) error { return nil }
func (m *mockGeoRepo) FindNearbyDrivers(lat, lng float64, radiusM float64, limit int) ([]model.NearbyDriverResult, error) {
	return nil, nil
}
func (m *mockGeoRepo) GetDriverLocation(driverID string) (*model.NearbyDriverResult, error) {
	return nil, nil
}
func (m *mockGeoRepo) MarkStaleDriversOffline() error { return nil }
func (m *mockGeoRepo) TouchDriverPresence(driverID, status string) error {
	return nil
}
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
	navRepo := &mockNavRepo{
		pathFunc: func(fLat, fLng, tLat, tLng float64) ([]repository.RouteResult, error) {
			return []repository.RouteResult{
				{NodeID: 1, AggCost: 0},
				{NodeID: 2, AggCost: 5000}, // 5 km, duration 5000/11 = 454 s
			}, nil
		},
	}
	navSvc := NewNavigationService(navRepo)

	cases := []struct {
		name         string
		vehicle      string
		drivers      int
		wantBase     float64
		wantDistance float64
		wantTime     float64
		wantSurge    float64
		wantTotal    float64
	}{
		{
			name:    "sedan_no_surge",
			vehicle: "sedan",
			drivers: 10, // >= 5 drivers -> supply 1.0
			// Base 5.00 + 5 km * 1.50 + (454/60)*0.50 = 5.00 + 7.50 + 3.7833
			wantBase:     5.00,
			wantDistance: 7.50,
			wantTime:     3.783333333333333,
			wantSurge:    1.0,
			wantTotal:    16.28,
		},
		{
			name:    "suv_surge",
			vehicle: "suv",
			drivers: 2, // < 5 drivers -> supply 1.5
			// Base 8.00 + 5 km * 2.00 + (454/60)*0.70 = 23.2966; * 1.5 = 34.95
			wantBase:     8.00,
			wantDistance: 10.00,
			wantTime:     5.296666666666667,
			wantSurge:    1.5,
			wantTotal:    34.95,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// A fresh geo repo per case, so no shared countFunc is mutated
			// across cases.
			geoRepo := &mockGeoRepo{
				countFunc: func(lat, lng float64, radiusM float64) (int, error) {
					return tc.drivers, nil
				},
			}
			fareSvc := NewFareService(geoRepo, navSvc, newFakeFareRepo(), testFareConfig())

			est, err := fareSvc.CalculateEstimate(0, 0, 0, 0, tc.vehicle)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			const eps = 1e-9
			if math.Abs(est.BaseFare-tc.wantBase) > eps {
				t.Errorf("base fare = %v, want %v", est.BaseFare, tc.wantBase)
			}
			if math.Abs(est.DistanceFare-tc.wantDistance) > eps {
				t.Errorf("distance fare = %v, want %v", est.DistanceFare, tc.wantDistance)
			}
			if math.Abs(est.TimeFare-tc.wantTime) > eps {
				t.Errorf("time fare = %v, want %v", est.TimeFare, tc.wantTime)
			}
			if math.Abs(est.SurgeMultiplier-tc.wantSurge) > eps {
				t.Errorf("surge = %v, want %v", est.SurgeMultiplier, tc.wantSurge)
			}
			if est.Total != tc.wantTotal {
				t.Errorf("total = %v, want %v", est.Total, tc.wantTotal)
			}
		})
	}
}
