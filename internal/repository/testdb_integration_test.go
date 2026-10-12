//go:build integration

package repository

import (
	"testing"

	"github.com/jmoiron/sqlx"
)

// This file is the single source of truth for the TEMP-table DDL the repository
// integration suites use to shadow the real schema. Before it, every
// *_integration_test.go hand-rolled its own CREATE TEMP TABLE, so a migration
// change could leave a fixture silently stale and the same table was declared
// with different column subsets in different files (tests/AUDIT_REPORT.md §5.4;
// api_plans/STATUS.md → Test-audit follow-ups). connectPG/mustExec live in
// pgrouting_repo_integration_test.go; the DDL below builds on them.
//
// Conventions:
//   - Each helper only CREATEs a TEMP table on the caller's handle. The caller
//     still owns SetMaxOpenConns(1) and the t.Cleanup DROP, because the drop has
//     to be registered before the connection is closed.
//   - Every helper accepts testing.TB so the routing benchmark (*testing.B) can
//     reuse the road-network pair.
//   - Where a test genuinely needs a NARROWER row than the migration's full
//     table, the shape is an explicit ridesSchema argument — never a silently
//     relaxed superset.

// ridesSchema selects the canonical TEMP `rides` shape a suite needs.
type ridesSchema int

const (
	// ridesFull mirrors migrations 005 + 019–023 and carries every column
	// model.Ride maps, so a `SELECT * ... INTO model.Ride` round-trips. Used by
	// the ride_stops and fare_snapshot suites.
	ridesFull ridesSchema = iota
	// ridesFareQuote is the money + quoted_* subset migration 022's guarded
	// UPDATE reads and writes. It is explicit because that test inserts a bare
	// `(id, money…)` row that the full schema's NOT NULL rider/pickup/… columns
	// would reject — the narrower shape is load-bearing, not an oversight.
	ridesFareQuote
	// ridesActuals is the migration-021 actuals subset (id + actual_duration_s +
	// actual_distance_m + updated_at); same reason as ridesFareQuote.
	ridesActuals
)

