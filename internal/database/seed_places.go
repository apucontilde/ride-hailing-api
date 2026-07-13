package database

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type geoJSONFeatureCollection struct {
	Features []geoJSONFeature `json:"features"`
}

type geoJSONFeature struct {
	Properties map[string]json.RawMessage `json:"properties"`
	Geometry   geoJSONGeometry            `json:"geometry"`
}

type geoJSONGeometry struct {
	Type        string          `json:"type"`
	Coordinates json.RawMessage `json:"coordinates"`
}

// SeedPlaces loads OSM POI/address data from a GeoJSON file into the places
// table on startup. It is idempotent: it skips when disabled, when the table is
// already populated, or when the data file is missing.
func SeedPlaces(db *sqlx.DB, cfg *config.Config) error {
	if !cfg.PlacesSeedOnStart {
		return nil
	}

	repo := repository.NewPlacesRepo(db)
	count, err := repo.CountPlaces()
	if err != nil {
		return err
	}
	if count > 0 {
		log.Printf("places already seeded (%d rows), skipping", count)
		return nil
	}

	raw, err := os.ReadFile(cfg.PlacesGeoJSONPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			log.Printf("places seed file not found at %s, skipping seed", cfg.PlacesGeoJSONPath)
			return nil
		}
		return fmt.Errorf("failed to read places seed file: %w", err)
	}

	var fc geoJSONFeatureCollection
	if err := json.Unmarshal(raw, &fc); err != nil {
		return fmt.Errorf("failed to parse places GeoJSON: %w", err)
	}

	seeds := make([]model.PlaceSeed, 0, len(fc.Features))
	for _, f := range fc.Features {
		seed, ok := featureToSeed(f)
		if ok {
			seeds = append(seeds, seed)
		}
	}

	if len(seeds) == 0 {
		log.Printf("no usable places found in %s", cfg.PlacesGeoJSONPath)
		return nil
	}

	inserted, err := repo.BulkInsert(seeds)
	if err != nil {
		return err
	}
	log.Printf("seeded %d places (%d features parsed)", inserted, len(seeds))
	return nil
}

func featureToSeed(f geoJSONFeature) (model.PlaceSeed, bool) {
	lat, lng, ok := representativePoint(f.Geometry)
	if !ok {
		return model.PlaceSeed{}, false
	}

	name := prop(f.Properties, "name")
	houseNumber := prop(f.Properties, "addr:housenumber")
	street := prop(f.Properties, "addr:street")
	city := prop(f.Properties, "addr:city")

	category := firstCategory(f.Properties)

	if name == "" {
		if houseNumber == "" {
			return model.PlaceSeed{}, false
		}
		name = strings.TrimSpace(street + " " + houseNumber)
		if name == "" {
			return model.PlaceSeed{}, false
		}
		category = "address"
	}

	address := composeAddress(street, houseNumber, city)

	osmType, osmID, ok := osmIdentity(f.Properties)
	if !ok {
		return model.PlaceSeed{}, false
	}

	return model.PlaceSeed{
		OSMType:  osmType,
		OSMID:    osmID,
		Name:     name,
		Category: category,
		Address:  address,
		Lat:      lat,
		Lng:      lng,
	}, true
}

func firstCategory(props map[string]json.RawMessage) string {
	for _, key := range []string{"amenity", "shop", "tourism", "office", "leisure", "place"} {
		if v := prop(props, key); v != "" {
			return v
		}
	}
	return "poi"
}

func composeAddress(street, houseNumber, city string) *string {
	parts := make([]string, 0, 3)
	line := strings.TrimSpace(street + " " + houseNumber)
	if line != "" {
		parts = append(parts, line)
	}
	if city != "" {
		parts = append(parts, city)
	}
	if len(parts) == 0 {
		return nil
	}
	addr := strings.Join(parts, ", ")
	return &addr
}

func osmIdentity(props map[string]json.RawMessage) (string, int64, bool) {
	osmType := prop(props, "@type")
	if osmType == "" {
		osmType = prop(props, "type")
	}
	idStr := prop(props, "@id")
	if idStr == "" {
		idStr = prop(props, "id")
	}
	if osmType == "" || idStr == "" {
		return "", 0, false
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "", 0, false
	}
	return osmType, id, true
}

// prop extracts a property as a string, accepting either JSON strings or numbers.
func prop(props map[string]json.RawMessage, key string) string {
	raw, ok := props[key]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return strings.TrimSpace(s)
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String()
	}
	return strings.TrimSpace(strings.Trim(string(raw), `"`))
}

// representativePoint returns a single lat/lng for any geometry type by
// averaging all coordinate pairs (centroid) for non-point geometries.
func representativePoint(g geoJSONGeometry) (lat, lng float64, ok bool) {
	if len(g.Coordinates) == 0 {
		return 0, 0, false
	}
	var coords interface{}
	if err := json.Unmarshal(g.Coordinates, &coords); err != nil {
		return 0, 0, false
	}
	var sumLat, sumLng float64
	var n int
	collectCoords(coords, &sumLat, &sumLng, &n)
	if n == 0 {
		return 0, 0, false
	}
	return sumLat / float64(n), sumLng / float64(n), true
}

func collectCoords(v interface{}, sumLat, sumLng *float64, n *int) {
	switch t := v.(type) {
	case []interface{}:
		if len(t) >= 2 {
			lng, lngOk := t[0].(float64)
			lat, latOk := t[1].(float64)
			if lngOk && latOk {
				*sumLng += lng
				*sumLat += lat
				*n++
				return
			}
		}
		for _, item := range t {
			collectCoords(item, sumLat, sumLng, n)
		}
	}
}
