package service

import (
	"fmt"
	"log"
	"math"
	"time"

	// Embed the IANA timezone database. Demand windows are evaluated in a
	// region's LOCAL timezone, and a minimal container image (scratch/alpine)
	// ships no /usr/share/zoneinfo, so time.LoadLocation would fail at runtime
	// and every demand factor would silently collapse to 1.0. Importing
	// time/tzdata for its side effect makes the lookup independent of the
	// host's filesystem; the copy adds ~450 KB and is the standard, supported
	// way to make LoadLocation deterministic.
	_ "time/tzdata"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// FareEstimate is the priced result for one vehicle class. The first block is
// the historical shape (major currency units at this boundary — the rides
// DOUBLE columns and the JSON contract stay in dollars); the second block is
// the additive [fare] audit/variable surface.
type FareEstimate struct {
	BaseFare        float64
	DistanceRate    float64 // per-kilometer rate in major units
	TimeRate        float64 // per-minute rate in major units
	DistanceFare    float64 // computed distance leg (major units)
	TimeFare        float64 // computed time leg (major units)
	SurgeMultiplier float64 // the unified conditions multiplier (demand × supply)
	Total           float64

	// RegionID/Currency/RateID identify the card that priced this ride.
	RegionID string
	Currency string
	RateID   string
	// DemandMultiplier and SupplyMultiplier are the two factors whose product,
	// clamped, is SurgeMultiplier. They are exposed so a client can explain a
	// price without guessing.
	DemandMultiplier float64
	SupplyMultiplier float64
	// GradeUpliftPct is the climb uplift applied to the distance leg, as a
	// fraction (0.12 == +12%). It is 0 whenever the uplift did not apply:
	// no ascent, no elevation coverage, a zero-length leg, or a card with the
	// feature disabled. Never negative.
	GradeUpliftPct float64
	// AscentM is the RAW route ascent the uplift was derived from, carried so
	// the booking path can snapshot it (rides.grade_ascent_m) for
	// re-derivation. It is only meaningful when GradeUpliftPct > 0.
	AscentM float64
}

// FareConfigurationError is an operator-actionable pricing misconfiguration:
// a region has no fare_regions row, no active card for the class, or a currency
// that disagrees with FARE_CURRENCY. It is deliberately NOT a client error —
// handlers answer 500 INTERNAL — and it must never be papered over with another
// region's card.
type FareConfigurationError struct {
	msg   string
	cause error
}

func (e *FareConfigurationError) Error() string { return e.msg }
func (e *FareConfigurationError) Unwrap() error { return e.cause }

func newFareConfigurationError(cause error, format string, args ...interface{}) *FareConfigurationError {
	return &FareConfigurationError{msg: fmt.Sprintf(format, args...), cause: cause}
}

type FareService struct {
	geoRepo  repository.GeoRepository
	navSvc   *NavigationService
	fareRepo repository.FareRepository
	// currency is FARE_CURRENCY. The card's currency and the region's currency
	// must both equal it when set.
	currency string
	// maxMultiplier is FARE_MAX_MULTIPLIER, the upper clamp on
	// demand × supply.
	maxMultiplier float64
	// now is injectable for deterministic time-of-day tests.
	now func() time.Time
}

func NewFareService(geoRepo repository.GeoRepository, navSvc *NavigationService, fareRepo repository.FareRepository, cfg *config.Config) *FareService {
	s := &FareService{
		geoRepo:       geoRepo,
		navSvc:        navSvc,
		fareRepo:      fareRepo,
		currency:      config.DefaultFareCurrency,
		maxMultiplier: config.DefaultFareMaxMultiplier,
		now:           time.Now,
	}
	if cfg != nil {
		s.currency = cfg.FareCurrency
		s.maxMultiplier = cfg.FareMaxMultiplier
	}
	if s.maxMultiplier <= 0 {
		s.maxMultiplier = config.DefaultFareMaxMultiplier
	}
	return s
}

// CalculateEstimate prices one vehicle class for a trip.
//
// Resolution order for the card (api_plans [fare] §3): the route's resolved
// region when present; otherwise (an estimate or the legacy unscoped path) the
// registry's default_region = TRUE row. A region with no active card is a
// configuration error. A region is NEVER priced with another region's card.
//
// Money is integer cents throughout; exactly one half-up rounding is applied,
// to the final total. With an empty fare_demand_windows table the unified
// multiplier reduces to the historical driver-count heuristic, so the default
// deployment reproduces the pre-[fare] fare exactly.
func (s *FareService) CalculateEstimate(pickupLat, pickupLng, dropoffLat, dropoffLng float64, vehicleType string) (*FareEstimate, error) {
	route, err := s.navSvc.GetRoute(pickupLat, pickupLng, dropoffLat, dropoffLng)
	if err != nil {
		return nil, fmt.Errorf("failed to calculate route for fare: %w", err)
	}

	now := s.now()
	regionID, err := s.resolveRegionID(route.RegionID)
	if err != nil {
		return nil, err
	}

	fareRegion, err := s.fareRepo.GetFareRegion(regionID)
	if err != nil {
		return nil, newFareConfigurationError(err, "no pricing configured for region %q; run make seed-fares", regionID)
	}
	if s.currency != "" && fareRegion.Currency != s.currency {
		return nil, newFareConfigurationError(nil,
			"region %q prices in %s but FARE_CURRENCY is %s", regionID, fareRegion.Currency, s.currency)
	}

	rate, err := s.fareRepo.GetActiveFareRate(regionID, normalizeVehicleType(vehicleType), now)
	if err != nil {
		return nil, newFareConfigurationError(err,
			"no active fare rate for region %q vehicle %q", regionID, normalizeVehicleType(vehicleType))
	}
	if rate.Currency != fareRegion.Currency {
		return nil, newFareConfigurationError(nil,
			"rate currency %s does not match region %q currency %s", rate.Currency, regionID, fareRegion.Currency)
	}

	demand := s.demandMultiplier(fareRegion, now)
	supply := s.supplyMultiplier(pickupLat, pickupLng)
	conditions := clampMultiplier(demand*supply, s.maxMultiplier)

	dist := float64(route.DistanceMeters)
	dur := float64(route.DurationSecs)

	// One rounding, at the end (the plan's "one explicit half-up rounding").
	// Keeping the legs fractional in cents is what makes an empty demand table
	// reproduce the old `(base + distance + time) * surge` total exactly: the
	// arithmetic is identical up to the single final round.
	baseCents := float64(rate.BaseFareCents)
	// The climb uplift multiplies ONLY the distance leg (never base, time or
	// the conditions multiplier). It is read from the very route the service
	// already fetched above, so ascent and distance can never disagree.
	// Fails flat (exactly 0) when the route is not elevation-aware, the leg is
	// zero, or the card disables the feature — so the total then equals the
	// pre-upgrade result bit for bit.
	gradeUpliftPct := gradeUpliftPct(route.AscentM, route.DistanceMeters, route.ElevationAware,
		rate.GradeUpliftFactor, rate.GradeUpliftCap)
	distanceCents := (dist / 1000.0) * float64(rate.PerKmCents) * (1 + gradeUpliftPct)
	timeCents := (dur / 60.0) * float64(rate.PerMinCents)
	totalCents := math.Round((baseCents + distanceCents + timeCents) * conditions)

	return &FareEstimate{
		BaseFare:         float64(rate.BaseFareCents) / 100,
		DistanceRate:     float64(rate.PerKmCents) / 100,
		TimeRate:         float64(rate.PerMinCents) / 100,
		DistanceFare:     distanceCents / 100,
		TimeFare:         timeCents / 100,
		SurgeMultiplier:  conditions,
		Total:            totalCents / 100,
		RegionID:         rate.RegionID,
		Currency:         rate.Currency,
		RateID:           rate.ID,
		DemandMultiplier: demand,
		SupplyMultiplier: supply,
		GradeUpliftPct:   gradeUpliftPct,
		AscentM:          route.AscentM,
	}, nil
}

// RecomputeActualFare prices a COMPLETED ride from its stored actuals
// (api_plans/01_[fare]_actuals_recompute_on_completion.md). It is the stage-02
// entry point: the quote made at booking is not trusted for the final charge,
// the driven distance and elapsed time are.
//
// Determinism and idempotency are structural. The inputs are all persisted on
// the ride and never re-sampled from the world:
//
//   - the card is looked up by rides.fare_rate_id (GetFareRateByID), so a rate
//     change or a region-card correction between booking and completion cannot
//     move a finished fare;
//   - the climb uplift is re-derived from the booked RAW ascent
//     (rides.grade_ascent_m) and the booked card's factor/cap, using the
//     ACTUAL distance for the per-km denominator;
//   - the conditions multiplier is the BOOKED surge (rides.surge_multiplier),
//     reused verbatim. Demand windows and the live nearby-driver count are
//     deliberately NOT re-sampled: they are time-of-day and fleet dependent, so
//     sampling them at completion would make a retry charge a different amount
//     and break exactly-once. The rider's booked terms are fixed at booking;
//     only the distance/time legs are repriced. (Re-clamping is unnecessary —
//     the stored value was already clamped at booking — but a non-positive value
//     falls back to 1.0 rather than minting a zero fare.)
//
// It returns (nil, nil) when there is nothing defensible to recompute: a ride
// with no booked card id (legacy) or with either actual NULL (no usable trace /
// no timestamp pair). The caller then charges the booked quote unchanged,
// exactly the migration-021 fallback contract. A card-lookup failure is a real
// error and is returned so the caller can log it and fall back rather than
// fabricate.
//
// The final charge is UNCAPPED in both directions (product decision,
// 2026-10-06): an actual above or below the quote is charged as-is, never
// clamped to a tolerance.
func (s *FareService) RecomputeActualFare(ride *model.Ride) (*FareEstimate, error) {
	if ride == nil || ride.FareRateID == nil || *ride.FareRateID == "" {
		return nil, nil
	}
	if ride.ActualDistanceM == nil || ride.ActualDurationS == nil {
		return nil, nil
	}

	rate, err := s.fareRepo.GetFareRateByID(*ride.FareRateID)
	if err != nil {
		return nil, fmt.Errorf("load booked fare card %q: %w", *ride.FareRateID, err)
	}

	// The booked conditions multiplier is reused verbatim (see doc). A stored
	// value that is missing or nonsensical (0) would mint a zero fare, so it
	// falls back to the tariff floor instead.
	conditions := ride.SurgeMultiplier
	if conditions <= 0 {
		conditions = 1.0
	}

	ascent := 0.0
	elevationAware := false
	if ride.GradeAscentM != nil {
		ascent = *ride.GradeAscentM
		elevationAware = true
	}

	dist := *ride.ActualDistanceM
	dur := float64(*ride.ActualDurationS)

	// One rounding, at the end, mirroring CalculateEstimate. GradeUpliftPct is
	// recomputed on the ACTUAL distance, so a shorter/longer drive changes the
	// per-km climb exposure exactly as the booking formula would have.
	gradeUplift := gradeUpliftPct(ascent, int(math.Round(dist)), elevationAware,
		rate.GradeUpliftFactor, rate.GradeUpliftCap)
	baseCents := float64(rate.BaseFareCents)
	distanceCents := (dist / 1000.0) * float64(rate.PerKmCents) * (1 + gradeUplift)
	timeCents := (dur / 60.0) * float64(rate.PerMinCents)
	totalCents := math.Round((baseCents + distanceCents + timeCents) * conditions)

	return &FareEstimate{
		BaseFare:        baseCents / 100,
		DistanceRate:    float64(rate.PerKmCents) / 100,
		TimeRate:        float64(rate.PerMinCents) / 100,
		DistanceFare:    distanceCents / 100,
		TimeFare:        timeCents / 100,
		SurgeMultiplier: conditions,
		Total:           totalCents / 100,
		RegionID:        rate.RegionID,
		Currency:        rate.Currency,
		RateID:          rate.ID,
		GradeUpliftPct:  gradeUplift,
		AscentM:         ascent,
	}, nil
}

// gradeUpliftPct computes the capped climb uplift FRACTION for one leg
// (api_plans/[fare]_grade_fuel_cost.md):
//
//	ascent_per_km = ascent_m / max(km, epsilon)
//	uplift        = min(ascent_per_km * factor, cap)
//
// It fails FLAT — exactly 0 — whenever the uplift must not apply: the route is
// not elevation-aware (missing/partial coverage for the region), the card
// disables the feature (factor or cap is 0, the migration-020 default), the leg
// has no length, or the route did not climb. A descent never credits: a
// non-positive ascent yields 0, and the result is clamped to [0, cap] so a
// pathological ascent can never produce an absurd or negative fare. The
// epsilon only guards the division; a zero/tiny leg is already failed flat
// above, so it can never surface.
func gradeUpliftPct(ascentM float64, distanceMeters int, elevationAware bool, factor, cap float64) float64 {
	if !elevationAware || distanceMeters <= 0 || factor <= 0 || cap <= 0 || ascentM <= 0 {
		return 0
	}
	km := float64(distanceMeters) / 1000.0
	ascentPerKm := ascentM / math.Max(km, gradeUpliftEpsilonKM)
	uplift := ascentPerKm * factor
	if uplift > cap {
		return cap
	}
	if uplift < 0 {
		return 0
	}
	return uplift
}

// gradeUpliftEpsilonKM is the division guard in gradeUpliftPct. It is
// deliberately far below any real leg (a micrometre); a zero-length leg is
// already failed flat before this is reached.
const gradeUpliftEpsilonKM = 1e-9

// resolveRegionID is the documented fallback order: a resolved region wins;
// an empty one (estimate/legacy) falls back to the registry's
// default_region = TRUE row. There is deliberately no cross-region fallback —
// a region the route resolved to is used as-is even if it cannot price.
func (s *FareService) resolveRegionID(regionID string) (string, error) {
	if regionID != "" {
		return regionID, nil
	}
	def, err := s.fareRepo.DefaultRegionID()
	if err != nil {
		return "", newFareConfigurationError(err, "no default region configured; run make seed-fares")
	}
	return def, nil
}

// demandMultiplier evaluates the region's demand windows in its LOCAL time.
// No windows, no region timezone, an unknown timezone, or a repository error
// all yield 1.0: the demand factor is never guessed and never invents an
// offset.
func (s *FareService) demandMultiplier(fareRegion *model.FareRegion, at time.Time) float64 {
	windows, err := s.fareRepo.ListDemandWindows(fareRegion.RegionID)
	if err != nil {
		log.Printf("[fare] failed to load demand windows for region %q, using 1.0: %v", fareRegion.RegionID, err)
		return 1.0
	}
	loc := loadRegionLocation(fareRegion.Timezone)
	if loc == nil {
		return 1.0
	}
	return demandFactor(windows, loc, at)
}

// supplyMultiplier is the historical nearby-driver heuristic. A repository
// error stays a silent 1.0 (the pre-[fare] behavior): the driver count is
// noisy and must never fail a priced request.
func (s *FareService) supplyMultiplier(lat, lng float64) float64 {
	drivers, err := s.geoRepo.CountNearbyDrivers(lat, lng, 2000)
	if err != nil {
		return 1.0
	}
	if drivers == 0 {
		return 2.0
	}
	if drivers < 5 {
		return 1.5
	}
	return 1.0
}

// loadRegionLocation resolves the IANA timezone, or nil when it is empty or
// unknown — the "cannot use demand windows" state.
func loadRegionLocation(timezone string) *time.Location {
	if timezone == "" {
		return nil
	}
	loc, err := time.LoadLocation(timezone)
	if err != nil {
		log.Printf("[fare] unknown timezone %q, demand windows disabled: %v", timezone, err)
		return nil
	}
	return loc
}

// demandFactor returns the highest multiplier among the windows that match the
// local wall-clock instant `at`, or 1.0 when none do. DayMask bit 0 is Sunday
// (time.Weekday's Sunday == 0). A window is half-open [start, end) and wraps
// past midnight when start > end.
func demandFactor(windows []model.FareDemandWindow, loc *time.Location, at time.Time) float64 {
	if loc == nil || len(windows) == 0 {
		return 1.0
	}
	local := at.In(loc)
	weekday := 1 << uint(local.Weekday())
	minute := local.Hour()*60 + local.Minute()

	factor := 1.0
	for _, w := range windows {
		if w.DayMask&weekday == 0 {
			continue
		}
		if minuteInWindow(minute, w.StartMinute, w.EndMinute) && w.Multiplier > factor {
			factor = w.Multiplier
		}
	}
	return factor
}

// minuteInWindow reports whether minute is inside [start, end). A zero-length
// window matches nothing; a start > end window wraps past local midnight.
func minuteInWindow(minute, start, end int) bool {
	if start == end {
		return false
	}
	if start < end {
		return minute >= start && minute < end
	}
	return minute >= start || minute < end
}

// clampMultiplier floors the unified multiplier at 1.0 (pricing never
// discounts below the tariff) and caps it at max (the rider never sees an
// uncapped multiplier).
func clampMultiplier(v, max float64) float64 {
	if v < 1.0 {
		return 1.0
	}
	if max > 0 && v > max {
		return max
	}
	return v
}

// normalizeVehicleType closes the enum: an unknown type is priced as sedan. A
// MISSING sedan row is still a configuration error (never a priced 0).
func normalizeVehicleType(vehicleType string) string {
	switch vehicleType {
	case "suv", "luxury":
		return vehicleType
	default:
		return "sedan"
	}
}
