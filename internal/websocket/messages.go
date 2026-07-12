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
}

type DriverLocationData struct {
	RideID   string  `json:"ride_id"`
	DriverID string  `json:"driver_id"`
	Lat      float64 `json:"lat"`
	Lng      float64 `json:"lng"`
	Heading  float64 `json:"heading"`
	Speed    float64 `json:"speed"`
}
