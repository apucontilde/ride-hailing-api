package service

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// testFareConfig is the shipped pricing config without touching the process
// environment.
func testFareConfig() *config.Config {
	return &config.Config{
		FareCurrency:      config.DefaultFareCurrency,
		FareMaxMultiplier: config.DefaultFareMaxMultiplier,
	}
}

// fakeFareRepo is a DB-free FareRepository. It mirrors only the contract the
// service depends on; the real SQL (active-row selection, expiry, the default
// flag) is proven by the integration tests.
type fakeFareRepo struct {
	regions       map[string]*model.FareRegion
	rates         map[string]*model.FareRate
	windows       map[string][]model.FareDemandWindow
	defaultRegion string
}

func newFakeFareRepo() *fakeFareRepo {
	f := &fakeFareRepo{
		regions:       map[string]*model.FareRegion{},
		rates:         map[string]*model.FareRate{},
		windows:       map[string][]model.FareDemandWindow{},
		defaultRegion: "cr-sj",
	}
	f.addRegion("cr-sj", "USD", "America/Costa_Rica")
	f.addRate("cr-sj", "sedan", "USD", 500, 150, 50)
	f.addRate("cr-sj", "suv", "USD", 800, 200, 70)
	f.addRate("cr-sj", "luxury", "USD", 1200, 300, 100)
	return f
}

func (f *fakeFareRepo) addRegion(id, currency, timezone string) {
	f.regions[id] = &model.FareRegion{RegionID: id, Currency: currency, Timezone: timezone}
}

func (f *fakeFareRepo) addRate(regionID, vehicleType, currency string, base, km, min int) {
	f.rates[regionID+"|"+vehicleType] = &model.FareRate{
		ID: "rate-" + regionID + "-" + vehicleType, RegionID: regionID, VehicleType: vehicleType,
		Currency: currency, BaseFareCents: base, PerKmCents: km, PerMinCents: min,
	}
}

// setUplift enables the per-card climb uplift knobs (migration 020) on an
// existing card. The default card has them 0 (feature off), which is what keeps
// the legacy-equivalence tests honest.
func (f *fakeFareRepo) setUplift(regionID, vehicleType string, factor, cap float64) {
	if r, ok := f.rates[regionID+"|"+vehicleType]; ok {
		r.GradeUpliftFactor = factor
		r.GradeUpliftCap = cap
	}
}

