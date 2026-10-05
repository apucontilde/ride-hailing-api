package model

import "time"

type Ride struct {
	ID              string  `db:"id" json:"id"`
	RiderID         string  `db:"rider_id" json:"rider_id"`
	DriverID        *string `db:"driver_id" json:"driver_id"`
	Status          string  `db:"status" json:"status"`
	PickupLat       float64 `db:"pickup_lat" json:"pickup_lat"`
	PickupLng       float64 `db:"pickup_lng" json:"pickup_lng"`
	DropoffLat      float64 `db:"dropoff_lat" json:"dropoff_lat"`
	DropoffLng      float64 `db:"dropoff_lng" json:"dropoff_lng"`
	PickupAddress   string  `db:"pickup_address" json:"pickup_address"`
	DropoffAddress  string  `db:"dropoff_address" json:"dropoff_address"`
	VehicleType     string  `db:"vehicle_type" json:"vehicle_type"`
	CancellationFee float64 `db:"cancellation_fee" json:"cancellation_fee"`
	IdempotencyKey  string  `db:"idempotency_key" json:"-"`

	BaseFare        float64 `db:"base_fare" json:"base_fare"`
	DistanceFare    float64 `db:"distance_fare" json:"distance_fare"`
	TimeFare        float64 `db:"time_fare" json:"time_fare"`
	SurgeMultiplier float64 `db:"surge_multiplier" json:"surge_multiplier"`
	TotalFare       float64 `db:"total_fare" json:"total_fare"`

	RequestedAt     *time.Time `db:"requested_at" json:"requested_at"`
	AcceptedAt      *time.Time `db:"accepted_at" json:"accepted_at"`
	DriverArrivedAt *time.Time `db:"driver_arrived_at" json:"driver_arrived_at"`
	StartedAt       *time.Time `db:"started_at" json:"started_at"`
	CompletedAt     *time.Time `db:"completed_at" json:"completed_at"`
	CancelledAt     *time.Time `db:"cancelled_at" json:"cancelled_at"`
	CreatedAt       time.Time  `db:"created_at" json:"created_at"`
	UpdatedAt       time.Time  `db:"updated_at" json:"updated_at"`

	// Stops is the itinerary, written by CreateRide in the same transaction as
	// the ride row (migration 016). It is not a rides column, so it is hidden
	// from the ride JSON: the read endpoints expose it as a separate, additive
	// `stops` envelope instead, which cannot change the shape of `ride` for a
	// client that ignores it.
	Stops []RideStop `db:"-" json:"-"`
}

type RideEvent struct {
	ID         string    `db:"id" json:"id"`
	RideID     string    `db:"ride_id" json:"ride_id"`
	FromStatus string    `db:"from_status" json:"from_status"`
	ToStatus   string    `db:"to_status" json:"to_status"`
	Actor      string    `db:"actor" json:"actor"`
	Reason     string    `db:"reason" json:"reason"`
	CreatedAt  time.Time `db:"created_at" json:"created_at"`
}

type Rating struct {
	ID        string    `db:"id" json:"id"`
	RideID    string    `db:"ride_id" json:"ride_id"`
	RaterRole string    `db:"rater_role" json:"rater_role"`
	RaterID   string    `db:"rater_id" json:"rater_id"`
	RateeID   string    `db:"ratee_id" json:"ratee_id"`
	Score     int       `db:"score" json:"score"`
	Comment   string    `db:"comment" json:"comment"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

type RiderPreference struct {
	UserID string `db:"user_id" json:"user_id"`
	Key    string `db:"key" json:"key"`
	Value  string `db:"value" json:"value"`
}

// RideStop kinds. `Stop` is an intermediate waypoint; `Destination` is the
// final one and is always the highest Sequence. The final destination is
// mirrored into rides.dropoff_lat/lng/address, which stays authoritative for
// the routing, fare and receipt paths.
const (
	StopKind        = "stop"
	DestinationKind = "destination"
)

// RideStop is one ordered waypoint of a ride (migration 016). Sequence is
// 1-based and unique per ride; Stops is the itinerary in visit order with the
// final DestinationKind last.
type RideStop struct {
	ID        string    `db:"id" json:"id"`
	RideID    string    `db:"ride_id" json:"ride_id"`
	Sequence  int       `db:"sequence" json:"sequence"`
	Kind      string    `db:"kind" json:"kind"`
	Lat       float64   `db:"lat" json:"lat"`
	Lng       float64   `db:"lng" json:"lng"`
	Address   string    `db:"address" json:"address"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}
