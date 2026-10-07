package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"time"

	// Same rationale as internal/service/fare.go: keep IANA timezone validation
	// working in a minimal image with no /usr/share/zoneinfo.
	_ "time/tzdata"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

// Per-km rate derivation (api_plans/STATUS.md [fare],
// decision 4: fuel is absorbed into the distance leg). Rather than hardcode
// 150/200/300 cents, the distance tariff is built from a documented
// consumption assumption so the fuel absorption is reproducible and editable:
//
//	fuel_cents_per_km = L_PER_100KM / 100 * FUEL_PRICE_USD_PER_L * 100
//	per_km_cents      = round(fuel_cents_per_km) + distance_margin_cents
//
// The margin is the non-fuel (commercial) part of the authored tariff. Both
// halves are explicit so an operator changing fuel price does not silently
// change the service premium. The shipped constants are chosen to reproduce
// the pre-[fare] hardcoded card EXACTLY (sedan 1.50, suv 2.00, luxury 3.00
// USD/km), so seeding a fresh region reads as "fuel + premium = the card the
// API served before this stage".
type fareSeedClass struct {
	vehicleType      string
	baseFareCents    int
	perMinCents      int
	consumptionL100K float64 // litres per 100 km
	marginCents      int     // non-fuel component of the per-km tariff
	massKg           float64 // curb mass used to derive the grade uplift factor
}

const fareSeedFuelPriceUSDPerL = 1.20

// Grade uplift derivation (api_plans/[fare]_grade_fuel_cost.md). The factor is
// the extra fuel cost of climbing ONE metre, expressed as a fraction of the
// fuel-inclusive per-km tariff; the cap bounds the rider's exposure so a
// pathological ascent can never price an absurd fare. Both are authored into
// the card, per (region, vehicle class), by SeedFaresRegion.
const (
	fareSeedDrivetrainEfficiency = 0.25 // tank-to-wheel
	fareSeedGasolineMJPerL       = 34.2 // lower heating value
	fareSeedGradeUpliftCap       = 0.15 // never more than +15% on the distance leg
)

var fareSeedClasses = []fareSeedClass{
	{vehicleType: "sedan", baseFareCents: 500, perMinCents: 50, consumptionL100K: 7.5, marginCents: 141, massKg: 1500},
	{vehicleType: "suv", baseFareCents: 800, perMinCents: 70, consumptionL100K: 10.0, marginCents: 188, massKg: 2100},
	{vehicleType: "luxury", baseFareCents: 1200, perMinCents: 100, consumptionL100K: 15.0, marginCents: 282, massKg: 1900},
}

// fuelInclusivePerKmCents is the documented derivation above.
func fuelInclusivePerKmCents(c fareSeedClass) int {
	fuelCents := c.consumptionL100K / 100.0 * fareSeedFuelPriceUSDPerL * 100.0
	return int(math.Round(fuelCents)) + c.marginCents
}

// gradeUpliftFactor derives the per-(metre climbed / km driven) uplift fraction
// from the extra potential energy a climb demands:
//
//	extra_cents_per_m = mass * g / (efficiency * fuel_energy) * fuel_price * 100
//	factor            = extra_cents_per_m / per_km_cents
//
// It is rounded to the card column's 6 decimals, so a re-seed over the same
// card is a no-op. A heavier class derives a larger factor (an SUV burns more
// per climb); a region that should price differently seeds its own factor.
func gradeUpliftFactor(c fareSeedClass) float64 {
	litresPerMeter := (c.massKg * 9.81) / (fareSeedDrivetrainEfficiency * fareSeedGasolineMJPerL * 1e6)
	centsPerMeter := litresPerMeter * fareSeedFuelPriceUSDPerL * 100
	perKmCents := float64(fuelInclusivePerKmCents(c))
	factor := centsPerMeter / perKmCents
	return math.Round(factor*1e6) / 1e6
}