func (f *fakeFareRepo) GetFareRegion(regionID string) (*model.FareRegion, error) {
	r, ok := f.regions[regionID]
	if !ok {
		return nil, fmt.Errorf("load fare region: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

func (f *fakeFareRepo) GetActiveFareRate(regionID, vehicleType string, _ time.Time) (*model.FareRate, error) {
	r, ok := f.rates[regionID+"|"+vehicleType]
	if !ok {
		return nil, fmt.Errorf("load active fare rate: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

// GetFareRateByID resolves the BOOKED card for the completion recompute. The
// fake stores cards by region|vehicle, so it scans by id; the real SQL does a
// primary-key lookup with no effective-window filter, proven against a live DB
// by TestRecomputeActualFarePricesViaClosedBookedCardIntegration
// (fare_recompute_integration_test.go).
func (f *fakeFareRepo) GetFareRateByID(rateID string) (*model.FareRate, error) {
	for _, r := range f.rates {
		if r.ID == rateID {
			cp := *r
			return &cp, nil
		}
	}
	return nil, fmt.Errorf("load fare rate by id: %w", repository.ErrNotFound)
}

func (f *fakeFareRepo) ListDemandWindows(regionID string) ([]model.FareDemandWindow, error) {
	out := append([]model.FareDemandWindow(nil), f.windows[regionID]...)
	if out == nil {
		return []model.FareDemandWindow{}, nil
	}
	return out, nil
}

func (f *fakeFareRepo) DefaultRegionID() (string, error) {
	if f.defaultRegion == "" {
		return "", fmt.Errorf("load default region: %w", repository.ErrNotFound)
	}
	return f.defaultRegion, nil
}

// fixedRouteGeo returns a geo repo whose driver count is a constant, so the
// supply factor is deterministic.
func fixedRouteGeo(drivers int) *mockGeoRepo {
	return &mockGeoRepo{countFunc: func(_, _ float64, _ float64) (int, error) { return drivers, nil }}
}

func legacyNav() *NavigationService {
	return NewNavigationService(&mockNavRepo{
		pathFunc: func(_, _, _, _ float64) ([]repository.RouteResult, error) {
			return []repository.RouteResult{
				{NodeID: 1, AggCost: 0},
				{NodeID: 2, AggCost: 5000}, // 5 km, duration 454 s
			}, nil
		},
	})
}

// The core equivalence claim: with an empty demand-window table the unified
// multiplier is just the driver heuristic, so every vehicle class reproduces
// the pre-[fare] hardcoded card's total exactly.
func TestFareService_EmptyWindowsReproduceLegacyTotals(t *testing.T) {
	svc := NewFareService(fixedRouteGeo(10), legacyNav(), newFakeFareRepo(), testFareConfig())

	cases := []struct {
		vehicleType string
		wantTotal   float64
	}{
		{"sedan", 16.28},
		{"suv", 23.30},
		{"luxury", 34.57},
	}
	for _, tc := range cases {
		t.Run(tc.vehicleType, func(t *testing.T) {
			est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, tc.vehicleType)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if est.Total != tc.wantTotal {
				t.Errorf("total = %v, want the legacy %v", est.Total, tc.wantTotal)
			}
			if est.DemandMultiplier != 1.0 || est.SupplyMultiplier != 1.0 || est.SurgeMultiplier != 1.0 {
				t.Errorf("multipliers = demand %v supply %v conditions %v, want 1/1/1",
					est.DemandMultiplier, est.SupplyMultiplier, est.SurgeMultiplier)
			}
			if est.RegionID != "cr-sj" || est.Currency != "USD" || est.RateID == "" {
				t.Errorf("card metadata = region %q currency %q rate %q, want cr-sj/USD/non-empty",
					est.RegionID, est.Currency, est.RateID)
			}
		})
	}
}

// Two regions with independent cards price independently, and the region the
// resolver picked is the one that prices.
func TestFareService_TwoRegionsPriceIndependently(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.covered[pinKey(lcPin)] = map[string]bool{"cr-lc": true}
	repo.covered[pinKey(lcDropPin)] = map[string]bool{"cr-lc": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 5000}},
		"cr-lc": {{NodeID: 1, AggCost: 0}, {NodeID: 2, AggCost: 5000}},
	}
	fares := newFakeFareRepo()
	fares.addRegion("cr-lc", "USD", "America/Costa_Rica")
	fares.addRate("cr-lc", "sedan", "USD", 900, 250, 90) // a different card

	svc := NewFareService(fixedRouteGeo(10), NewNavigationService(repo), fares, testFareConfig())

	sj, err := svc.CalculateEstimate(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1], "sedan")
	if err != nil {
		t.Fatalf("cr-sj: %v", err)
	}
	lc, err := svc.CalculateEstimate(lcPin[0], lcPin[1], lcDropPin[0], lcDropPin[1], "sedan")
	if err != nil {
		t.Fatalf("cr-lc: %v", err)
	}
	if sj.RegionID != "cr-sj" || lc.RegionID != "cr-lc" {
		t.Fatalf("regions = %q / %q, want cr-sj / cr-lc", sj.RegionID, lc.RegionID)
	}
	if sj.Total == lc.Total {
		t.Errorf("both regions priced %v; the cards are different and must price independently", sj.Total)
	}
	if lc.BaseFare != 9.0 || lc.DistanceRate != 2.5 {
		t.Errorf("cr-lc card = base %v/km %v, want 9.0/2.5", lc.BaseFare, lc.DistanceRate)
	}
}

// A region with no pricing row fails closed; it is never priced with another
// region's card.
func TestFareService_NoCardRegionErrors(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1}, {NodeID: 2, AggCost: 5000}},
	}
	fares := newFakeFareRepo()
	delete(fares.rates, "cr-sj|sedan") // the region has no sedan card

	svc := NewFareService(fixedRouteGeo(10), NewNavigationService(repo), fares, testFareConfig())
	_, err := svc.CalculateEstimate(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1], "sedan")
	if err == nil {
		t.Fatal("a region with no active card must error")
	}
	var cfgErr *FareConfigurationError
	if !errors.As(err, &cfgErr) {
		t.Errorf("error = %v, want a *FareConfigurationError", err)
	}
}

