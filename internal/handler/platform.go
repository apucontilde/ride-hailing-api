package handler

import (
	"fmt"
	"net/http"
	"strconv"

	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"

	"github.com/gin-gonic/gin"
)

type PlatformHandler struct {
	navSvc       *service.NavigationService
	fareSvc      *service.FareService
	placesRepo   repository.PlacesRepository
	maxRadiusM   float64
	defaultLimit int
}

func NewPlatformHandler(navSvc *service.NavigationService, fareSvc *service.FareService, placesRepo repository.PlacesRepository, maxRadiusM float64, defaultLimit int) *PlatformHandler {
	return &PlatformHandler{navSvc: navSvc, fareSvc: fareSvc, placesRepo: placesRepo, maxRadiusM: maxRadiusM, defaultLimit: defaultLimit}
}

type sosRequest struct {
	Lat float64 `json:"lat" binding:"required"`
	Lng float64 `json:"lng" binding:"required"`
}

type feedbackRequest struct {
	Message string  `json:"message" binding:"required"`
	RideID  *string `json:"ride_id"`
}

type deviceRegisterRequest struct {
	Token    string `json:"token" binding:"required"`
	Platform string `json:"platform" binding:"required"`
}

// SOS godoc
//
//	@Summary	Send an SOS alert
//	@Tags		platform
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		sosRequest	true	"SOS request"
//	@Success	201		{object}	SOSResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/sos [post]
func (h *PlatformHandler) SOS(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var req sosRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		_ = c.Error(fmt.Errorf("[sos] validation error (user=%v): %w", userID, err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"message": "SOS alert received",
		"alert": gin.H{
			"user_id": userID,
			"lat":     req.Lat,
			"lng":     req.Lng,
			"status":  "active",
		},
	})
}

// Feedback godoc
//
//	@Summary	Submit user feedback
//	@Tags		platform
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		feedbackRequest	true	"Feedback request"
//	@Success	201		{object}	MessageResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/feedback [post]
func (h *PlatformHandler) Feedback(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var req feedbackRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		_ = c.Error(fmt.Errorf("[feedback] validation error (user=%v): %w", userID, err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "feedback submitted"})
}

// DeviceRegister godoc
//
//	@Summary	Register a push notification device
//	@Tags		platform
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		deviceRegisterRequest	true	"Device registration request"
//	@Success	201		{object}	MessageResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/devices [post]
func (h *PlatformHandler) DeviceRegister(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var req deviceRegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		_ = c.Error(fmt.Errorf("[devices] register validation error (user=%v): %w", userID, err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "device registered"})
}

// DeviceUnregister godoc
//
//	@Summary	Unregister a push notification device
//	@Tags		platform
//	@Security	BearerAuth
//	@Param		token	path	string	true	"Device token"
//	@Success	204		"No content"
//	@Router		/api/v1/devices/{token} [delete]
func (h *PlatformHandler) DeviceUnregister(c *gin.Context) {
	c.JSON(http.StatusNoContent, nil)
}

// PromotionsList godoc
//
//	@Summary	List available promotions
//	@Tags		promotions
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	PromotionsResponse
//	@Router		/api/v1/promotions [get]
func (h *PlatformHandler) PromotionsList(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"promotions": []interface{}{}})
}

// ApplyPromotion godoc
//
//	@Summary	Apply a promotion (stub)
//	@Tags		promotions
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	MessageResponse
//	@Router		/api/v1/promotions/apply [post]
func (h *PlatformHandler) ApplyPromotion(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"message": "promotion applied (stub)"})
}

