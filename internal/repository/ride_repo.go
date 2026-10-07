package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"

	"ride-hailing-api/internal/model"
)

type RideRepository interface {
	CreateRide(ride *model.Ride) error
	FindByID(id string) (*model.Ride, error)
	FindStopsByRideID(rideID string) ([]model.RideStop, error)
	FindStopsByRideIDs(rideIDs []string) (map[string][]model.RideStop, error)
	ReplaceDestination(rideID string, dest model.RideStop) error
	FindCurrentRideByRider(riderID string) (*model.Ride, error)
	FindCurrentRideByDriver(driverID string) (*model.Ride, error)
	FindRidesByRider(riderID string, limit, offset int) ([]model.Ride, int, error)
	FindRidesByDriver(driverID string, limit, offset int) ([]model.Ride, int, error)
	UpdateRideStatus(rideID, status string, timestamp *time.Time) error
	// Actuals (migration 021, api_plans/[tracking]_actual_trip_distance.md).
	InsertRideTrackPoint(rideID string, lat, lng float64, at time.Time) error
	FindRideTrackPoints(rideID string) ([]model.RideTrackPoint, error)
	SetRideActuals(rideID string, durationS *int, distanceM *float64) error
	// FinalizeRideFare captures the current money columns AND the booked climb
	// uplift as the quote and overwrites them with the recomputed final charge
	// (migrations 022/023,
	// api_plans/01_[fare]_actuals_recompute_on_completion.md). gradeUpliftPct is
	// the uplift APPLIED to the final distance leg (nil for a legacy ride with
	// no uplift); the booked value is preserved in quoted_grade_uplift_pct. It
	// is once-only: the UPDATE is guarded on quoted_total_fare IS NULL, so a
	// second call is a no-op that reports finalized=false. That guard is what
	// makes finalization idempotent even if two completions race the service's
	// status machine.
	FinalizeRideFare(rideID string, baseFare, distanceFare, timeFare, totalFare float64, gradeUpliftPct *float64) (finalized bool, err error)
	AssignDriver(rideID, driverID string) error
	CreateEvent(event *model.RideEvent) error
	CreateRating(rating *model.Rating) error
	FindRatingsByRater(raterID, raterRole, rideID string, limit, offset int) ([]model.Rating, int, error)
	FindVehicleByDriverID(driverID string) (*model.DriverVehicle, error)
}

var _ RideRepository = (*RideRepo)(nil)

type RideRepo struct {
	db *sqlx.DB
}

func NewRideRepo(db *sqlx.DB) *RideRepo {
	return &RideRepo{db: db}
}