// A card authored in a different currency than the region (or than
// FARE_CURRENCY) is a configuration error, never a silent conversion.
func TestFareService_CurrencyMismatchErrors(t *testing.T) {
	t.Run("card_vs_region", func(t *testing.T) {
		fares := newFakeFareRepo()
		fares.rates["cr-sj|sedan"].Currency = "EUR"
		svc := NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())
		_, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
		var cfgErr *FareConfigurationError
		if err == nil || !errors.As(err, &cfgErr) {
			t.Fatalf("error = %v, want a currency configuration error", err)
		}
	})

	t.Run("region_vs_fare_currency", func(t *testing.T) {
		fares := newFakeFareRepo()
		fares.regions["cr-sj"].Currency = "CRC"
		svc := NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())
		_, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
		var cfgErr *FareConfigurationError
		if err == nil || !errors.As(err, &cfgErr) {
			t.Fatalf("error = %v, want a FARE_CURRENCY configuration error", err)
		}
	})
}

// An empty region (estimate / legacy) uses ONLY the registry default row.
func TestFareService_EmptyRegionUsesDefaultRegion(t *testing.T) {
	fares := newFakeFareRepo()
	svc := NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())

	est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.RegionID != "cr-sj" {
		t.Errorf("region = %q, want the default cr-sj", est.RegionID)
	}

	// No default row at all: fail closed, do not guess.
	fares.defaultRegion = ""
	svc = NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())
	if _, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan"); err == nil {
		t.Fatal("no default region must be a configuration error")
	}
}

func TestDemandFactor(t *testing.T) {
	// 2026-10-05 is a Monday; 08:00 local. Sunday is day_mask bit 0.
	monday := 1 << uint(time.Monday)
	sunday := 1 << uint(time.Sunday)

	windows := []model.FareDemandWindow{
		{Name: "am_peak", DayMask: monday, StartMinute: 7 * 60, EndMinute: 9 * 60, Multiplier: 1.4},
		{Name: "late", DayMask: monday, StartMinute: 23 * 60, EndMinute: 2 * 60, Multiplier: 1.2},
		{Name: "sunday_only", DayMask: sunday, StartMinute: 0, EndMinute: 1440, Multiplier: 2.0},
	}
	sj := mustLoad(t, "America/Costa_Rica") // UTC-6

	cases := []struct {
		name string
		at   time.Time
		loc  *time.Location
		want float64
	}{
		{"monday 08:00 local", time.Date(2026, 10, 5, 14, 0, 0, 0, time.UTC), sj, 1.4}, // 14:00Z == 08:00 CR
		{"start boundary is inclusive", time.Date(2026, 10, 5, 13, 0, 0, 0, time.UTC), sj, 1.4},
		{"end boundary is exclusive", time.Date(2026, 10, 5, 15, 0, 0, 0, time.UTC), sj, 1.0},
		{"just before end", time.Date(2026, 10, 5, 14, 59, 0, 0, time.UTC), sj, 1.4},
		{"wraps past midnight", time.Date(2026, 10, 6, 5, 0, 0, 0, time.UTC), sj, 1.2}, // 23:00 CR Monday
		{"day_mask excludes other weekdays", time.Date(2026, 10, 6, 14, 0, 0, 0, time.UTC), sj, 1.0},
		{"no location", time.Date(2026, 10, 5, 14, 0, 0, 0, time.UTC), nil, 1.0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := demandFactor(windows, tc.loc, tc.at); got != tc.want {
				t.Errorf("demand = %v, want %v", got, tc.want)
			}
		})
	}
}