// PlacesAutocomplete godoc
//
//	@Summary	Autocomplete places near coordinates
//	@Tags		places
//	@Produce	json
//	@Security	BearerAuth
//	@Param		lat		query		number	true	"Latitude"
//	@Param		lng		query		number	true	"Longitude"
//	@Param		q		query		string	false	"Free-text search query"
//	@Param		radius	query		number	false	"Search radius in meters"	default(1000)
//	@Param		limit	query		int		false	"Maximum results (max 50)"	default(10)
//	@Success	200		{object}	PlacesResponse
//	@Failure	422		{object}	ErrorResponse	"Invalid parameters"
//	@Failure	500		{object}	ErrorResponse	"Query failed"
//	@Router		/api/v1/places/autocomplete [get]
func (h *PlatformHandler) PlacesAutocomplete(c *gin.Context) {
	lat, err := strconv.ParseFloat(c.Query("lat"), 64)
	if err != nil {
		_ = c.Error(fmt.Errorf("[places] autocomplete invalid lat value=%q: %w", c.Query("lat"), err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lat"}})
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		_ = c.Error(fmt.Errorf("[places] autocomplete invalid lng value=%q: %w", c.Query("lng"), err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lng"}})
		return
	}

	radius := 1000.0
	if r := c.Query("radius"); r != "" {
		radius, err = strconv.ParseFloat(r, 64)
		if err != nil {
			_ = c.Error(fmt.Errorf("[places] autocomplete invalid radius value=%q: %w", r, err))
		}
	}
	if radius > h.maxRadiusM {
		radius = h.maxRadiusM
	}

	query := c.Query("q")

	limit := h.defaultLimit
	if l := c.Query("limit"); l != "" {
		var atoiErr error
		limit, atoiErr = strconv.Atoi(l)
		if atoiErr != nil {
			_ = c.Error(fmt.Errorf("[places] autocomplete invalid limit value=%q: %w", l, atoiErr))
		}
	}
	if limit > 50 {
		limit = 50
	}
	if limit <= 0 {
		limit = h.defaultLimit
	}

	places, err := h.placesRepo.FindNearbyPlaces(lat, lng, radius, query, limit)
	if err != nil {
		_ = c.Error(fmt.Errorf("[places] autocomplete query failed: %w", err))
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to query places"}})
		return
	}

	c.JSON(http.StatusOK, gin.H{"places": places})
}

// PlacesGeocode godoc
//
//	@Summary		Reverse-geocode a coordinate into a place
//	@Description	Returns the nearest known place to the given coordinates, used to turn a map pin into an address.
//	@Tags			places
//	@Produce		json
//	@Security		BearerAuth
//	@Param			lat		query		number			true	"Latitude"
//	@Param			lng		query		number			true	"Longitude"
//	@Param			radius	query		number			false	"Search radius in meters (default 500, capped at the configured max)"	default(500)
//	@Success		200		{object}	GeocodeResponse	"place is null when nothing is found within the radius"
//	@Failure		422		{object}	ErrorResponse	"Invalid parameters"
//	@Failure		500		{object}	ErrorResponse	"Query failed"
//	@Router			/api/v1/places/geocode [get]
func (h *PlatformHandler) PlacesGeocode(c *gin.Context) {
	lat, err := strconv.ParseFloat(c.Query("lat"), 64)
	if err != nil {
		_ = c.Error(fmt.Errorf("[places] geocode invalid lat value=%q: %w", c.Query("lat"), err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lat"}})
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		_ = c.Error(fmt.Errorf("[places] geocode invalid lng value=%q: %w", c.Query("lng"), err))
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lng"}})
		return
	}

	radius := 500.0
	if r := c.Query("radius"); r != "" {
		radius, err = strconv.ParseFloat(r, 64)
		if err != nil {
			_ = c.Error(fmt.Errorf("[places] geocode invalid radius value=%q: %w", r, err))
		}
	}
	if radius > h.maxRadiusM {
		radius = h.maxRadiusM
	}

	place, err := h.placesRepo.ReverseGeocode(lat, lng, radius)
	if err != nil {
		_ = c.Error(fmt.Errorf("[places] geocode query failed: %w", err))
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to query places"}})
		return
	}

	c.JSON(http.StatusOK, gin.H{"place": place})
}

// PlacesDetails godoc
//
//	@Summary	Get place details (stub)
//	@Tags		places
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	PlacesResponse
//	@Router		/api/v1/places/details [get]
func (h *PlatformHandler) PlacesDetails(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"place": nil})
}

// EstimatesPrice godoc
//
//	@Summary		Get price estimates by vehicle type
//	@Description	Computes base + distance + time fare with surge for each vehicle type, using the live routing engine.
//	@Tags			estimates
//	@Produce		json
//	@Security		BearerAuth
//	@Param			pickup_lat		query		number	true	"Pickup latitude"
//	@Param			pickup_lng		query		number	true	"Pickup longitude"
//	@Param			dropoff_lat		query		number	true	"Dropoff latitude"
//	@Param			dropoff_lng		query		number	true	"Dropoff longitude"
//	@Param			vehicle_type	query		string	false	"Limit to one type (sedan|suv|luxury); all types when omitted"
//	@Success		200				{object}	EstimatesPriceResponse
//	@Failure		422				{object}	ErrorResponse	"Invalid parameters"
//	@Failure		500				{object}	ErrorResponse	"Failed to compute estimate"
//	@Router			/api/v1/estimates/price [get]
func (h *PlatformHandler) EstimatesPrice(c *gin.Context) {
	pickupLat, pickupLng, dropoffLat, dropoffLng, ok := h.parseCoordinates(c, pickupDropoffKeys)
	if !ok {
		return
	}

	vehicleTypes := []string{"sedan", "suv", "luxury"}
	if vt := c.Query("vehicle_type"); vt != "" {
		switch vt {
		case "sedan", "suv", "luxury":
			vehicleTypes = []string{vt}
		default:
			_ = c.Error(fmt.Errorf("[estimates] invalid vehicle_type=%q", vt))
			c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid vehicle_type"}})
			return
		}
	}

	estimates := make([]Estimate, 0, len(vehicleTypes))
	for _, vt := range vehicleTypes {
		est, err := h.fareSvc.CalculateEstimate(pickupLat, pickupLng, dropoffLat, dropoffLng, vt)
		if err != nil {
			_ = c.Error(fmt.Errorf("[estimates] price failed vt=%s pickup=(%.5f,%.5f) dropoff=(%.5f,%.5f): %w",
				vt, pickupLat, pickupLng, dropoffLat, dropoffLng, err))
			c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to compute estimate"}})
			return
		}
		estimates = append(estimates, Estimate{
			VehicleType:     vt,
			BaseFare:        est.BaseFare,
			DistanceRate:    est.DistanceFare,
			TimeRate:        est.TimeFare,
			DistanceFare:    est.DistanceFare,
			TimeFare:        est.TimeFare,
			SurgeMultiplier: est.SurgeMultiplier,
			Total:           est.Total,
		})
	}

	c.JSON(http.StatusOK, gin.H{"estimates": estimates})
}

// EstimatesETA godoc
//
//	@Summary		Get a route-based ETA estimate
//	@Description	Returns travel seconds and distance for a route between two coordinates, computed from the live routing engine.
//	@Tags			estimates
//	@Produce		json
//	@Security		BearerAuth
//	@Param			from_lat	query		number	true	"Origin latitude"
//	@Param			from_lng	query		number	true	"Origin longitude"
//	@Param			to_lat		query		number	true	"Destination latitude"
//	@Param			to_lng		query		number	true	"Destination longitude"
//	@Success		200			{object}	EstimatesETAResponse
//	@Failure		422			{object}	ErrorResponse	"Invalid parameters"
//	@Failure		500			{object}	ErrorResponse	"Routing failed"
//	@Router			/api/v1/estimates/eta [get]
//	@Router			/api/v1/geo/eta [get]
func (h *PlatformHandler) EstimatesETA(c *gin.Context) {
	fromLat, fromLng, toLat, toLng, ok := h.parseCoordinates(c, fromToKeys)
	if !ok {
		return
	}

	route, err := h.navSvc.GetRoute(fromLat, fromLng, toLat, toLng)
	if err != nil {
		_ = c.Error(fmt.Errorf("[estimates] eta route failed from=(%.5f,%.5f) to=(%.5f,%.5f): %w",
			fromLat, fromLng, toLat, toLng, err))
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to calculate route"}})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"eta_seconds":     route.DurationSecs,
		"distance_meters": route.DistanceMeters,
	})
}

// UpdateDestination godoc
//
//	@Summary	Update a ride's destination (stub)
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	MessageResponse
//	@Router		/api/v1/rides/{id}/destination [put]
func (h *PlatformHandler) UpdateDestination(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"message": "destination updated"})
}

// NavigationRoute godoc
//
//	@Summary	Get a route between two coordinates
//	@Tags		navigation
//	@Produce	json
//	@Security	BearerAuth
//	@Param		from_lat	query		number	true	"Origin latitude"
//	@Param		from_lng	query		number	true	"Origin longitude"
//	@Param		to_lat		query		number	true	"Destination latitude"
//	@Param		to_lng		query		number	true	"Destination longitude"
//	@Success	200			{object}	NavigationRouteResponse
//	@Failure	500			{object}	ErrorResponse	"Routing failed"
//	@Router		/api/v1/navigation/route [get]
func (h *PlatformHandler) NavigationRoute(c *gin.Context) {
	fromLat, fromLng, toLat, toLng, ok := h.parseCoordinates(c, fromToKeys)
	if !ok {
		return
	}

	route, err := h.navSvc.GetRoute(fromLat, fromLng, toLat, toLng)
	if err != nil {
		_ = c.Error(fmt.Errorf("[navigation] route failed from=(%.5f,%.5f) to=(%.5f,%.5f): %w", fromLat, fromLng, toLat, toLng, err))
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": err.Error()}})
		return
	}

	var coords []gin.H
	for _, p := range route.Polyline {
		coords = append(coords, gin.H{"lat": p.Lat, "lng": p.Lng})
	}

	c.JSON(http.StatusOK, gin.H{
		"polyline":         coords,
		"total_distance_m": route.DistanceMeters,
		"total_duration_s": route.DurationSecs,
	})
}

// Heatmap godoc
//
//	@Summary	Get a heatmap tile (stub)
//	@Tags		platform
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	HeatmapResponse
//	@Router		/api/v1/heatmap [get]
func (h *PlatformHandler) Heatmap(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"tiles": "data:image/png;base64,..."})
}

