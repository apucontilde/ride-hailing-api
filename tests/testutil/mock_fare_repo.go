package testutil

import (
	"fmt"
	"sync"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// MockFareRepo is the in-memory pricing store for the db-less harnesses. It is
// seeded with the pre-[fare] hardcoded card for the default region so a test
// server prices exactly as the legacy switch did (api_plans/STATUS.md
// [fare]). Tests can add regions/cards/windows to
// exercise the engine without a database.
type MockFareRepo struct {
	mu      sync.Mutex
	regions map[string]*model.FareRegion
	rates   map[string]*model.FareRate // key: regionID + "|" + vehicleType
	// ratesByID indexes the same cards by primary key so GetFareRateByID (the
	// completion recompute seam) can resolve the BOOKED card even after a
	// successor closes it.
	ratesByID map[string]*model.FareRate // key: rate id
	windows   map[string][]model.FareDemandWindow

	defaultRegionID string
}

func NewMockFareRepo() *MockFareRepo {
	m := &MockFareRepo{
		regions:         make(map[string]*model.FareRegion),
		rates:           make(map[string]*model.FareRate),
		ratesByID:       make(map[string]*model.FareRate),
		windows:         make(map[string][]model.FareDemandWindow),
		defaultRegionID: "cr-sj",
	}
	m.SetRegion("cr-sj", "USD", "America/Costa_Rica")
	// The legacy card, converted to cents (fastest: the same numbers the unit
	// tests assert).
	m.SetRate("cr-sj", "sedan", 500, 150, 50)
	m.SetRate("cr-sj", "suv", 800, 200, 70)
	m.SetRate("cr-sj", "luxury", 1200, 300, 100)
	return m
}

func fareKey(regionID, vehicleType string) string { return regionID + "|" + vehicleType }

func (m *MockFareRepo) SetRegion(regionID, currency, timezone string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.regions[regionID] = &model.FareRegion{
		RegionID: regionID, Currency: currency, Timezone: timezone,
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
}

func (m *MockFareRepo) SetRate(regionID, vehicleType string, baseCents, perKmCents, perMinCents int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	regionCurrency := "USD"
	if r, ok := m.regions[regionID]; ok {
		regionCurrency = r.Currency
	}
	card := &model.FareRate{
		ID:            newID(),
		RegionID:      regionID,
		VehicleType:   vehicleType,
		Currency:      regionCurrency,
		BaseFareCents: baseCents,
		PerKmCents:    perKmCents,
		PerMinCents:   perMinCents,
		EffectiveFrom: time.Now().Add(-time.Hour),
	}
	m.rates[fareKey(regionID, vehicleType)] = card
	m.ratesByID[card.ID] = card
}

// SetRateCurrency overrides only the currency on an existing card, to make the
// currency-mismatch error reachable in tests.
func (m *MockFareRepo) SetRateCurrency(regionID, vehicleType, currency string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r, ok := m.rates[fareKey(regionID, vehicleType)]; ok {
		r.Currency = currency
	}
}

// SetRateUplift enables the migration-020 climb uplift knobs on an existing
// card. The default card leaves them 0 (feature off), matching the shipped
// fail-flat contract.
func (m *MockFareRepo) SetRateUplift(regionID, vehicleType string, factor, cap float64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r, ok := m.rates[fareKey(regionID, vehicleType)]; ok {
		r.GradeUpliftFactor = factor
		r.GradeUpliftCap = cap
	}
}

func (m *MockFareRepo) SetWindows(regionID string, windows ...model.FareDemandWindow) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.windows[regionID] = windows
}

func (m *MockFareRepo) SetDefaultRegion(regionID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.defaultRegionID = regionID
}

func (m *MockFareRepo) GetFareRegion(regionID string) (*model.FareRegion, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.regions[regionID]
	if !ok {
		return nil, fmt.Errorf("load fare region: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

func (m *MockFareRepo) GetActiveFareRate(regionID, vehicleType string, at time.Time) (*model.FareRate, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.rates[fareKey(regionID, vehicleType)]
	if !ok {
		return nil, fmt.Errorf("load active fare rate: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

// GetFareRateByID resolves a card by primary key, ignoring the effective
// window, so a completed-ride recompute prices against the BOOKED card.
func (m *MockFareRepo) GetFareRateByID(rateID string) (*model.FareRate, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.ratesByID[rateID]
	if !ok {
		return nil, fmt.Errorf("load fare rate by id: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

func (m *MockFareRepo) ListDemandWindows(regionID string) ([]model.FareDemandWindow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := append([]model.FareDemandWindow(nil), m.windows[regionID]...)
	if out == nil {
		return []model.FareDemandWindow{}, nil
	}
	return out, nil
}

func (m *MockFareRepo) DefaultRegionID() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.defaultRegionID == "" {
		return "", fmt.Errorf("load default region: %w", repository.ErrNotFound)
	}
	return m.defaultRegionID, nil
}