// A timezone offset case: the same instant is peak in one region and flat in
// another because each is evaluated at its own local wall clock.
func TestDemandFactor_TimezoneOffset(t *testing.T) {
	window := []model.FareDemandWindow{
		{Name: "am_peak", DayMask: 127, StartMinute: 8 * 60, EndMinute: 9 * 60, Multiplier: 1.5},
	}
	// 13:30 UTC.
	at := time.Date(2026, 10, 5, 13, 30, 0, 0, time.UTC)

	cr := mustLoad(t, "America/Costa_Rica") // UTC-6 -> 07:30, outside
	es := mustLoad(t, "Europe/Madrid")      // UTC+2 -> 15:30, outside
	if got := demandFactor(window, cr, at); got != 1.0 {
		t.Errorf("Costa Rica demand = %v, want 1.0 (07:30 local)", got)
	}
	if got := demandFactor(window, es, at); got != 1.0 {
		t.Errorf("Madrid demand = %v, want 1.0 (15:30 local)", got)
	}
	// 14:30 UTC is 08:30 CR -> peak, 16:30 Madrid -> flat.
	at = at.Add(time.Hour)
	if got := demandFactor(window, cr, at); got != 1.5 {
		t.Errorf("Costa Rica demand = %v, want 1.5 (08:30 local)", got)
	}
	if got := demandFactor(window, es, at); got != 1.0 {
		t.Errorf("Madrid demand = %v, want 1.0 (16:30 local)", got)
	}
}

func TestDemandFactor_HighestMatchingWindowWins(t *testing.T) {
	allDay := []model.FareDemandWindow{
		{Name: "base", DayMask: 127, StartMinute: 0, EndMinute: 1440, Multiplier: 1.1},
		{Name: "peak", DayMask: 127, StartMinute: 8 * 60, EndMinute: 9 * 60, Multiplier: 1.6},
	}
	loc := mustLoad(t, "UTC")
	at := time.Date(2026, 10, 5, 8, 30, 0, 0, time.UTC)
	if got := demandFactor(allDay, loc, at); got != 1.6 {
		t.Errorf("demand = %v, want the highest matching window 1.6", got)
	}
}

func TestClampMultiplier(t *testing.T) {
	cases := []struct {
		v, max, want float64
	}{
		{0.5, 3.0, 1.0}, // never below the tariff
		{1.0, 3.0, 1.0},
		{2.5, 3.0, 2.5},
		{9.0, 3.0, 3.0}, // capped
	}
	for _, tc := range cases {
		if got := clampMultiplier(tc.v, tc.max); got != tc.want {
			t.Errorf("clamp(%v, %v) = %v, want %v", tc.v, tc.max, got, tc.want)
		}
	}
}

// demand × supply is clamped at FARE_MAX_MULTIPLIER; a demand window alone can
// already hit the cap.
func TestFareService_ConditionsClampAtMax(t *testing.T) {
	fares := newFakeFareRepo()
	fares.windows["cr-sj"] = []model.FareDemandWindow{
		{Name: "surge", DayMask: 127, StartMinute: 0, EndMinute: 1440, Multiplier: 2.5},
	}
	// Zero drivers -> supply 2.0; 2.5 * 2.0 = 5.0 -> capped at 3.0.
	svc := NewFareService(fixedRouteGeo(0), legacyNav(), fares, testFareConfig())
	svc.now = func() time.Time { return time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC) }

	est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.DemandMultiplier != 2.5 || est.SupplyMultiplier != 2.0 {
		t.Errorf("factors = demand %v supply %v, want 2.5/2.0", est.DemandMultiplier, est.SupplyMultiplier)
	}
	if est.SurgeMultiplier != config.DefaultFareMaxMultiplier {
		t.Errorf("conditions = %v, want the cap %v", est.SurgeMultiplier, config.DefaultFareMaxMultiplier)
	}
}

// A region with no timezone cannot use demand windows: factor 1.0, never a
// guessed offset.
func TestFareService_NoTimezoneDemandIsOne(t *testing.T) {
	fares := newFakeFareRepo()
	fares.regions["cr-sj"].Timezone = ""
	fares.windows["cr-sj"] = []model.FareDemandWindow{
		{Name: "all_day", DayMask: 127, StartMinute: 0, EndMinute: 1440, Multiplier: 2.0},
	}
	svc := NewFareService(fixedRouteGeo(10), legacyNav(), fares, testFareConfig())
	svc.now = func() time.Time { return time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC) }

	est, err := svc.CalculateEstimate(9.93, -84.08, 9.94, -84.07, "sedan")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if est.DemandMultiplier != 1.0 {
		t.Errorf("demand = %v, want 1.0 with no timezone", est.DemandMultiplier)
	}
}

func mustLoad(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("LoadLocation(%q): %v", name, err)
	}
	return loc
}
