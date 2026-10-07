//go:build integration

package repository

import (
	"errors"
	"testing"
	"time"
)

// TestFareRepoIntegration exercises the real SQL of migration 019 against a live
// DB: active-row selection, future/expired exclusion, per-region independence,
// the default-region flag and demand windows. The fixtures are TEMP tables on a
// single-connection handle (the trick the other integration tests here use), so
// the real fare tables are never touched.
func TestFareRepoIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_demand_windows") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_rates") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS fare_regions") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS routing_regions") })

	mustExec(t, db, `CREATE TEMP TABLE fare_regions (
		region_id  TEXT PRIMARY KEY,
		currency   TEXT NOT NULL DEFAULT 'USD',
		timezone   TEXT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	mustExec(t, db, `CREATE TEMP TABLE fare_rates (
		id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id       TEXT NOT NULL,
		vehicle_type    TEXT NOT NULL,
		currency        TEXT NOT NULL,
		base_fare_cents INTEGER NOT NULL,
		per_km_cents    INTEGER NOT NULL,
		per_min_cents   INTEGER NOT NULL,
		grade_uplift_factor NUMERIC(10,6) NOT NULL DEFAULT 0,
		grade_uplift_cap    NUMERIC(6,4)  NOT NULL DEFAULT 0,
		effective_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
		effective_to    TIMESTAMPTZ,
		created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	mustExec(t, db, `CREATE UNIQUE INDEX uq_fare_rates_active
		ON fare_rates(region_id, vehicle_type) WHERE effective_to IS NULL`)
	mustExec(t, db, `CREATE TEMP TABLE fare_demand_windows (
		id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id    TEXT NOT NULL,
		name         TEXT NOT NULL,
		day_mask     SMALLINT NOT NULL DEFAULT 127,
		start_minute INTEGER NOT NULL,
		end_minute   INTEGER NOT NULL,
		multiplier   NUMERIC(4,2) NOT NULL DEFAULT 1.0,
		created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	mustExec(t, db, `CREATE TEMP TABLE routing_regions (
		region_id      TEXT PRIMARY KEY,
		default_region BOOLEAN NOT NULL DEFAULT FALSE
	)`)

	mustExec(t, db, `INSERT INTO fare_regions (region_id, currency, timezone) VALUES
		('cr-sj', 'USD', 'America/Costa_Rica'),
		('cr-lc', 'USD', 'America/Costa_Rica'),
		('cr-future', 'USD', 'America/Costa_Rica'),
		('cr-expired', 'USD', 'America/Costa_Rica')`)
	mustExec(t, db, `INSERT INTO routing_regions (region_id, default_region) VALUES
		('cr', FALSE), ('cr-sj', TRUE), ('cr-lc', FALSE)`)
	// cr-sj: an expired card, a future card, and the one active NOW.
	mustExec(t, db, `INSERT INTO fare_rates
		(region_id, vehicle_type, currency, base_fare_cents, per_km_cents, per_min_cents, effective_from, effective_to)
		VALUES
		('cr-sj', 'sedan', 'USD', 400, 100, 40, now() - interval '10 days', now() - interval '5 days'),
		('cr-sj', 'sedan', 'USD', 600, 200, 60, now() + interval '1 day',  now() + interval '30 days'),
		('cr-sj', 'sedan', 'USD', 500, 150, 50, now() - interval '5 days',  NULL),
		('cr-lc', 'sedan', 'USD', 900, 250, 90, now() - interval '1 day',   NULL),
		('cr-future', 'sedan', 'USD', 111, 11, 11, now() + interval '1 day',  NULL),
		('cr-expired', 'sedan', 'USD', 222, 22, 22, now() - interval '10 days', now() - interval '5 days')`)
	mustExec(t, db, `INSERT INTO fare_demand_windows
		(region_id, name, day_mask, start_minute, end_minute, multiplier)
		VALUES ('cr-sj', 'am_peak', 2, 420, 540, 1.4)`)
	// A card with the migration-020 uplift knobs set, so the SELECT is proven to
	// read them (cr-sj stays at the 0/off column default).
	mustExec(t, db, `UPDATE fare_rates SET grade_uplift_factor = 0.002, grade_uplift_cap = 0.2
		WHERE region_id='cr-lc' AND vehicle_type='sedan'`)

	repo := NewFareRepo(db)
	now := time.Now()

	t.Run("active row is picked and future/expired rows are ignored", func(t *testing.T) {
		rate, err := repo.GetActiveFareRate("cr-sj", "sedan", now)
		if err != nil {
			t.Fatalf("GetActiveFareRate: %v", err)
		}
		if rate.BaseFareCents != 500 || rate.PerKmCents != 150 || rate.PerMinCents != 50 {
			t.Errorf("active card = %d/%d/%d, want the now-active 500/150/50",
				rate.BaseFareCents, rate.PerKmCents, rate.PerMinCents)
		}
		if rate.GradeUpliftFactor != 0 || rate.GradeUpliftCap != 0 {
			t.Errorf("uplift knobs = %v/%v, want the 0/off column default",
				rate.GradeUpliftFactor, rate.GradeUpliftCap)
		}
	})

	t.Run("a historical instant resolves the then-active card", func(t *testing.T) {
		rate, err := repo.GetActiveFareRate("cr-sj", "sedan", now.AddDate(0, 0, -7))
		if err != nil {
			t.Fatalf("GetActiveFareRate(past): %v", err)
		}
		if rate.BaseFareCents != 400 {
			t.Errorf("past card base = %d, want the expired 400", rate.BaseFareCents)
		}
	})

	t.Run("a region whose only card is in the future is not selected", func(t *testing.T) {
		// cr-future has a single card starting tomorrow: at `now` there is no
		// effective card, so the query must not reach forward to it.
		if _, err := repo.GetActiveFareRate("cr-future", "sedan", now); !errors.Is(err, ErrNotFound) {
			t.Fatalf("error = %v, want ErrNotFound: a future effective_from must not price now", err)
		}
	})

	t.Run("a region whose only card has closed is not selected", func(t *testing.T) {
		// cr-expired's single card closed five days ago: at `now` it is gone.
		if _, err := repo.GetActiveFareRate("cr-expired", "sedan", now); !errors.Is(err, ErrNotFound) {
			t.Fatalf("error = %v, want ErrNotFound: an effective_to in the past must not price now", err)
		}
	})

	t.Run("a closed card loses to the active one at the same instant", func(t *testing.T) {
		// cr-sj holds BOTH the closed 400 card and the active 500 card, so a
		// query at `now` proves the closed row is excluded by the window rather
		// than by being the only row.
		rate, err := repo.GetActiveFareRate("cr-sj", "sedan", now)
		if err != nil {
			t.Fatalf("GetActiveFareRate: %v", err)
		}
		if rate.BaseFareCents != 500 {
			t.Errorf("base = %d, want 500 (the active card, not the closed 400)", rate.BaseFareCents)
		}
	})

	t.Run("two regions price independently", func(t *testing.T) {
		sj, err := repo.GetActiveFareRate("cr-sj", "sedan", now)
		if err != nil {
			t.Fatalf("cr-sj: %v", err)
		}
		lc, err := repo.GetActiveFareRate("cr-lc", "sedan", now)
		if err != nil {
			t.Fatalf("cr-lc: %v", err)
		}
		if sj.BaseFareCents == lc.BaseFareCents {
			t.Errorf("both regions returned base %d; a region must never borrow another's card", sj.BaseFareCents)
		}
		if lc.BaseFareCents != 900 {
			t.Errorf("cr-lc base = %d, want 900", lc.BaseFareCents)
		}
		if lc.GradeUpliftFactor != 0.002 || lc.GradeUpliftCap != 0.2 {
			t.Errorf("cr-lc uplift knobs = %v/%v, want 0.002/0.2 (the SELECT dropped them)",
				lc.GradeUpliftFactor, lc.GradeUpliftCap)
		}
	})

	t.Run("a class with no card is not found", func(t *testing.T) {
		if _, err := repo.GetActiveFareRate("cr-sj", "suv", now); !errors.Is(err, ErrNotFound) {
			t.Fatalf("error = %v, want ErrNotFound", err)
		}
	})

	t.Run("default region is the registry flag", func(t *testing.T) {
		id, err := repo.DefaultRegionID()
		if err != nil {
			t.Fatalf("DefaultRegionID: %v", err)
		}
		if id != "cr-sj" {
			t.Errorf("default region = %q, want cr-sj", id)
		}
	})

	t.Run("fare region attributes round-trip", func(t *testing.T) {
		r, err := repo.GetFareRegion("cr-sj")
		if err != nil {
			t.Fatalf("GetFareRegion: %v", err)
		}
		if r.Currency != "USD" || r.Timezone != "America/Costa_Rica" {
			t.Errorf("region = %+v, want USD / America/Costa_Rica", r)
		}
		if _, err := repo.GetFareRegion("missing"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("missing region error = %v, want ErrNotFound", err)
		}
	})

	t.Run("demand windows are returned and empty means empty not nil", func(t *testing.T) {
		windows, err := repo.ListDemandWindows("cr-sj")
		if err != nil {
			t.Fatalf("ListDemandWindows: %v", err)
		}
		if len(windows) != 1 || windows[0].Name != "am_peak" || windows[0].Multiplier != 1.4 {
			t.Fatalf("windows = %+v, want the single am_peak 1.4", windows)
		}
		if windows[0].DayMask != 2 {
			t.Errorf("day_mask = %d, want 2 (Monday)", windows[0].DayMask)
		}
		empty, err := repo.ListDemandWindows("cr-lc")
		if err != nil {
			t.Fatalf("ListDemandWindows(cr-lc): %v", err)
		}
		if empty == nil || len(empty) != 0 {
			t.Errorf("cr-lc windows = %+v, want an empty non-nil slice", empty)
		}
	})

	t.Run("the partial unique index rejects a second active row", func(t *testing.T) {
		// Last on purpose: the fixture's uq_fare_rates_active index is the
		// migration 019 index reproduced verbatim, and it must reject a second
		// effective_to IS NULL row per (region, vehicle_type).
		_, err := db.Exec(`INSERT INTO fare_rates
			(region_id, vehicle_type, currency, base_fare_cents, per_km_cents, per_min_cents, effective_from, effective_to)
			VALUES ('cr-sj', 'sedan', 'USD', 700, 300, 70, now(), NULL)`)
		if err == nil {
			t.Fatal("a second active card was accepted; the partial unique index did not fire")
		}
	})
}