// createRidesTable creates a TEMP `rides` in one of the canonical shapes above.
func createRidesTable(tb testing.TB, db *sqlx.DB, schema ridesSchema) {
	tb.Helper()
	var ddl string
	switch schema {
	case ridesFull:
		ddl = `CREATE TEMP TABLE rides (
			id                      UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
			rider_id                UUID          NOT NULL,
			driver_id               UUID,
			status                  TEXT          NOT NULL DEFAULT 'pending',
			pickup_lat              DOUBLE PRECISION NOT NULL,
			pickup_lng              DOUBLE PRECISION NOT NULL,
			dropoff_lat             DOUBLE PRECISION NOT NULL,
			dropoff_lng             DOUBLE PRECISION NOT NULL,
			pickup_address          TEXT          NOT NULL DEFAULT '',
			dropoff_address         TEXT          NOT NULL DEFAULT '',
			vehicle_type            TEXT          NOT NULL DEFAULT 'sedan',
			cancellation_fee        DOUBLE PRECISION NOT NULL DEFAULT 0,
			idempotency_key         TEXT          NOT NULL DEFAULT '',
			base_fare               DOUBLE PRECISION NOT NULL DEFAULT 0,
			distance_fare           DOUBLE PRECISION NOT NULL DEFAULT 0,
			time_fare               DOUBLE PRECISION NOT NULL DEFAULT 0,
			surge_multiplier        DOUBLE PRECISION NOT NULL DEFAULT 1.0,
			total_fare              DOUBLE PRECISION NOT NULL DEFAULT 0,
			fare_region_id          TEXT,
			fare_rate_id            UUID,
			fare_currency           TEXT,
			grade_uplift_pct        NUMERIC(6,4),
			grade_ascent_m          DOUBLE PRECISION,
			actual_duration_s       INTEGER,
			actual_distance_m       DOUBLE PRECISION,
			quoted_base_fare        DOUBLE PRECISION,
			quoted_distance_fare    DOUBLE PRECISION,
			quoted_time_fare        DOUBLE PRECISION,
			quoted_surge_multiplier DOUBLE PRECISION,
			quoted_total_fare       DOUBLE PRECISION,
			quoted_grade_uplift_pct NUMERIC(6,4),
			requested_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
			accepted_at             TIMESTAMPTZ,
			driver_arrived_at       TIMESTAMPTZ,
			started_at              TIMESTAMPTZ,
			completed_at            TIMESTAMPTZ,
			cancelled_at            TIMESTAMPTZ,
			created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
			updated_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW()
		)`
	case ridesFareQuote:
		ddl = `CREATE TEMP TABLE rides (
			id                      UUID PRIMARY KEY,
			base_fare               DOUBLE PRECISION NOT NULL DEFAULT 0,
			distance_fare           DOUBLE PRECISION NOT NULL DEFAULT 0,
			time_fare               DOUBLE PRECISION NOT NULL DEFAULT 0,
			surge_multiplier        DOUBLE PRECISION NOT NULL DEFAULT 1.0,
			total_fare              DOUBLE PRECISION NOT NULL DEFAULT 0,
			grade_uplift_pct        NUMERIC(6,4),
			quoted_base_fare        DOUBLE PRECISION,
			quoted_distance_fare    DOUBLE PRECISION,
			quoted_time_fare        DOUBLE PRECISION,
			quoted_surge_multiplier DOUBLE PRECISION,
			quoted_total_fare       DOUBLE PRECISION,
			quoted_grade_uplift_pct NUMERIC(6,4),
			updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`
	case ridesActuals:
		ddl = `CREATE TEMP TABLE rides (
			id                UUID PRIMARY KEY,
			actual_duration_s INTEGER,
			actual_distance_m DOUBLE PRECISION,
			updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`
	default:
		tb.Fatalf("createRidesTable: unknown ridesSchema %d", schema)
	}
	mustExec(tb, db, ddl)
}

// createRideStopsTable creates the TEMP `ride_stops` with migration 016's real
// CHECK and UNIQUE constraints reproduced verbatim — the part a mock cannot
// prove. It carries no FK because the fixture rides rows may be inserted with a
// bare id in some suites; the repository never relies on the cascade.
func createRideStopsTable(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE TEMP TABLE ride_stops (
		id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
		ride_id    UUID        NOT NULL,
		sequence   INTEGER     NOT NULL CHECK (sequence >= 1),
		kind       TEXT        NOT NULL DEFAULT 'stop' CHECK (kind IN ('stop','destination')),
		lat        DOUBLE PRECISION NOT NULL,
		lng        DOUBLE PRECISION NOT NULL,
		address    TEXT        NOT NULL DEFAULT '',
		created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		UNIQUE (ride_id, sequence)
	)`)
}

// createRideTrackPointsTable creates the TEMP `ride_track_points` (migration
// 021). It references the TEMP `rides` (created first by the caller) so the
// ON DELETE CASCADE the migration declares is exercised.
func createRideTrackPointsTable(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE TEMP TABLE ride_track_points (
		id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
		ride_id     UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
		lat         DOUBLE PRECISION NOT NULL,
		lng         DOUBLE PRECISION NOT NULL,
		recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)
}

// createRoutingRegionsTable creates the TEMP `routing_regions` (migration 013).
// level/name/bbox get defaults so the fare suites (which insert only
// region_id + the default flag) and the region/datasource suites (which insert
// the full registry row) share ONE declaration. parent_region and datasource
// stay NULL-able by design, so the COALESCE mapping is exercised.
func createRoutingRegionsTable(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE TEMP TABLE routing_regions (
		region_id      TEXT PRIMARY KEY,
		level          TEXT NOT NULL DEFAULT 'city',
		name           TEXT NOT NULL DEFAULT '',
		parent_region  TEXT,
		bbox_lon_min   DOUBLE PRECISION NOT NULL DEFAULT 0,
		bbox_lat_min   DOUBLE PRECISION NOT NULL DEFAULT 0,
		bbox_lon_max   DOUBLE PRECISION NOT NULL DEFAULT 0,
		bbox_lat_max   DOUBLE PRECISION NOT NULL DEFAULT 0,
		default_region BOOLEAN NOT NULL DEFAULT FALSE,
		datasource     TEXT
	)`)
}

