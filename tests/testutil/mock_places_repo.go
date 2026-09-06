package testutil

import (
	"sync"

	"ride-hailing-api/internal/model"
)

type MockPlacesRepo struct {
	mu     sync.Mutex
	places []model.PlaceSeed
}

func NewMockPlacesRepo() *MockPlacesRepo {
	return &MockPlacesRepo{places: make([]model.PlaceSeed, 0)}
}

// Seed lets tests preload places without going through BulkInsert.
func (m *MockPlacesRepo) Seed(places ...model.PlaceSeed) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.places = append(m.places, places...)
}

func (m *MockPlacesRepo) FindNearbyPlaces(lat, lng, radiusM float64, query string, limit int) ([]model.NearbyPlaceResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var results []model.NearbyPlaceResult
	for _, p := range m.places {
		dist := haversine(lat, lng, p.Lat, p.Lng) * 1000
		if dist > radiusM {
			continue
		}
		if query != "" && !containsFold(p.Name, query) {
			continue
		}
		results = append(results, model.NearbyPlaceResult{
			Place: model.Place{
				Name:     p.Name,
				Category: p.Category,
				Address:  p.Address,
				Lat:      p.Lat,
				Lng:      p.Lng,
			},
			DistanceM: dist,
		})
		if len(results) >= limit {
			break
		}
	}
	return results, nil
}

func (m *MockPlacesRepo) ReverseGeocode(lat, lng, radiusM float64) (*model.NearbyPlaceResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var nearest *model.NearbyPlaceResult
	var nearestDist float64
	for _, p := range m.places {
		dist := haversine(lat, lng, p.Lat, p.Lng) * 1000
		if dist > radiusM {
			continue
		}
		if nearest == nil || dist < nearestDist {
			result := &model.NearbyPlaceResult{
				Place: model.Place{
					Name:     p.Name,
					Category: p.Category,
					Address:  p.Address,
					Lat:      p.Lat,
					Lng:      p.Lng,
				},
				DistanceM: dist,
			}
			nearest = result
			nearestDist = dist
		}
	}
	return nearest, nil
}

func (m *MockPlacesRepo) CountPlaces() (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.places), nil
}

func (m *MockPlacesRepo) BulkInsert(places []model.PlaceSeed) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.places = append(m.places, places...)
	return len(places), nil
}

func containsFold(haystack, needle string) bool {
	h := []rune(toLower(haystack))
	n := []rune(toLower(needle))
	if len(n) == 0 {
		return true
	}
	for i := 0; i+len(n) <= len(h); i++ {
		match := true
		for j := 0; j < len(n); j++ {
			if h[i+j] != n[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

func toLower(s string) string {
	b := []rune(s)
	for i, r := range b {
		if r >= 'A' && r <= 'Z' {
			b[i] = r + 32
		}
	}
	return string(b)
}
