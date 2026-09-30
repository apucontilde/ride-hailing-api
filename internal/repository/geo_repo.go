package repository

import (
	"fmt"
	"log"
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

type GeoRepository interface {
	UpsertDriverPosition(driverID string, lat, lng, heading, speed float64, status string) error
	UpsertRiderPosition(riderID string, lat, lng float64) error
	FindNearbyDrivers(lat, lng float64, radiusM float64, limit int) ([]model.NearbyDriverResult, error)
	CountNearbyDrivers(lat, lng float64, radiusM float64) (int, error)
	GetDriverLocation(driverID string) (*model.NearbyDriverResult, error)
	MarkStaleDriversOffline() error
	// TouchDriverPresence refreshes an EXISTING position row's timestamp and
	// status. It never invents coordinates and never resurrects a stale fix:
	// with no row, or one older than DriverPresenceMaxAgeS, it reports
	// ErrNotFound. It is the liveness half of UpsertDriverPosition: dispatch
	// only considers drivers whose row is younger than DriverLivenessWindow,
	// and a stationary or just-online driver emits no GPS fix, so without this
	// they would silently age out of the search while the app still shows them
	// "online" (api_plans [dispatch]).
	TouchDriverPresence(driverID, status string) error
}

// DriverLivenessWindow is how old a driver_positions row may be and still be
// considered live by FindNearbyDrivers/CountNearbyDrivers. It is the liveness
// CONTRACT the driver app must satisfy: while a driver is online it has to
// refresh its presence at least this often (a location update, or the API's own
// refresh when their status is written as online, via TouchDriverPresence), or
// dispatch stops seeing them. 30s has been the window since the original query;
// it is exported because the dispatch offer path documents the contract against
// it (internal/service/dispatch_observability.go).
const DriverLivenessWindow = 30 * time.Second

// driverLivenessSeconds is DriverLivenessWindow as the float64 the SQL binds.
// It MUST stay .Seconds() and MUST NOT become a time.Duration.
//
// database/sql passes an unknown Go type through driver.DefaultParameterConverter,
// which turns a time.Duration into its raw nanosecond int64 — binding
// DriverLivenessWindow directly sends "30000000000". Postgres then reads that
// as 30,000,000,000 SECONDS and answers without error: verified on the dev DB,
// `NOW() - $1::interval` and `make_interval(secs => $1::double precision)` both
// land in 1076 AD, so no dead driver ever ages out and the sweep never fires.
// (Postgres renders the interval as 8333333:20:00 in HOURS:MIN:SEC, which is
// where an earlier "parsed as hours, ~9.5 years" reading came from — wrong on
// both counts.) The mock-backed unit suite cannot see SQL parameters at all;
// TestLivenessWindowBindsInPostgres (integration tag) is the regression test.
var driverLivenessSeconds = DriverLivenessWindow.Seconds()

var _ GeoRepository = (*GeoRepo)(nil)

type GeoRepo struct {
	db *sqlx.DB
}

func NewGeoRepo(db *sqlx.DB) *GeoRepo {
	return &GeoRepo{db: db}
}

func (r *GeoRepo) UpsertDriverPosition(driverID string, lat, lng, heading, speed float64, status string) error {
	_, err := r.db.Exec(`
		INSERT INTO driver_positions (driver_id, location, heading, speed, status, updated_at)
		VALUES (
			$1,
			ST_SetSRID(ST_MakePoint($2, $3), 4326)::GEOGRAPHY,
			$4, $5, $6, NOW()
		)
		ON CONFLICT (driver_id)
		DO UPDATE SET
			location   = ST_SetSRID(ST_MakePoint($2, $3), 4326)::GEOGRAPHY,
			heading    = $4,
			speed      = $5,
			status     = $6,
			updated_at = NOW()`,
		driverID, lng, lat, heading, speed, status)
	return wrapDB("upsert driver position", err)
}

func (r *GeoRepo) UpsertRiderPosition(riderID string, lat, lng float64) error {
	_, err := r.db.Exec(`
		INSERT INTO rider_positions (rider_id, location, updated_at)
		VALUES ($1, ST_SetSRID(ST_MakePoint($2, $3), 4326)::GEOGRAPHY, NOW())
		ON CONFLICT (rider_id)
		DO UPDATE SET
			location   = ST_SetSRID(ST_MakePoint($2, $3), 4326)::GEOGRAPHY,
			updated_at = NOW()`,
		riderID, lng, lat)
	return wrapDB("upsert rider position", err)
}

func (r *GeoRepo) FindNearbyDrivers(lat, lng float64, radiusM float64, limit int) ([]model.NearbyDriverResult, error) {
	var results []model.NearbyDriverResult
	query := `
		SELECT
			driver_id,
			ST_X(location::GEOMETRY) AS lng,
			ST_Y(location::GEOMETRY) AS lat,
			heading,
			speed,
			ST_Distance(location, ST_SetSRID(ST_MakePoint($1, $2), 4326)::GEOGRAPHY) AS distance_m
		FROM driver_positions
		WHERE status = 'online'
		  AND updated_at > NOW() - make_interval(secs => $3::double precision)
		  AND ST_DWithin(
				location,
				ST_SetSRID(ST_MakePoint($1, $2), 4326)::GEOGRAPHY,
				$4
			  )
		ORDER BY distance_m
		LIMIT $5`

	err := r.db.Select(&results, query, lng, lat, driverLivenessSeconds, radiusM, limit)
	if err != nil {
		return nil, wrapDB("find nearby drivers", err)
	}
	return results, nil
}

func (r *GeoRepo) GetDriverLocation(driverID string) (*model.NearbyDriverResult, error) {
	result := &model.NearbyDriverResult{}
	query := `
		SELECT
			driver_id,
			ST_X(location::GEOMETRY) AS lng,
			ST_Y(location::GEOMETRY) AS lat,
			heading, speed
		FROM driver_positions
		WHERE driver_id = $1`
	err := r.db.Get(result, query, driverID)
	if err != nil {
		return nil, wrapDB("load driver location", err)
	}
	return result, nil
}

func (r *GeoRepo) CountNearbyDrivers(lat, lng float64, radiusM float64) (int, error) {
	var count int
	query := `
		SELECT COUNT(*)
		FROM driver_positions
		WHERE status = 'online'
		  AND updated_at > NOW() - make_interval(secs => $3::double precision)
		  AND ST_DWithin(
				location,
				ST_SetSRID(ST_MakePoint($1, $2), 4326)::GEOGRAPHY,
				$4
			  )`
	err := r.db.Get(&count, query, lng, lat, driverLivenessSeconds, radiusM)
	if err != nil {
		return 0, wrapDB("count nearby drivers", err)
	}
	return count, nil
}

// MarkStaleDriversOffline reconciles the DISPATCH view: a row that has not been
// refreshed within DriverLivenessWindow is no longer dispatch-eligible, so it is
// marked offline in driver_positions rather than left claiming to be online.
//
// It writes driver_positions.status only. drivers.status — the profile record
// the driver API and app read — is deliberately left alone here, because only
// the driver's own status write may change it; a driver whose app died
// mid-shift therefore stays "online" in drivers until they next write. Nothing
// in this sweep makes a driver dispatchable (that is TouchDriverPresence) and
// nothing reports a position (GetDriverLocation selects no status column at
// all).
func (r *GeoRepo) MarkStaleDriversOffline() error {
	res, err := r.db.Exec(`
		UPDATE driver_positions SET status = 'offline'
		WHERE status = 'online'
		  AND updated_at < NOW() - make_interval(secs => $1::double precision)`,
		driverLivenessSeconds)
	if err != nil {
		return wrapDB("mark stale drivers offline", err)
	}
	swept, _ := res.RowsAffected()
	if swept > 0 {
		log.Printf("[dispatch] liveness sweep: %d driver(s) marked offline (no presence refresh in %s)", swept, DriverLivenessWindow)
	}
	return nil
}

// DriverPresenceMaxAgeS is the oldest a driver's stored fix may be and still be
// re-armed by TouchDriverPresence (seconds). A driver who opens the app 15 km
// from where they last were, and taps online BEFORE the first GPS fix, would
// otherwise re-arm the liveness window at their OLD coordinates — and
// FindNearbyDrivers would offer that stale position to a rider, who then waits
// for a driver who is somewhere else entirely. Five minutes is generous for a
// fix that arrived seconds ago and short enough to keep a driver's last
// remembered position near where they actually are.
//
// Zero rows from the age-gated UPDATE is reported as ErrNotFound, the same as
// a driver with no row at all: from dispatch's point of view the driver has no
// usable position either way, and the caller must not invent one.
const DriverPresenceMaxAgeS = 5 * 60

// driverPresenceMaxAgeSeconds is DriverPresenceMaxAgeS as the float64 the SQL
// binds. It is a typed CONST so it cannot become a time.Duration the way
// driverLivenessSeconds could — see that comment for why binding a Duration
// silently corrupts the interval.
const driverPresenceMaxAgeSeconds = float64(DriverPresenceMaxAgeS)

// TouchDriverPresence writes status onto a driver's EXISTING position row and
// re-arms the liveness window for a driver who is online at a known location
// but has not moved. It deliberately does NOT create a row: with no fix there
// are no coordinates to dispatch to, and inventing one would be a lie the whole
// offer path would act on. It also does NOT resurrect an arbitrarily old fix:
// the row must be younger than DriverPresenceMaxAgeS, or the driver counts as
// having no usable position and ErrNotFound is returned.
func (r *GeoRepo) TouchDriverPresence(driverID, status string) error {
	res, err := r.db.Exec(`
		UPDATE driver_positions SET status = $2, updated_at = NOW()
		WHERE driver_id = $1
		  AND updated_at > NOW() - make_interval(secs => $3::double precision)`,
		driverID, status, driverPresenceMaxAgeSeconds)
	if err != nil {
		return wrapDB("touch driver presence", err)
	}
	touched, err := res.RowsAffected()
	if err != nil {
		return wrapDB("touch driver presence", err)
	}
	if touched == 0 {
		// Two distinct facts, one outcome: the driver has never sent a fix at
		// all, or their last one is too old to trust. Both mean "dispatch has
		// no position for this driver", which is what the caller must report.
		return presenceUndispatchable(driverID)
	}
	return nil
}

// presenceUndispatchable is that single error. It is a named helper so the
// message — the only signal a support trace has for "the driver is online but
// dispatch cannot see them" — is unit-testable without a database.
func presenceUndispatchable(driverID string) error {
	return fmt.Errorf("driver %s has no dispatchable position (none recorded, or the last fix is older than %ds): %w",
		driverID, DriverPresenceMaxAgeS, ErrNotFound)
}