// createFareRegionsTable creates the TEMP `fare_regions` (migration 019).
// Deliberately no FK to routing_regions: the fare suites insert region rows in
// an order that would violate it and no assertion relies on it.
func createFareRegionsTable(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE TEMP TABLE fare_regions (
		region_id  TEXT PRIMARY KEY,
		currency   TEXT NOT NULL DEFAULT 'USD',
		timezone   TEXT NOT NULL,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
}

// createFareRatesTable creates the TEMP `fare_rates` (migrations 019/020). Like
// createFareRegionsTable it omits the FK so both fare suites can share it.
func createFareRatesTable(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE TEMP TABLE fare_rates (
		id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id           TEXT NOT NULL,
		vehicle_type        TEXT NOT NULL,
		currency            TEXT NOT NULL,
		base_fare_cents     INTEGER NOT NULL,
		per_km_cents        INTEGER NOT NULL,
		per_min_cents       INTEGER NOT NULL,
		grade_uplift_factor NUMERIC(10,6) NOT NULL DEFAULT 0,
		grade_uplift_cap    NUMERIC(6,4)  NOT NULL DEFAULT 0,
		effective_from      TIMESTAMPTZ NOT NULL DEFAULT now(),
		effective_to        TIMESTAMPTZ,
		created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
}

// createFareRatesActiveIndex recreates migration 019's partial unique index, so
// the "one active card per (region, vehicle_type)" rule is tested against a real
// constraint rather than only through the repository.
func createFareRatesActiveIndex(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE UNIQUE INDEX uq_fare_rates_active
		ON fare_rates(region_id, vehicle_type) WHERE effective_to IS NULL`)
}

// createFareDemandWindowsTable creates the TEMP `fare_demand_windows`
// (migration 019).
func createFareDemandWindowsTable(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, `CREATE TEMP TABLE fare_demand_windows (
		id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
		region_id    TEXT NOT NULL,
		name         TEXT NOT NULL,
		day_mask     SMALLINT NOT NULL DEFAULT 127,
		start_minute INTEGER NOT NULL,
		end_minute   INTEGER NOT NULL,
		multiplier   NUMERIC(4,2) NOT NULL DEFAULT 1.0,
		created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
}

// createSingleRegionRoadTables creates the id-PK (no region_id)
// road_network_vertices_pgr / road_network_edges_pgr pair — the pre-013
// single-extract shape that pgr_dijkstra's edges_sql and the native graph build
// resolve to. The GIST index on the vertex geometry is what the snap/KNN
// queries need. The region-scoped composite-PK shape lives in
// regions_integration_test.go's createRegionTables.
func createSingleRegionRoadTables(tb testing.TB, db *sqlx.DB) {
	mustExec(tb, db, "CREATE TEMP TABLE road_network_vertices_pgr ("+
		"id BIGINT PRIMARY KEY, the_geom GEOMETRY(Point,4326), "+
		"lat DOUBLE PRECISION NOT NULL, lng DOUBLE PRECISION NOT NULL, "+
		"elevation_m DOUBLE PRECISION, elevation_source TEXT)")
	mustExec(tb, db, "CREATE TEMP TABLE road_network_edges_pgr ("+
		"id BIGINT PRIMARY KEY, source BIGINT, target BIGINT, cost DOUBLE PRECISION)")
	mustExec(tb, db, "CREATE INDEX ON road_network_vertices_pgr USING GIST (the_geom)")
}
