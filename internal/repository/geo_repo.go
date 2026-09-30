package repository

import (
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
}

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
		  AND updated_at > NOW() - INTERVAL '30 seconds'
		  AND ST_DWithin(
				location,
				ST_SetSRID(ST_MakePoint($1, $2), 4326)::GEOGRAPHY,
				$3
			  )
		ORDER BY distance_m
		LIMIT $4`

	err := r.db.Select(&results, query, lng, lat, radiusM, limit)
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
		  AND updated_at > NOW() - INTERVAL '30 seconds'
		  AND ST_DWithin(
				location,
				ST_SetSRID(ST_MakePoint($1, $2), 4326)::GEOGRAPHY,
				$3
			  )`
	err := r.db.Get(&count, query, lng, lat, radiusM)
	if err != nil {
		return 0, wrapDB("count nearby drivers", err)
	}
	return count, nil
}

func (r *GeoRepo) MarkStaleDriversOffline() error {
	_, err := r.db.Exec(`
		UPDATE driver_positions SET status = 'offline'
		WHERE status = 'online' AND updated_at < NOW() - INTERVAL '30 seconds'`)
	return wrapDB("mark stale drivers offline", err)
}
