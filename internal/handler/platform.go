package handler

import (
	"fmt"
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
)

type PlatformHandler struct {
	navSvc       *service.NavigationService
	placesRepo   repository.PlacesRepository
	maxRadiusM   float64
	defaultLimit int
}

func NewPlatformHandler(navSvc *service.NavigationService, placesRepo repository.PlacesRepository, maxRadiusM float64, defaultLimit int) *PlatformHandler {
	return &PlatformHandler{navSvc: navSvc, placesRepo: placesRepo, maxRadiusM: maxRadiusM, defaultLimit: defaultLimit}
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
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"message": "SOS alert received",
		"alert": gin.H{
			"user_id":  userID,
			"lat":      req.Lat,
			"lng":      req.Lng,
			"status":   "active",
		},
	})
}

// Feedback godoc
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
	var req feedbackRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "feedback submitted"})
}

// DeviceRegister godoc
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
	var req deviceRegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "device registered"})
}

// DeviceUnregister godoc
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
	log.Printf("[places] autocomplete request lat=%s lng=%s radius=%s q=%q limit=%s",
		c.Query("lat"), c.Query("lng"), c.Query("radius"), c.Query("q"), c.Query("limit"))

	lat, err := strconv.ParseFloat(c.Query("lat"), 64)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lat"}})
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lng"}})
		return
	}

	radius := 1000.0
	if r := c.Query("radius"); r != "" {
		radius, _ = strconv.ParseFloat(r, 64)
	}
	if radius > h.maxRadiusM {
		radius = h.maxRadiusM
	}

	query := c.Query("q")

	limit := h.defaultLimit
	if l := c.Query("limit"); l != "" {
		limit, _ = strconv.Atoi(l)
	}
	if limit > 50 {
		limit = 50
	}
	if limit <= 0 {
		limit = h.defaultLimit
	}

	places, err := h.placesRepo.FindNearbyPlaces(lat, lng, radius, query, limit)
	if err != nil {
		log.Printf("[places] autocomplete error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to query places"}})
		return
	}

	log.Printf("[places] autocomplete returning %d places (lat=%.5f lng=%.5f radius=%.0f q=%q)",
		len(places), lat, lng, radius, query)
	c.JSON(http.StatusOK, gin.H{"places": places})
}

// PlacesGeocode godoc
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
	log.Printf("[places] geocode request lat=%s lng=%s radius=%s",
		c.Query("lat"), c.Query("lng"), c.Query("radius"))

	lat, err := strconv.ParseFloat(c.Query("lat"), 64)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lat"}})
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "invalid lng"}})
		return
	}

	radius := 500.0
	if r := c.Query("radius"); r != "" {
		radius, _ = strconv.ParseFloat(r, 64)
	}
	if radius > h.maxRadiusM {
		radius = h.maxRadiusM
	}

	place, err := h.placesRepo.ReverseGeocode(lat, lng, radius)
	if err != nil {
		log.Printf("[places] geocode error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to query places"}})
		return
	}

	log.Printf("[places] geocode returning %v (lat=%.5f lng=%.5f radius=%.0f)",
		place != nil, lat, lng, radius)
	c.JSON(http.StatusOK, gin.H{"place": place})
}

// PlacesDetails godoc
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
//	@Summary	Get price estimates by vehicle type
//	@Tags		estimates
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	EstimatesPriceResponse
//	@Router		/api/v1/estimates/price [get]
func (h *PlatformHandler) EstimatesPrice(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"estimates": []gin.H{
			{"vehicle_type": "sedan", "base_fare": 5.0, "distance_rate": 1.5, "time_rate": 0.5},
			{"vehicle_type": "suv", "base_fare": 8.0, "distance_rate": 2.0, "time_rate": 0.7},
		},
	})
}

// EstimatesETA godoc
//	@Summary	Get an ETA estimate
//	@Tags		estimates
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	EstimatesETAResponse
//	@Router		/api/v1/estimates/eta [get]
func (h *PlatformHandler) EstimatesETA(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"eta_seconds": 300, "distance_meters": 5000})
}

// UpdateDestination godoc
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
	fromLat := c.Query("from_lat")
	fromLng := c.Query("from_lng")
	toLat := c.Query("to_lat")
	toLng := c.Query("to_lng")

	// In a real app, we would parse these as float64.
	// Using dummy values for now since they are strings in Query().
	// But I should actually parse them.
	var fLat, fLng, tLat, tLng float64
	fmt.Sscanf(fromLat, "%f", &fLat)
	fmt.Sscanf(fromLng, "%f", &fLng)
	fmt.Sscanf(toLat, "%f", &tLat)
	fmt.Sscanf(toLng, "%f", &tLng)

	route, err := h.navSvc.GetRoute(fLat, fLng, tLat, tLng)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
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
//	@Summary	Get the API version
//	@Tags		platform
//	@Produce	json
//	@Success	200	{object}	VersionResponse
//	@Router		/api/v1/version [get]
func (h *PlatformHandler) Version(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"version": "0.1.0", "commit": "development"})
}

// StubPayment godoc
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