// SeedFaresRegion inserts (or refreshes) a region's pricing row and one active
// card per vehicle class. It is IDEMPOTENT and append-only:
//
//   - fare_regions is upserted (currency/timezone refresh, no row churn);
//   - a card whose active row already matches the shipped values is left
//     untouched (a no-op re-run);
//   - a card whose active row DIFFERS is closed (effective_to = now) and a NEW
//     active version is inserted — history is never mutated in place.
//
// Demand windows are deliberately left untouched: the table stays empty
// (multiplier 1.0) unless windows are authored explicitly by an operator.
//
// timezone is required and validated as an IANA name — it is never guessed.
func SeedFaresRegion(db *sqlx.DB, regionID, currency, timezone string) error {
	if regionID == "" {
		return errors.New("fare seed: region is required")
	}
	if timezone == "" {
		return errors.New("fare seed: timezone is required (an explicit IANA name; never guessed)")
	}
	if _, err := time.LoadLocation(timezone); err != nil {
		return fmt.Errorf("fare seed: invalid timezone %q: %w", timezone, err)
	}
	if currency == "" {
		currency = config.DefaultFareCurrency
	}

	tx, err := db.BeginTxx(context.Background(), nil)
	if err != nil {
		return fmt.Errorf("fare seed: begin transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO fare_regions (region_id, currency, timezone, created_at, updated_at)
		VALUES ($1, $2, $3, now(), now())
		ON CONFLICT (region_id) DO UPDATE
		SET currency = EXCLUDED.currency, timezone = EXCLUDED.timezone, updated_at = now()`,
		regionID, currency, timezone); err != nil {
		return fmt.Errorf("fare seed: upsert fare_regions %q: %w", regionID, err)
	}

	for _, c := range fareSeedClasses {
		perKmCents := fuelInclusivePerKmCents(c)

		var (
			activeID       string
			base, km, min  int
			activeCurrency string
			activeFactor   float64
			activeCap      float64
		)
		err := tx.QueryRow(`
			SELECT id, base_fare_cents, per_km_cents, per_min_cents, currency,
			       grade_uplift_factor::float8, grade_uplift_cap::float8
			FROM fare_rates
			WHERE region_id = $1 AND vehicle_type = $2 AND effective_to IS NULL`,
			regionID, c.vehicleType).Scan(&activeID, &base, &km, &min, &activeCurrency,
			&activeFactor, &activeCap)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			if insErr := insertFareRate(tx, regionID, currency, c, perKmCents); insErr != nil {
				return insErr
			}
		case err != nil:
			return fmt.Errorf("fare seed: read active rate %q/%q: %w", regionID, c.vehicleType, err)
		default:
			if base == c.baseFareCents && km == perKmCents && min == c.perMinCents && activeCurrency == currency &&
				activeFactor == gradeUpliftFactor(c) && activeCap == fareSeedGradeUpliftCap {
				continue // idempotent: already at the shipped card
			}
			// A price change is a new effective-dated row, never an UPDATE.
			if _, err := tx.Exec(`UPDATE fare_rates SET effective_to = now() WHERE id = $1`, activeID); err != nil {
				return fmt.Errorf("fare seed: close rate %q/%q: %w", regionID, c.vehicleType, err)
			}
			if insErr := insertFareRate(tx, regionID, currency, c, perKmCents); insErr != nil {
				return insErr
			}
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("fare seed: commit: %w", err)
	}
	return nil
}

func insertFareRate(tx *sqlx.Tx, regionID, currency string, c fareSeedClass, perKmCents int) error {
	if _, err := tx.Exec(`
		INSERT INTO fare_rates
			(region_id, vehicle_type, currency, base_fare_cents, per_km_cents, per_min_cents,
			 grade_uplift_factor, grade_uplift_cap)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		regionID, c.vehicleType, currency, c.baseFareCents, perKmCents, c.perMinCents,
		gradeUpliftFactor(c), fareSeedGradeUpliftCap); err != nil {
		return fmt.Errorf("fare seed: insert rate %q/%q: %w", regionID, c.vehicleType, err)
	}
	return nil
}
