package websocket

import "time"

type OutgoingMessage struct {
	Type string      `json:"type"`
	Data interface{} `json:"data"`
}

type RideUpdateData struct {
	RideID      string      `json:"ride_id"`
	Status      string      `json:"status"`
	Timestamp   time.Time   `json:"timestamp"`
	Driver      *DriverInfo `json:"driver,omitempty"`
	Pickup      *PlaceInfo  `json:"pickup,omitempty"`
	Dropoff     *PlaceInfo  `json:"dropoff,omitempty"`
	EtaSeconds  int         `json:"eta_seconds,omitempty"`
	CancelledBy string      `json:"cancelled_by,omitempty"`
	Fare        *FareInfo   `json:"fare,omitempty"`

	// Additive actuals on the completion event (migration 021,
	// api_plans/[tracking]_actual_trip_distance.md). Omitted while absent so an
	// older client sees the payload it always did; a nil pointer means SQL NULL
	// ("no usable actual"), never a fabricated 0.
	ActualDurationS *int     `json:"actual_duration_s,omitempty"`
	ActualDistanceM *float64 `json:"actual_distance_m,omitempty"`
}

type DriverInfo struct {
	ID        string       `json:"id"`
	FirstName string       `json:"first_name"`
	PhotoURL  string       `json:"photo_url"`
	Rating    float64      `json:"rating"`
	Vehicle   *VehicleInfo `json:"vehicle"`
	Location  *LatLng      `json:"location"`
}

type VehicleInfo struct {
	Make        string `json:"make"`
	Model       string `json:"model"`
	Color       string `json:"color"`
	PlateNumber string `json:"plate_number"`
}

type PlaceInfo struct {
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Address string  `json:"address"`
}

type LatLng struct {
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Heading float64 `json:"heading"`
}

type FareInfo struct {
	BaseFare        float64 `json:"base_fare"`
	DistanceFare    float64 `json:"distance_fare"`
	TimeFare        float64 `json:"time_fare"`
	SurgeMultiplier float64 `json:"surge_multiplier"`
	Total           float64 `json:"total"`

	// Additive [fare] identity/applied fields (defect 4 of the actuals review).
	// The driver app already reads `fare.currency` and `fare.grade_uplift_pct`
	// off the completion event (driver_app lib/core/ride/ride_update.dart:75-76);
	// before these fields the reads always resolved to null. currency/region_id
	// are empty for a legacy ride booked before migration 019;
	// GradeUpliftPct is the uplift APPLIED to the final distance leg (0 when the
	// route is flat or the card disables it, never a fabricated value).
	Currency       string  `json:"currency"`
	RegionID       string  `json:"region_id"`
	GradeUpliftPct float64 `json:"grade_uplift_pct"`
}

type DriverLocationData struct {
	RideID   string  `json:"ride_id"`
	DriverID string  `json:"driver_id"`
	Lat      float64 `json:"lat"`
	Lng      float64 `json:"lng"`
	Heading  float64 `json:"heading"`
	Speed    float64 `json:"speed"`
}
