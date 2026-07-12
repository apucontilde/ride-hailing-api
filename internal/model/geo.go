package model

import "time"

type DriverPosition struct {
	DriverID  string    `db:"driver_id" json:"driver_id"`
	Lat       float64   `db:"-" json:"lat"`
	Lng       float64   `db:"-" json:"lng"`
	Heading   float64   `db:"heading" json:"heading"`
	Speed     float64   `db:"speed" json:"speed"`
	Status    string    `db:"status" json:"status"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

type RiderPosition struct {
	RiderID   string    `db:"rider_id" json:"rider_id"`
	Lat       float64   `db:"-" json:"lat"`
	Lng       float64   `db:"-" json:"lng"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

type NearbyDriverResult struct {
	DriverID   string  `db:"driver_id" json:"driver_id"`
	Lat        float64 `json:"lat"`
	Lng        float64 `json:"lng"`
	Heading    float64 `db:"heading" json:"heading"`
	Speed      float64 `db:"speed" json:"speed"`
	DistanceM  float64 `db:"distance_m" json:"distance_m"`
}

type RouteEdge struct {
	EdgeID      int64   `json:"edge_id"`
	Name        string  `json:"name"`
	Instruction string  `json:"instruction"`
	DistanceM   float64 `json:"distance_m"`
	DurationS   float64 `json:"duration_s"`
	Geometry    string  `json:"geometry"`
}

type RouteResponse struct {
	Edges           []RouteEdge `json:"edges"`
	TotalDistanceM  float64     `json:"total_distance_m"`
	TotalDurationS  float64     `json:"total_duration_s"`
	Polyline        string      `json:"polyline"`
	Fallback        bool        `json:"fallback,omitempty"`
	ElevFallback    bool        `json:"elevation_fallback,omitempty"`
}