// DriverRideQueue godoc
//
//	@Summary	Get the driver's ride queue
//	@Tags		driver
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	QueueResponse
//	@Router		/api/v1/driver/rides/queue [get]
func (h *PlatformHandler) DriverRideQueue(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"queue": []interface{}{}})
}

// DriverRiderInfo godoc
//
//	@Summary	Get rider info for a driver's ride
//	@Tags		driver
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	DriverRiderInfoResponse
//	@Router		/api/v1/driver/rides/{id}/rider [get]
func (h *PlatformHandler) DriverRiderInfo(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"rider": gin.H{"name": "Rider", "rating": 5.0}})
}

// ArrivalNotification godoc
//
//	@Summary	Notify the rider that the driver has arrived
//	@Tags		driver
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	MessageResponse
//	@Router		/api/v1/driver/rides/{id}/notify-arrival [post]
func (h *PlatformHandler) ArrivalNotification(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"message": "rider notified of arrival"})
}

// Version godoc
//
//	@Summary	Get the API version
//	@Tags		platform
//	@Produce	json
//	@Success	200	{object}	VersionResponse
//	@Router		/api/v1/version [get]
func (h *PlatformHandler) Version(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"version": "0.1.0", "commit": "development"})
}

// StubPayment godoc
//
//	@Summary		Not yet implemented (stub)
//	@Description	Placeholder for endpoints pending payment integration and other future work.
//	@Tags			platform
//	@Produce		json
//	@Security		BearerAuth
//	@Success		200	{object}	StubResponse
//	@Router			/api/v1/rider/me/preferences [get]
func (h *PlatformHandler) StubPayment(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "stub",
		"message": "Payment integration pending",
	})
}