// CreateRide inserts the ride and its itinerary (ride.Stops, migration 016) in
// ONE transaction.
//
// The stops are not an audit row: a ride whose itinerary failed to persist
// would route and bill a trip the rider never asked for, so a stop failure has
// to undo the ride rather than be logged and forgotten. An empty Stops is the
// pre-016 shape and writes only the rides row.
// CreateRide inserts the ride and its itinerary as ONE unit.
//
// There is deliberately no "no stops, no transaction" shortcut: a ride row and
// its ride_stops rows must never disagree, and a second code path would also
// mean a second error taxonomy (the bare insert returns the raw driver error
// while this one classifies it through wrapDB), so the same logical failure
// could answer 500 without stops and 409 with them.
func (r *RideRepo) CreateRide(ride *model.Ride) error {
	tx, err := r.db.BeginTxx(context.Background(), nil)
	if err != nil {
		return wrapDB("begin ride transaction", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once Commit has succeeded

	query := `
		INSERT INTO rides (rider_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
			pickup_address, dropoff_address, vehicle_type, idempotency_key, status, requested_at,
			base_fare, distance_fare, time_fare, surge_multiplier, total_fare,
			fare_region_id, fare_rate_id, fare_currency, grade_uplift_pct, grade_ascent_m)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'pending', NOW(),
			$10, $11, $12, $13, $14, $15, $16, $17, $18, $19)
		RETURNING id, status, created_at, updated_at`
	if err := tx.QueryRow(query, ride.RiderID, ride.PickupLat, ride.PickupLng,
		ride.DropoffLat, ride.DropoffLng, ride.PickupAddress, ride.DropoffAddress,
		ride.VehicleType, ride.IdempotencyKey,
		ride.BaseFare, ride.DistanceFare, ride.TimeFare, ride.SurgeMultiplier, ride.TotalFare,
		ride.FareRegionID, ride.FareRateID, ride.FareCurrency, ride.GradeUpliftPct, ride.GradeAscentM).
		Scan(&ride.ID, &ride.Status, &ride.CreatedAt, &ride.UpdatedAt); err != nil {
		return wrapDB("create ride", err)
	}

	for i := range ride.Stops {
		stop := &ride.Stops[i]
		stop.RideID = ride.ID
		if err := tx.QueryRow(`
			INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng, address)
			VALUES ($1, $2, $3, $4, $5, $6)
			RETURNING id, created_at, updated_at`,
			stop.RideID, stop.Sequence, stop.Kind, stop.Lat, stop.Lng, stop.Address).
			Scan(&stop.ID, &stop.CreatedAt, &stop.UpdatedAt); err != nil {
			return wrapDB("create ride stop", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return wrapDB("commit ride transaction", err)
	}
	return nil
}

// FindStopsByRideID returns the ride's itinerary in visit order. A ride with no
// stops yields an empty slice, never nil, so callers can range over it.
func (r *RideRepo) FindStopsByRideID(rideID string) ([]model.RideStop, error) {
	// Initialized, never nil: a ride with no itinerary must still encode as
	// "stops": [] and not "stops": null, or every client needs a nil check to
	// tell "no stops" from "not loaded".
	stops := []model.RideStop{}
	if err := r.db.Select(&stops, `
		SELECT id, ride_id, sequence, kind, lat, lng, address, created_at, updated_at
		FROM ride_stops WHERE ride_id = $1 ORDER BY sequence`, rideID); err != nil {
		return nil, wrapDB("load ride stops", err)
	}
	return stops, nil
}

// FindStopsByRideIDs is the batched form used by GET /rides/history, so a page
// of rides costs ONE query instead of one per ride (an N+1 on a 50-row page is
// 50 round-trips on the rider's most-polled screen).
//
// Every requested ride gets an entry, empty slice included, so a caller can
// index the map without a presence check. An empty input answers an empty map
// without touching the database — sqlx would otherwise build an invalid
// `IN ()` statement.
func (r *RideRepo) FindStopsByRideIDs(rideIDs []string) (map[string][]model.RideStop, error) {
	byRide := make(map[string][]model.RideStop, len(rideIDs))
	if len(rideIDs) == 0 {
		return byRide, nil
	}
	for _, id := range rideIDs {
		byRide[id] = []model.RideStop{}
	}

	query := `SELECT id, ride_id, sequence, kind, lat, lng, address, created_at, updated_at
		FROM ride_stops WHERE ride_id = ANY($1) ORDER BY ride_id, sequence`

	var rows []struct {
		ID        string    `db:"id"`
		RideID    string    `db:"ride_id"`
		Sequence  int       `db:"sequence"`
		Kind      string    `db:"kind"`
		Lat       float64   `db:"lat"`
		Lng       float64   `db:"lng"`
		Address   string    `db:"address"`
		CreatedAt time.Time `db:"created_at"`
		UpdatedAt time.Time `db:"updated_at"`
	}
	if err := r.db.Select(&rows, query, pq.Array(rideIDs)); err != nil {
		return nil, wrapDB("load ride stops", err)
	}
	for _, row := range rows {
		byRide[row.RideID] = append(byRide[row.RideID], model.RideStop{
			ID: row.ID, RideID: row.RideID, Sequence: row.Sequence, Kind: row.Kind,
			Lat: row.Lat, Lng: row.Lng, Address: row.Address,
			CreatedAt: row.CreatedAt, UpdatedAt: row.UpdatedAt,
		})
	}
	return byRide, nil
}

// ReplaceDestination changes a ride's final destination: the rides.dropoff_*
// scalars (authoritative for routing, fare and receipt) and the itinerary's
// kind='destination' row move together or not at all.
//
// dest.Sequence and dest.Kind are ignored — the destination is always the last
// waypoint and always kind='destination'. A ride whose itinerary has no
// destination row yet (one created before 016, or with only intermediate
// stops) gets one appended after the current last stop.
//
// The rides row is written FIRST so a missing ride answers ErrNotFound instead
// of tripping the ride_id foreign key, which wrapDB would report as a conflict.
func (r *RideRepo) ReplaceDestination(rideID string, dest model.RideStop) error {
	tx, err := r.db.BeginTxx(context.Background(), nil)
	if err != nil {
		return wrapDB("begin destination transaction", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`
		UPDATE rides SET dropoff_lat=$1, dropoff_lng=$2, dropoff_address=$3, updated_at=NOW()
		WHERE id=$4`, dest.Lat, dest.Lng, dest.Address, rideID)
	if err != nil {
		return wrapDB("update ride destination", err)
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return wrapDB("update ride destination", err)
	}
	if rows == 0 {
		return fmt.Errorf("update ride destination: %w: %w", ErrNotFound, sql.ErrNoRows)
	}

	res, err = tx.Exec(`
		UPDATE ride_stops SET lat=$1, lng=$2, address=$3, updated_at=NOW()
		WHERE ride_id=$4 AND kind='destination'`, dest.Lat, dest.Lng, dest.Address, rideID)
	if err != nil {
		return wrapDB("update destination stop", err)
	}
	rows, err = res.RowsAffected()
	if err != nil {
		return wrapDB("update destination stop", err)
	}
	if rows == 0 {
		// COALESCE keeps the append correct for a ride with no stops at all:
		// the aggregate still yields exactly one row.
		if _, err := tx.Exec(`
			INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng, address)
			SELECT $1, COALESCE(MAX(sequence), 0) + 1, 'destination', $2, $3, $4
			FROM ride_stops WHERE ride_id = $1`,
			rideID, dest.Lat, dest.Lng, dest.Address); err != nil {
			return wrapDB("append destination stop", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return wrapDB("commit destination transaction", err)
	}
	return nil
}

func (r *RideRepo) FindByID(id string) (*model.Ride, error) {
	ride := &model.Ride{}
	err := r.db.Get(ride, "SELECT * FROM rides WHERE id = $1", id)
	if err != nil {
		return nil, wrapDB("load ride", err)
	}
	return ride, nil
}

func (r *RideRepo) FindCurrentRideByRider(riderID string) (*model.Ride, error) {
	ride := &model.Ride{}
	err := r.db.Get(ride, `
		SELECT * FROM rides
		WHERE rider_id = $1 AND status IN ('pending', 'accepted', 'driver_arrived', 'in_progress')
		ORDER BY created_at DESC LIMIT 1`, riderID)
	if err != nil {
		return nil, wrapDB("load active ride", err)
	}
	return ride, nil
}

func (r *RideRepo) FindCurrentRideByDriver(driverID string) (*model.Ride, error) {
	ride := &model.Ride{}
	err := r.db.Get(ride, `
		SELECT * FROM rides
		WHERE driver_id = $1 AND status IN ('accepted', 'driver_arrived', 'in_progress')
		ORDER BY created_at DESC LIMIT 1`, driverID)
	if err != nil {
		return nil, wrapDB("load active ride", err)
	}
	return ride, nil
}

func (r *RideRepo) FindRidesByRider(riderID string, limit, offset int) ([]model.Ride, int, error) {
	var total int
	if err := r.db.Get(&total, "SELECT COUNT(*) FROM rides WHERE rider_id = $1", riderID); err != nil {
		return nil, 0, wrapDB("load rides by rider", err)
	}

	var rides []model.Ride
	err := r.db.Select(&rides, `
		SELECT * FROM rides WHERE rider_id = $1
		ORDER BY created_at DESC LIMIT $2 OFFSET $3`, riderID, limit, offset)
	if err != nil {
		return nil, 0, wrapDB("load rides by rider", err)
	}
	return rides, total, nil
}

func (r *RideRepo) FindRidesByDriver(driverID string, limit, offset int) ([]model.Ride, int, error) {
	var total int
	if err := r.db.Get(&total, "SELECT COUNT(*) FROM rides WHERE driver_id = $1", driverID); err != nil {
		return nil, 0, wrapDB("load rides by driver", err)
	}

	var rides []model.Ride
	err := r.db.Select(&rides, `
		SELECT * FROM rides WHERE driver_id = $1
		ORDER BY created_at DESC LIMIT $2 OFFSET $3`, driverID, limit, offset)
	if err != nil {
		return nil, 0, wrapDB("load rides by driver", err)
	}
	return rides, total, nil
}

func (r *RideRepo) UpdateRideStatus(rideID, status string, timestamp *time.Time) error {
	now := timestamp
	if now == nil {
		t := time.Now()
		now = &t
	}

	statusCol := ""
	switch status {
	case "accepted":
		statusCol = "accepted_at"
	case "driver_arrived":
		statusCol = "driver_arrived_at"
	case "in_progress":
		statusCol = "started_at"
	case "completed":
		statusCol = "completed_at"
	case "cancelled":
		statusCol = "cancelled_at"
	}

	query := fmt.Sprintf(
		"UPDATE rides SET status=$1, %s=$2, updated_at=NOW() WHERE id=$3",
		statusCol,
	)
	_, err := r.db.Exec(query, status, *now, rideID)
	return wrapDB("update ride status", err)
}

// InsertRideTrackPoint appends one accepted driver fix to the ride's trace
// (migration 021). It is APPEND-ONLY on purpose: the hot location endpoint
// never reads-then-writes rides.actual_distance_m, so concurrent pings cannot
// lose a segment to a lost update. The distance is summed from these points on
// the completed transition (service.DrivenDistanceMeters).
//
// at is the server receive time; the noise gate uses it to derive implied speed
// and drop teleports.
func (r *RideRepo) InsertRideTrackPoint(rideID string, lat, lng float64, at time.Time) error {
	_, err := r.db.Exec(`
		INSERT INTO ride_track_points (ride_id, lat, lng, recorded_at)
		VALUES ($1, $2, $3, $4)`, rideID, lat, lng, at)
	return wrapDB("insert ride track point", err)
}

// FindRideTrackPoints returns one ride's fixes in time order (recorded_at, then
// id to break exact ties). A ride with no fixes yields an empty slice, never
// nil, so a caller can range over it.
func (r *RideRepo) FindRideTrackPoints(rideID string) ([]model.RideTrackPoint, error) {
	points := []model.RideTrackPoint{}
	if err := r.db.Select(&points, `
		SELECT id, ride_id, lat, lng, recorded_at
		FROM ride_track_points WHERE ride_id = $1
		ORDER BY recorded_at, id`, rideID); err != nil {
		return nil, wrapDB("load ride track points", err)
	}
	return points, nil
}

// SetRideActuals writes the computed actuals on the completed transition. Nil
// arguments write SQL NULL, which is the honest "no usable actual" the later
// fare recompute falls back from.
func (r *RideRepo) SetRideActuals(rideID string, durationS *int, distanceM *float64) error {
	_, err := r.db.Exec(`
		UPDATE rides SET actual_duration_s=$1, actual_distance_m=$2, updated_at=NOW()
		WHERE id=$3`, durationS, distanceM, rideID)
	return wrapDB("set ride actuals", err)
}

// FinalizeRideFare snapshots the booked quote (money columns AND climb uplift)
// and writes the final charge in ONE statement (migrations 022/023). The quote
// is copied from the row's CURRENT columns, not from a caller-supplied value:
// the service's loaded ride may be stale, but the guarded UPDATE reads the
// pre-finalization row it is about to overwrite, so the quote can never be the
// final charge.
//
// `grade_uplift_pct` follows the money split: it is snapshotted into
// `quoted_grade_uplift_pct` and then overwritten with the uplift APPLIED to the
// final distance leg, so every read path returns the value that reconciles with
// the charged distance_fare.
//
// The `quoted_total_fare IS NULL` guard makes this once-only: a second call (a
// racing completion, a retry that slipped past the status machine) affects zero
// rows and reports finalized=false without touching the row. That is the
// database-level half of the recompute's idempotency; the service half is the
// completed->completed transition being rejected.
func (r *RideRepo) FinalizeRideFare(rideID string, baseFare, distanceFare, timeFare, totalFare float64, gradeUpliftPct *float64) (bool, error) {
	res, err := r.db.Exec(`
		UPDATE rides
		SET quoted_base_fare         = base_fare,
		    quoted_distance_fare     = distance_fare,
		    quoted_time_fare         = time_fare,
		    quoted_surge_multiplier  = surge_multiplier,
		    quoted_total_fare        = total_fare,
		    quoted_grade_uplift_pct  = grade_uplift_pct,
		    base_fare                = $2,
		    distance_fare            = $3,
		    time_fare                = $4,
		    total_fare               = $5,
		    grade_uplift_pct         = $6,
		    updated_at               = NOW()
		WHERE id = $1 AND quoted_total_fare IS NULL`,
		rideID, baseFare, distanceFare, timeFare, totalFare, gradeUpliftPct)
	if err != nil {
		return false, wrapDB("finalize ride fare", err)
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return false, wrapDB("finalize ride fare", err)
	}
	return rows == 1, nil
}

func (r *RideRepo) AssignDriver(rideID, driverID string) error {
	res, err := r.db.Exec(`
		UPDATE rides SET driver_id=$1, status='accepted', accepted_at=NOW(), updated_at=NOW()
		WHERE id=$2 AND status='pending'`,
		driverID, rideID)
	if err != nil {
		return wrapDB("assign driver", err)
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return wrapDB("assign driver", err)
	}
	if rows == 0 {
		return fmt.Errorf("accept ride: %w: %w", ErrConflict, sql.ErrNoRows)
	}
	return nil
}

func (r *RideRepo) CreateEvent(event *model.RideEvent) error {
	_, err := r.db.Exec(`
		INSERT INTO ride_events (ride_id, from_status, to_status, actor, reason)
		VALUES ($1, $2, $3, $4, $5)`,
		event.RideID, event.FromStatus, event.ToStatus, event.Actor, event.Reason)
	return wrapDB("create ride event", err)
}

func (r *RideRepo) FindVehicleByDriverID(driverID string) (*model.DriverVehicle, error) {
	v := &model.DriverVehicle{}
	err := r.db.Get(v, "SELECT * FROM driver_vehicles WHERE driver_id = $1 AND is_active = true ORDER BY created_at DESC LIMIT 1", driverID)
	if err != nil {
		return nil, wrapDB("load vehicle", err)
	}
	return v, nil
}

func (r *RideRepo) CreateRating(rating *model.Rating) error {
	_, err := r.db.Exec(`
		INSERT INTO ratings (ride_id, rater_role, rater_id, ratee_id, score, comment)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		rating.RideID, rating.RaterRole, rating.RaterID, rating.RateeID, rating.Score, rating.Comment)
	return wrapDB("create rating", err)
}

// FindRatingsByRater returns the ratings a single actor submitted (rater_role
// disambiguates the UNIQUE(ride_id, rater_role) row pair), newest first, with
// the total row count for pagination. Backed by idx_ratings_rater (015).
//
// rideID is an optional per-ride existence filter: when non-empty the query is
// further scoped to that ride, so a caller asking "did this rater rate this
// ride?" gets 0 or 1 rows without walking a paginated list. The filter is
// appended, not substituted, so the existing rater-scoped index path is
// unchanged. The handler validates ride_id to the canonical UUID form, so the
// bare column comparison can never receive a value Postgres would reject.
func (r *RideRepo) FindRatingsByRater(raterID, raterRole, rideID string, limit, offset int) ([]model.Rating, int, error) {
	filter := ""
	args := []any{raterID, raterRole}
	if rideID != "" {
		filter = " AND ride_id = $3"
		args = append(args, rideID)
	}

	var total int
	if err := r.db.Get(&total,
		"SELECT COUNT(*) FROM ratings WHERE rater_id = $1 AND rater_role = $2"+filter,
		args...); err != nil {
		return nil, 0, wrapDB("load ratings by rater", err)
	}

	var ratings []model.Rating
	limitIdx := len(args) + 1
	err := r.db.Select(&ratings, fmt.Sprintf(`
		SELECT * FROM ratings WHERE rater_id = $1 AND rater_role = $2%s
		ORDER BY created_at DESC LIMIT $%d OFFSET $%d`, filter, limitIdx, limitIdx+1),
		append(args, limit, offset)...)
	if err != nil {
		return nil, 0, wrapDB("load ratings by rater", err)
	}
	return ratings, total, nil
}
