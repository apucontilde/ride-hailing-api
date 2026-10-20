package model

import "time"

type LatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

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
	DriverID  string  `db:"driver_id" json:"driver_id"`
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
	Heading   float64 `db:"heading" json:"heading"`
	Speed     float64 `db:"speed" json:"speed"`
	DistanceM float64 `db:"distance_m" json:"distance_m"`
	// UpdatedAt and AgeS are the accept-time fix freshness contract
	// (api_plans/[arrival]_accept_time_evaluation.md D2/D6). AgeS is computed
	// by Postgres in the same read as the fix — never from the app clock — and
	// only GetDriverLocation selects either column; FindNearbyDrivers leaves
	// both at their zero values. Both stay internal: GET
	// /drivers/:id/location marshals this struct directly, so json:"-" keeps
	// that response shape unchanged.
	UpdatedAt time.Time `db:"updated_at" json:"-"`
	AgeS      float64   `db:"age_s" json:"-"`
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
	Edges          []RouteEdge `json:"edges"`
	TotalDistanceM float64     `json:"total_distance_m"`
	TotalDurationS float64     `json:"total_duration_s"`
	Polyline       string      `json:"polyline"`
	Fallback       bool        `json:"fallback,omitempty"`
	ElevFallback   bool        `json:"elevation_fallback,omitempty"`
}
