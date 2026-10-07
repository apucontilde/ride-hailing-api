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

	// Fare audit (migration 019, api_plans/STATUS.md [fare]).
	// These snapshot WHICH region's card and WHICH card version priced the
	// ride, so stage 02 can recompute from the BOOKED card rather than the
	// current one. They are pointers because a ride booked before 019 (or one
	// whose region had no card) has SQL NULL: scanning NULL into a string would
	// fail. The fare_* DOUBLE columns above stay major currency units at this
	// JSON boundary; the audit columns are metadata, not money.
	FareRegionID *string `db:"fare_region_id" json:"fare_region_id"`
	FareRateID   *string `db:"fare_rate_id" json:"fare_rate_id"`
	FareCurrency *string `db:"fare_currency" json:"fare_currency"`
	// GradeUpliftPct is the climb uplift APPLIED to the charged distance leg,
	// as a fraction (0.12 == +12%). Like the money columns it holds the BOOKED
	// value until completion, then the value RECOMPUTED on the actual distance,
	// so a completed ride's `grade_uplift_pct` reconciles with its final
	// distance_fare. The booked snapshot is preserved in
	// QuotedGradeUpliftPct (migration 023).
	GradeUpliftPct *float64 `db:"grade_uplift_pct" json:"grade_uplift_pct"`
	// GradeAscentM is the RAW ascent the applied uplift was derived from
	// (migration 020). NULL means no uplift was applied (the fail-flat case),
	// never a fabricated 0; the same pointer discipline as the fare_* audit
	// columns.
	GradeAscentM *float64 `db:"grade_ascent_m" json:"grade_ascent_m"`

	// Actual trip actuals (migration 021, api_plans/[tracking]_actual_trip_distance.md).
	// Both are pointers because SQL NULL means "no usable actual", never a
	// fabricated 0: a missing trace leaves ActualDistanceM nil and a missing
	// timestamp pair leaves ActualDurationS nil, and the later fare recompute
	// (stage 02) falls back to the booked values. They are additive JSON fields.
	ActualDurationS *int     `db:"actual_duration_s" json:"actual_duration_s"`
	ActualDistanceM *float64 `db:"actual_distance_m" json:"actual_distance_m"`

	// Quote-vs-final split (migration 022,
	// api_plans/01_[fare]_actuals_recompute_on_completion.md). On completion the
	// pre-completion money columns (BaseFare/…/TotalFare) are copied here and
	// then overwritten with the recomputed FINAL charge, so the plain money
	// columns always hold what the rider is charged and these hold what was
	// quoted. They are audit metadata and are deliberately hidden from the ride
	// JSON (`json:"-"`): the product decision shows the final charge only, never
	// a separate quoted line. NULL means "no quote was ever captured" (the ride
	// never completed, or predates migration 022), never a fabricated 0.
	QuotedBaseFare        *float64 `db:"quoted_base_fare" json:"-"`
	QuotedDistanceFare    *float64 `db:"quoted_distance_fare" json:"-"`
	QuotedTimeFare        *float64 `db:"quoted_time_fare" json:"-"`
	QuotedSurgeMultiplier *float64 `db:"quoted_surge_multiplier" json:"-"`
	QuotedTotalFare       *float64 `db:"quoted_total_fare" json:"-"`
	// QuotedGradeUpliftPct is the booked climb-uplift audit companion
	// (migration 023), captured at completion exactly like the quoted_* money
	// columns. Hidden from the wire; the applied value rides in GradeUpliftPct.
	QuotedGradeUpliftPct *float64 `db:"quoted_grade_uplift_pct" json:"-"`

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

// RideTrackPoint is one driver location fix recorded while a ride was
// in_progress (migration 021). The sequence of points is the raw trace the
// actual driven distance is summed from; it also carries the driven polyline
// should a later stage expose it. RecordedAt is server receive time.
type RideTrackPoint struct {
	ID         string    `db:"id" json:"id"`
	RideID     string    `db:"ride_id" json:"ride_id"`
	Lat        float64   `db:"lat" json:"lat"`
	Lng        float64   `db:"lng" json:"lng"`
	RecordedAt time.Time `db:"recorded_at" json:"recorded_at"`
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
