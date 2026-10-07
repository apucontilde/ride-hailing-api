package model

import "time"

// FareRegion is the pricing-owned extension of the region dimension
// (api_plans/STATUS.md [fare]). routing_regions knows where a
// region is and how to route on it; fare_regions knows what it costs and in
// which currency, plus the IANA timezone demand windows are evaluated in.
type FareRegion struct {
	RegionID string `db:"region_id"`
	// Currency is the region's ISO-4217 pricing currency. It must equal the
	// currency on the region's active rate card; a mismatch is a configuration
	// error, never a silent conversion.
	Currency string `db:"currency"`
	// Timezone is an IANA name (e.g. "America/Costa_Rica"). It is supplied
	// explicitly when the region is seeded and is never guessed. An empty or
	// unknown value disables demand windows for the region (factor 1.0) rather
	// than assuming an offset.
	Timezone  string    `db:"timezone"`
	CreatedAt time.Time `db:"created_at"`
	UpdatedAt time.Time `db:"updated_at"`
}

// FareRate is one version of a region's rate card for a vehicle class. All
// money is integer CENTS (the JSON/ride boundary stays major units). PerKmCents
// includes fuel (decision 4); the fuel derivation happens at authoring time.
//
// Exactly one row per (region, vehicle_type) has EffectiveTo == nil (the active
// card). A rate change appends a row and closes the predecessor; history is
// never mutated in place.
type FareRate struct {
	ID            string `db:"id"`
	RegionID      string `db:"region_id"`
	VehicleType   string `db:"vehicle_type"`
	Currency      string `db:"currency"`
	BaseFareCents int    `db:"base_fare_cents"`
	PerKmCents    int    `db:"per_km_cents"`
	PerMinCents   int    `db:"per_min_cents"`
	// GradeUpliftFactor and GradeUpliftCap are the per-(region, class) climb
	// uplift knobs (migration 020). Factor is the fraction added per
	// (metre climbed / km driven); Cap is the hard ceiling on that fraction.
	// Both DEFAULT 0 = uplift disabled for this card, which is honest and must
	// never crash.
	GradeUpliftFactor float64    `db:"grade_uplift_factor"`
	GradeUpliftCap    float64    `db:"grade_uplift_cap"`
	EffectiveFrom     time.Time  `db:"effective_from"`
	EffectiveTo       *time.Time `db:"effective_to"`
	CreatedAt         time.Time  `db:"created_at"`
}

// FareDemandWindow is one recurring time-of-day window in a region's LOCAL
// time. DayMask is a 7-bit mask with bit 0 = Sunday; StartMinute/EndMinute are
// minutes from local midnight and form a half-open range (a start > end window
// wraps past midnight). Multiplier is >= 1.0; the tariff is never discounted
// below itself.
type FareDemandWindow struct {
	ID          string    `db:"id"`
	RegionID    string    `db:"region_id"`
	Name        string    `db:"name"`
	DayMask     int       `db:"day_mask"`
	StartMinute int       `db:"start_minute"`
	EndMinute   int       `db:"end_minute"`
	Multiplier  float64   `db:"multiplier"`
	CreatedAt   time.Time `db:"created_at"`
}
