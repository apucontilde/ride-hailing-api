package repository

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

type RideRepository interface {
	CreateRide(ride *model.Ride) error
	FindByID(id string) (*model.Ride, error)
	FindCurrentRideByRider(riderID string) (*model.Ride, error)
	FindCurrentRideByDriver(driverID string) (*model.Ride, error)
	FindRidesByRider(riderID string, limit, offset int) ([]model.Ride, int, error)
	FindRidesByDriver(driverID string, limit, offset int) ([]model.Ride, int, error)
	UpdateRideStatus(rideID, status string, timestamp *time.Time) error
	AssignDriver(rideID, driverID string) error
	CreateEvent(event *model.RideEvent) error
	CreateRating(rating *model.Rating) error
	FindVehicleByDriverID(driverID string) (*model.DriverVehicle, error)
}

var _ RideRepository = (*RideRepo)(nil)

type RideRepo struct {
	db *sqlx.DB
}

func NewRideRepo(db *sqlx.DB) *RideRepo {
	return &RideRepo{db: db}
}

func (r *RideRepo) CreateRide(ride *model.Ride) error {
	query := `
		INSERT INTO rides (rider_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
			pickup_address, dropoff_address, vehicle_type, idempotency_key, status, requested_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'pending', NOW())
		RETURNING id, status, created_at, updated_at`
	return r.db.QueryRow(query, ride.RiderID, ride.PickupLat, ride.PickupLng,
		ride.DropoffLat, ride.DropoffLng, ride.PickupAddress, ride.DropoffAddress,
		ride.VehicleType, ride.IdempotencyKey).
		Scan(&ride.ID, &ride.Status, &ride.CreatedAt, &ride.UpdatedAt)
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