// paramSet defines the four query-string keys that name lat/lng for two points.
type paramSet struct {
	lat1 string // e.g. "pickup_lat" or "from_lat"
	lng1 string
	lat2 string
	lng2 string
}

var (
	pickupDropoffKeys = paramSet{"pickup_lat", "pickup_lng", "dropoff_lat", "dropoff_lng"}
	fromToKeys        = paramSet{"from_lat", "from_lng", "to_lat", "to_lng"}
)

// parseCoordinates parses two lat/lng pairs from query params using the given
// key set. On the first missing/invalid value it writes the 422 response and
// returns ok=false.
func (h *PlatformHandler) parseCoordinates(c *gin.Context, keys paramSet) (lat1, lng1, lat2, lng2 float64, ok bool) {
	for _, key := range [4]string{keys.lat1, keys.lng1, keys.lat2, keys.lng2} {
		v, err := strconv.ParseFloat(c.Query(key), 64)
		if err != nil {
			_ = c.Error(fmt.Errorf("invalid coordinate param %s value=%q: %w", key, c.Query(key), err))
			c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid " + key}})
			return 0, 0, 0, 0, false
		}
		switch key {
		case keys.lat1:
			lat1 = v
		case keys.lng1:
			lng1 = v
		case keys.lat2:
			lat2 = v
		case keys.lng2:
			lng2 = v
		}
	}
	return lat1, lng1, lat2, lng2, true
}
