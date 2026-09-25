package handler

import "ride-hailing-api/internal/model"

// ErrorDetail is the structured error body returned for non-2xx responses.
type ErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ErrorResponse is the standard error envelope used across the API.
type ErrorResponse struct {
	Error ErrorDetail `json:"error"`
}

// MessageResponse is a simple success envelope carrying a message.
type MessageResponse struct {
	Message string `json:"message"`
}

// UserSummary is the public-facing user representation.
type UserSummary struct {
	ID     string `json:"id"`
	Email  string `json:"email"`
	Phone  string `json:"phone"`
	Role   string `json:"role"`
	Status string `json:"status"`
}

// RegisterResponse is returned by POST /api/v1/auth/register.
type RegisterResponse struct {
	User UserSummary `json:"user"`
}

// TokenPair carries JWT access and refresh tokens.
type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

// LoginResponse is returned by POST /api/v1/auth/login.
type LoginResponse struct {
	TokenPair
	User UserSummary `json:"user"`
}

// RiderProfileResponse is returned by GET /api/v1/rider/me.
type RiderProfileResponse struct {
	User  UserSummary `json:"user"`
	Rider model.Rider `json:"rider"`
}

// RiderResponse wraps a rider object.
type RiderResponse struct {
	Rider model.Rider `json:"rider"`
}

// DriverResponse wraps a driver object.
type DriverResponse struct {
	Driver model.Driver `json:"driver"`
}

// RideResponse wraps a ride object.
type RideResponse struct {
	Ride *model.Ride `json:"ride"`
}

// RideListResponse is the paginated ride history envelope.
type RideListResponse struct {
	Rides      interface{} `json:"rides"`
	Total      int         `json:"total"`
	Page       int         `json:"page"`
	PerPage    int         `json:"per_page"`
	TotalPages int         `json:"total_pages"`
}

// RideReceiptResponse is returned by GET /api/v1/rides/:id/receipt.
type RideReceiptResponse struct {
	Receipt struct {
		BaseFare        float64 `json:"base_fare"`
		DistanceFare    float64 `json:"distance_fare"`
		TimeFare        float64 `json:"time_fare"`
		SurgeMultiplier float64 `json:"surge_multiplier"`
		Total           float64 `json:"total"`
	} `json:"receipt"`
}

// NearbyDriversResponse is returned by GET /api/v1/geo/nearby-drivers.
type NearbyDriversResponse struct {
	Drivers interface{} `json:"drivers"`
}

// DriverLocationResponse is returned by GET /api/v1/drivers/:id/location.
type DriverLocationResponse struct {
	DriverID  string  `json:"driver_id"`
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
	Heading   float64 `json:"heading"`
	Speed     float64 `json:"speed"`
	Status    string  `json:"status"`
	UpdatedAt string  `json:"updated_at"`
}

// PlacesResponse is returned by GET /api/v1/places/autocomplete.
type PlacesResponse struct {
	Places interface{} `json:"places"`
}

// GeocodeResponse is returned by GET /api/v1/places/geocode. Place is null
// when no known place is within the search radius of the pin.
type GeocodeResponse struct {
	Place interface{} `json:"place"`
}

// Estimate is a single price estimate by vehicle type.
type Estimate struct {
	VehicleType     string  `json:"vehicle_type"`
	BaseFare        float64 `json:"base_fare"`
	DistanceRate    float64 `json:"distance_rate"`
	TimeRate        float64 `json:"time_rate"`
	DistanceFare    float64 `json:"distance_fare"`
	TimeFare        float64 `json:"time_fare"`
	SurgeMultiplier float64 `json:"surge_multiplier"`
	Total           float64 `json:"total"`
}

// EstimatesPriceResponse is returned by GET /api/v1/estimates/price.
type EstimatesPriceResponse struct {
	Estimates []Estimate `json:"estimates"`
}

// EstimatesETAResponse is returned by GET /api/v1/estimates/eta.
// IsEstimate is true when the pins fell outside every imported region and the
// numbers are a straight-line estimate (api_plans/05) rather than a routed leg.
type EstimatesETAResponse struct {
	EtaSeconds     int  `json:"eta_seconds"`
	DistanceMeters int  `json:"distance_meters"`
	IsEstimate     bool `json:"is_estimate"`
}

// PolylinePoint is a single coordinate along a route polyline.
type PolylinePoint struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// NavigationRouteResponse is returned by GET /api/v1/navigation/route.
// IsEstimate is true when the pins fell outside every imported region, so
// Polyline is the straight line between them rather than a road path
// (api_plans/05).
type NavigationRouteResponse struct {
	Polyline       []PolylinePoint `json:"polyline"`
	TotalDistanceM float64         `json:"total_distance_m"`
	TotalDurationS float64         `json:"total_duration_s"`
	IsEstimate     bool            `json:"is_estimate"`
}

// PromotionsResponse is returned by GET /api/v1/promotions.
type PromotionsResponse struct {
	Promotions interface{} `json:"promotions"`
}

// SOSResponse is returned by POST /api/v1/sos.
type SOSResponse struct {
	Message string `json:"message"`
	Alert   struct {
		UserID string  `json:"user_id"`
		Lat    float64 `json:"lat"`
		Lng    float64 `json:"lng"`
		Status string  `json:"status"`
	} `json:"alert"`
}

// QueueResponse is returned by GET /api/v1/driver/rides/queue.
type QueueResponse struct {
	Queue interface{} `json:"queue"`
}

// DriverRiderInfoResponse is returned by GET /api/v1/driver/rides/:id/rider.
type DriverRiderInfoResponse struct {
	Rider struct {
		Name   string  `json:"name"`
		Rating float64 `json:"rating"`
	} `json:"rider"`
}

// VersionResponse is returned by GET /api/v1/version.
type VersionResponse struct {
	Version string `json:"version"`
	Commit  string `json:"commit"`
}

// StubResponse is returned by endpoints that are not yet implemented.
type StubResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

// HeatmapResponse is returned by GET /api/v1/heatmap.
type HeatmapResponse struct {
	Tiles string `json:"tiles"`
}

// HealthResponse is returned by GET /health.
type HealthResponse struct {
	Status string `json:"status"`
}

// ReadinessResponse is returned by GET /health/ready.
type ReadinessResponse struct {
	Status string            `json:"status"`
	Checks map[string]string `json:"checks"`
}
