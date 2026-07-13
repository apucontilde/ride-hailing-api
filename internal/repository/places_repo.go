package repository

import (
	"fmt"
	"strings"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

type PlacesRepository interface {
	FindNearbyPlaces(lat, lng, radiusM float64, query string, limit int) ([]model.NearbyPlaceResult, error)
	CountPlaces() (int, error)
	BulkInsert(places []model.PlaceSeed) (int, error)
}

var _ PlacesRepository = (*PlacesRepo)(nil)

type PlacesRepo struct {
	db *sqlx.DB
}

func NewPlacesRepo(db *sqlx.DB) *PlacesRepo { return &PlacesRepo{db: db} }

func (r *PlacesRepo) FindNearbyPlaces(lat, lng, radiusM float64, query string, limit int) ([]model.NearbyPlaceResult, error) {
	var results []model.NearbyPlaceResult
	sql := `
		SELECT id, name, category, address,
		       ST_X(location::GEOMETRY) AS lng,
		       ST_Y(location::GEOMETRY) AS lat,
		       ST_Distance(location, ST_SetSRID(ST_MakePoint($1,$2),4326)::GEOGRAPHY) AS distance_m,
		       CASE WHEN $4 = '' THEN 0
		            ELSE ts_rank(search_tsv, plainto_tsquery('simple', $4)) END AS rank
		FROM places
		WHERE ST_DWithin(location, ST_SetSRID(ST_MakePoint($1,$2),4326)::GEOGRAPHY, $3)
		  AND ($4 = '' OR search_tsv @@ plainto_tsquery('simple', $4))
		ORDER BY rank DESC, distance_m ASC
		LIMIT $5`
	if err := r.db.Select(&results, sql, lng, lat, radiusM, query, limit); err != nil {
		return nil, fmt.Errorf("failed to find nearby places: %w", err)
	}
	return results, nil
}

func (r *PlacesRepo) CountPlaces() (int, error) {
	var n int
	if err := r.db.Get(&n, `SELECT COUNT(*) FROM places`); err != nil {
		return 0, fmt.Errorf("failed to count places: %w", err)
	}
	return n, nil
}

func (r *PlacesRepo) BulkInsert(places []model.PlaceSeed) (int, error) {
	const batchSize = 500
	total := 0
	for start := 0; start < len(places); start += batchSize {
		end := start + batchSize
		if end > len(places) {
			end = len(places)
		}
		n, err := r.insertBatch(places[start:end])
		if err != nil {
			return total, err
		}
		total += n
	}
	return total, nil
}

func (r *PlacesRepo) insertBatch(batch []model.PlaceSeed) (int, error) {
	if len(batch) == 0 {
		return 0, nil
	}
	valueStrings := make([]string, 0, len(batch))
	args := make([]interface{}, 0, len(batch)*7)
	for i, p := range batch {
		b := i * 7
		valueStrings = append(valueStrings, fmt.Sprintf(
			"($%d,$%d,$%d,$%d,$%d, ST_SetSRID(ST_MakePoint($%d,$%d),4326)::GEOGRAPHY)",
			b+1, b+2, b+3, b+4, b+5, b+6, b+7,
		))
		args = append(args, p.OSMType, p.OSMID, p.Name, p.Category, p.Address, p.Lng, p.Lat)
	}
	sql := `INSERT INTO places (osm_type, osm_id, name, category, address, location) VALUES ` +
		strings.Join(valueStrings, ",") +
		` ON CONFLICT (osm_type, osm_id) DO NOTHING`

	res, err := r.db.Exec(sql, args...)
	if err != nil {
		return 0, fmt.Errorf("failed to bulk insert places: %w", err)
	}
	affected, _ := res.RowsAffected()
	return int(affected), nil
}
