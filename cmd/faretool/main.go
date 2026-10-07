// Command faretool bootstraps region pricing (api_plans/STATUS.md [fare]). It
// is invoked per region and requires an
// EXPLICIT IANA timezone: demand windows are a local-time concept and the tool
// refuses to guess one.
//
// Usage:
//
//	go run ./cmd/faretool --region cr-sj --timezone America/Costa_Rica
//
// It is idempotent: a re-run over an unchanged card does nothing, and a
// changed card is versioned (the old row is closed, a new active row is
// inserted) rather than rewritten in place.
package main

import (
	"flag"
	"fmt"
	"log"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/database"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

// run holds the work so every early return unwinds through run's defers and
// the database always closes.
func run() error {
	region := flag.String("region", "", "routing_regions.region_id to price (required)")
	timezone := flag.String("timezone", "", "explicit IANA timezone, e.g. America/Costa_Rica (required)")
	currency := flag.String("currency", "", "ISO-4217 currency; defaults to FARE_CURRENCY / USD")
	flag.Parse()

	if *region == "" || *timezone == "" {
		return fmt.Errorf("faretool: both --region and --timezone are required")
	}

	cfg := config.Load()
	if *currency == "" {
		*currency = cfg.FareCurrency
	}

	db, err := database.Connect(cfg)
	if err != nil {
		return fmt.Errorf("faretool: connect: %w", err)
	}
	defer func() { _ = db.Close() }()

	if err := database.SeedFaresRegion(db, *region, *currency, *timezone); err != nil {
		return fmt.Errorf("faretool: %w", err)
	}
	fmt.Printf("fare seed: region %s priced in %s (timezone %s)\n", *region, *currency, *timezone)
	return nil
}
