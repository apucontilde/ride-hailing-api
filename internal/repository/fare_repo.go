package repository

import (
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

// FareRepository is the LOCAL read side of the pricing engine (api_plans/
// STATUS.md [fare]). Every method reads the MAIN database: a
// region's price, timezone and default flag resolve locally even when that
// region's road network lives in another Postgres, so a down city datasource
// degrades to an estimate and never to a pricing outage.
type FareRepository interface {
	// GetFareRegion returns the pricing attributes of one region. A region
	// that has never been seeded is ErrNotFound.
	GetFareRegion(regionID string) (*model.FareRegion, error)
	// GetActiveFareRate returns the rate card effective at `at` — effective_from
	// <= at AND (effective_to IS NULL OR effective_to > at), newest first. A
	// region/class with no such row is ErrNotFound, which the service turns
	// into a configuration error (never a fallback to another region's card).
	GetActiveFareRate(regionID, vehicleType string, at time.Time) (*model.FareRate, error)
	// GetFareRateByID returns a card by its primary key, ignoring the
	// effective window. It is the completion recompute seam
	// (api_plans/01_[fare]_actuals_recompute_on_completion.md): a finished ride
	// prices against the card it BOOKED (rides.fare_rate_id), so a rate change
	// between booking and completion cannot retroactively reprice it. A card
	// row is immutable, so this is deterministic; a missing row is ErrNotFound.
	GetFareRateByID(rateID string) (*model.FareRate, error)
	// ListDemandWindows returns every demand window of a region; an empty table
	// or region yields an empty slice, never nil.
	ListDemandWindows(regionID string) ([]model.FareDemandWindow, error)
	// DefaultRegionID returns the routing registry's default_region = TRUE row,
	// the fallback used when a ride has NO region at all (a straight-line
	// estimate, or the legacy unscoped path). It is NOT a cross-region price
	// fallback. No default row is ErrNotFound.
	DefaultRegionID() (string, error)
}

var _ FareRepository = (*FareRepo)(nil)

type FareRepo struct {
	db *sqlx.DB
}

func NewFareRepo(db *sqlx.DB) *FareRepo {
	return &FareRepo{db: db}
}

func (r *FareRepo) GetFareRegion(regionID string) (*model.FareRegion, error) {
	region := &model.FareRegion{}
	err := r.db.Get(region, `
		SELECT region_id, currency, timezone, created_at, updated_at
		FROM fare_regions WHERE region_id = $1`, regionID)
	if err != nil {
		return nil, wrapDB("load fare region", err)
	}
	return region, nil
}

func (r *FareRepo) GetActiveFareRate(regionID, vehicleType string, at time.Time) (*model.FareRate, error) {
	rate := &model.FareRate{}
	err := r.db.Get(rate, `
		SELECT id, region_id, vehicle_type, currency,
		       base_fare_cents, per_km_cents, per_min_cents,
		       grade_uplift_factor::float8 AS grade_uplift_factor,
		       grade_uplift_cap::float8 AS grade_uplift_cap,
		       effective_from, effective_to, created_at
		FROM fare_rates
		WHERE region_id = $1 AND vehicle_type = $2
		  AND effective_from <= $3
		  AND (effective_to IS NULL OR effective_to > $3)
		ORDER BY effective_from DESC
		LIMIT 1`, regionID, vehicleType, at)
	if err != nil {
		return nil, wrapDB("load active fare rate", err)
	}
	return rate, nil
}

// GetFareRateByID loads a rate card by primary key, with NO effective-window
// filter: the completion recompute prices a finished ride against the card it
// booked, even if that card was superseded or closed since. Card rows are
// immutable, so the result is deterministic.
func (r *FareRepo) GetFareRateByID(rateID string) (*model.FareRate, error) {
	rate := &model.FareRate{}
	err := r.db.Get(rate, `
		SELECT id, region_id, vehicle_type, currency,
		       base_fare_cents, per_km_cents, per_min_cents,
		       grade_uplift_factor::float8 AS grade_uplift_factor,
		       grade_uplift_cap::float8 AS grade_uplift_cap,
		       effective_from, effective_to, created_at
		FROM fare_rates
		WHERE id = $1`, rateID)
	if err != nil {
		return nil, wrapDB("load fare rate by id", err)
	}
	return rate, nil
}

func (r *FareRepo) ListDemandWindows(regionID string) ([]model.FareDemandWindow, error) {
	// Initialized, never nil, so callers can range over it.
	windows := []model.FareDemandWindow{}
	err := r.db.Select(&windows, `
		SELECT id, region_id, name, day_mask, start_minute, end_minute,
		       multiplier::float8 AS multiplier, created_at
		FROM fare_demand_windows
		WHERE region_id = $1
		ORDER BY start_minute`, regionID)
	if err != nil {
		return nil, wrapDB("load fare demand windows", err)
	}
	return windows, nil
}

func (r *FareRepo) DefaultRegionID() (string, error) {
	var regionID string
	err := r.db.Get(&regionID, `
		SELECT region_id FROM routing_regions
		WHERE default_region = TRUE
		ORDER BY region_id
		LIMIT 1`)
	if err != nil {
		return "", wrapDB("load default region", err)
	}
	return regionID, nil
}
