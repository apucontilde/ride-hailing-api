package handler

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
	"ride-hailing-api/internal/service/push"
	"ride-hailing-api/internal/websocket"

	"github.com/gin-gonic/gin"
)

type PlatformHandler struct {
	navSvc       *service.NavigationService
	fareSvc      *service.FareService
	placesRepo   repository.PlacesRepository
	deviceRepo   repository.DeviceTokenRepository
	feedbackRepo repository.FeedbackRepository
	rideRepo     repository.RideRepository
	hub          *websocket.Hub
	pushSvc      *push.Service
	maxRadiusM   float64
	defaultLimit int
	// maxStops is config RIDE_MAX_STOPS, shared with the create path via
	// service.BuildItinerary (api_plans/[fare]_waypoint_fare.md §5).
	maxStops int
}

func NewPlatformHandler(
	navSvc *service.NavigationService,
	fareSvc *service.FareService,
	placesRepo repository.PlacesRepository,
	deviceRepo repository.DeviceTokenRepository,
	feedbackRepo repository.FeedbackRepository,
	rideRepo repository.RideRepository,
	hub *websocket.Hub,
	pushSvc *push.Service,
	maxRadiusM float64,
	defaultLimit int,
	maxStops int,
) *PlatformHandler {
	return &PlatformHandler{
		navSvc:       navSvc,
		fareSvc:      fareSvc,
		placesRepo:   placesRepo,
		deviceRepo:   deviceRepo,
		feedbackRepo: feedbackRepo,
		rideRepo:     rideRepo,
		hub:          hub,
		pushSvc:      pushSvc,
		maxRadiusM:   maxRadiusM,
		defaultLimit: defaultLimit,
		maxStops:     maxStops,
	}
}

type sosRequest struct {
	Lat float64 `json:"lat" binding:"required"`
	Lng float64 `json:"lng" binding:"required"`
}

// feedbackRequest is the body of POST /api/v1/feedback. Type is the client's
// classification (e.g. "app_issue"); it is optional so a pre-existing client
// that sends only `message` keeps working, and it is persisted (bug #20).
type feedbackRequest struct {
	Type    string  `json:"type"`
	Message string  `json:"message" binding:"required"`
	RideID  *string `json:"ride_id"`
}

type deviceRegisterRequest struct {
	Token    string `json:"token" binding:"required"`
	Platform string `json:"platform" binding:"required,oneof=ios android web"`
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
	if !bindJSON(c, &req, fmt.Sprintf("[sos] validation error (user=%v)", userID)) {
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
//	@Success	201		{object}	FeedbackResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Failure	500		{object}	ErrorResponse	"Feedback could not be stored"
//	@Router		/api/v1/feedback [post]
func (h *PlatformHandler) Feedback(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var req feedbackRequest
	if !bindJSON(c, &req, fmt.Sprintf("[feedback] validation error (user=%v)", userID)) {
		return
	}

	if h.feedbackRepo == nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to submit feedback",
			errors.New("feedback repository is not configured"))
		return
	}

	feedback := &model.Feedback{
		UserID:  userID.(string),
		RideID:  req.RideID,
		Type:    req.Type,
		Message: req.Message,
	}
	// A failed write must never answer 201: the client sends feedback once and
	// has no way to notice it was dropped.
	if err := h.feedbackRepo.CreateFeedback(feedback); err != nil {
		respondRepo(c, err, "feedback not found", "", "failed to submit feedback")
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "feedback submitted", "feedback": feedback})
}

// DeviceRegister godoc
//
//	@Summary		Register a push notification device
//	@Description	Upserts the authenticated user's device token. A token is
//	@Description	globally unique: registering a token that another user holds
//	@Description	REASSIGNS it, so the previous user stops receiving pushes to
//	@Description	it. Re-registering the same token does not duplicate.
//	@Tags			platform
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			body	body		deviceRegisterRequest	true	"Device registration request"
//	@Success		201		{object}	DeviceResponse
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Device could not be stored"
//	@Router			/api/v1/devices [post]
//	@Router			/api/v1/device-tokens [post]
func (h *PlatformHandler) DeviceRegister(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var req deviceRegisterRequest
	if !bindJSON(c, &req, fmt.Sprintf("[devices] register validation error (user=%v)", userID)) {
		return
	}

	if h.deviceRepo == nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to register device",
			errors.New("device token repository is not configured"))
		return
	}

	device, err := h.deviceRepo.Register(userID.(string), req.Token, req.Platform)
	if err != nil {
		respondRepo(c, err, "device not found", "", "failed to register device")
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "device registered", "device": device})
}

// DeviceUnregister godoc
//
//	@Summary		Unregister a push notification device
//	@Description	Deactivates the authenticated user's token. Idempotent: an
//	@Description	unknown, already-inactive, or another user's token is a no-op.
//	@Tags			platform
//	@Security		BearerAuth
//	@Param			token	path	string	true	"Device token"
//	@Success		204		"No content"
//	@Failure		500		{object}	ErrorResponse	"Device could not be updated"
//	@Router			/api/v1/devices/{token} [delete]
//	@Router			/api/v1/device-tokens/{token} [delete]
func (h *PlatformHandler) DeviceUnregister(c *gin.Context) {
	userID, _ := c.Get("user_id")
	token := c.Param("token")

	if h.deviceRepo == nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to unregister device",
			errors.New("device token repository is not configured"))
		return
	}

	if err := h.deviceRepo.Unregister(userID.(string), token); err != nil {
		respondRepo(c, err, "device not found", "", "failed to unregister device")
		return
	}

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
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid lat",
			fmt.Errorf("[places] autocomplete invalid lat value=%q: %w", c.Query("lat"), err))
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid lng",
			fmt.Errorf("[places] autocomplete invalid lng value=%q: %w", c.Query("lng"), err))
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
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to query places",
			fmt.Errorf("[places] autocomplete query failed: %w", err))
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
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid lat",
			fmt.Errorf("[places] geocode invalid lat value=%q: %w", c.Query("lat"), err))
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid lng",
			fmt.Errorf("[places] geocode invalid lng value=%q: %w", c.Query("lng"), err))
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
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to query places",
			fmt.Errorf("[places] geocode query failed: %w", err))
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

// estimatePriceRequest is the POST body of /api/v1/estimates/price. It embeds
// the shared coordinate/stops shape so its JSON tags cannot drift from
// POST /rides (api_plans/[fare]_waypoint_fare.md §3.5).
type estimatePriceRequest struct {
	coordinateStopsRequest
	// VehicleType is optional; omitted means all of sedan|suv|luxury. Anything
	// else is a 422.
	VehicleType string `json:"vehicle_type"`
}

// EstimatesPrice godoc
//
//	@Summary		Get price estimates by vehicle type
//	@Description	Computes base + distance + time fare with surge for each vehicle type over the ordered itinerary pickup → stops → dropoff. Returns an additive per-leg breakdown and an is_estimate flag.
//	@Tags			estimates
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			body	body		estimatePriceRequest	true	"Price estimate request"
//	@Success		200		{object}	EstimatesPriceResponse
//	@Failure		400		{object}	ErrorResponse	"Malformed request body"
//	@Failure		422		{object}	ErrorResponse	"Invalid parameters"
//	@Failure		500		{object}	ErrorResponse	"Failed to compute estimate"
//	@Router			/api/v1/estimates/price [post]
func (h *PlatformHandler) EstimatesPrice(c *gin.Context) {
	var req estimatePriceRequest
	if !bindJSON(c, &req, "") {
		return
	}

	// `binding:"required"` guarantees presence only; the range is checked here,
	// exactly as the create path does.
	if msg, cause := validateCoordinatePair(req.PickupLat, req.PickupLng, "Pickup"); cause != nil {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", msg, cause)
		return
	}
	if msg, cause := validateCoordinatePair(req.DropoffLat, req.DropoffLng, "Drop-off"); cause != nil {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", msg, cause)
		return
	}

	vehicleTypes := []string{"sedan", "suv", "luxury"}
	if vt := req.VehicleType; vt != "" {
		switch vt {
		case "sedan", "suv", "luxury":
			vehicleTypes = []string{vt}
		default:
			fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid vehicle_type",
				fmt.Errorf("[estimates] invalid vehicle_type=%q", vt))
			return
		}
	}

	// Build the itinerary exactly like CreateRide: one shared cap, one kind
	// rule, one range rule. It returns the top-level dropoff as the final
	// kind='destination' row, which is dropped before pricing (the pickup and
	// dropoff travel as explicit arguments).
	inputs, invalidMsg := stopInputs(req.Stops)
	if invalidMsg != "" {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", invalidMsg, nil)
		return
	}
	stops, err := service.BuildItinerary(inputs, *req.DropoffLat, *req.DropoffLng, "", h.maxStops)
	if err != nil {
		var verr *service.ValidationError
		if errors.As(err, &verr) {
			fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", verr.Message, err)
			return
		}
		log.Printf("[estimates] unexpected itinerary error: %v", err)
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to compute estimate", err)
		return
	}
	waypoints := make([]model.LatLng, 0, len(stops)-1)
	for i := 0; i < len(stops)-1; i++ {
		waypoints = append(waypoints, model.LatLng{Lat: stops[i].Lat, Lng: stops[i].Lng})
	}

	estimates := make([]Estimate, 0, len(vehicleTypes))
	for _, vt := range vehicleTypes {
		est, err := h.fareSvc.CalculateItineraryEstimate(*req.PickupLat, *req.PickupLng, waypoints,
			*req.DropoffLat, *req.DropoffLng, vt)
		if err != nil {
			fail(c, http.StatusInternalServerError, "INTERNAL", "failed to compute estimate",
				fmt.Errorf("[estimates] price failed vt=%s pickup=(%.5f,%.5f) dropoff=(%.5f,%.5f): %w",
					vt, *req.PickupLat, *req.PickupLng, *req.DropoffLat, *req.DropoffLng, err))
			return
		}
		estimates = append(estimates, Estimate{
			VehicleType:      vt,
			BaseFare:         est.BaseFare,
			DistanceRate:     est.DistanceRate,
			TimeRate:         est.TimeRate,
			DistanceFare:     est.DistanceFare,
			TimeFare:         est.TimeFare,
			SurgeMultiplier:  est.SurgeMultiplier,
			Total:            est.Total,
			RegionID:         est.RegionID,
			Currency:         est.Currency,
			DemandMultiplier: est.DemandMultiplier,
			SupplyMultiplier: est.SupplyMultiplier,
			GradeUpliftPct:   est.GradeUpliftPct,
			IsEstimate:       est.IsEstimate,
			Legs:             estimateLegs(est.Legs),
		})
	}

	c.JSON(http.StatusOK, gin.H{"estimates": estimates})
}

// validateCoordinatePair range-checks one (lat, lng) pointer pair. Presence is
// guaranteed by `binding:"required"`; this covers the range, which `required`
// cannot, and names the label ("Pickup"/"Drop-off") in the message.
func validateCoordinatePair(lat, lng *float64, label string) (string, error) {
	if lat == nil || lng == nil {
		return fmt.Sprintf("Invalid %s", label), fmt.Errorf("[estimates] %s coordinate missing", label)
	}
	if dim := service.CoordinateOutOfRange(*lat, *lng); dim != "" {
		return fmt.Sprintf("%s %s out of range", label, dim),
			fmt.Errorf("[estimates] %s %s out of range (lat=%v lng=%v)", label, dim, *lat, *lng)
	}
	return "", nil
}

// estimateLegs maps the service's per-leg breakdown onto the wire shape. The
// service guarantees at least one leg, so `legs` is never nil/empty.
func estimateLegs(legs []service.FareLeg) []EstimateLeg {
	out := make([]EstimateLeg, 0, len(legs))
	for _, leg := range legs {
		out = append(out, EstimateLeg{
			DistanceMeters: leg.DistanceMeters,
			DurationSecs:   leg.DurationSecs,
			DistanceFare:   leg.DistanceFare,
			TimeFare:       leg.TimeFare,
		})
	}
	return out
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
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to calculate route",
			fmt.Errorf("[estimates] eta route failed from=(%.5f,%.5f) to=(%.5f,%.5f): %w",
				fromLat, fromLng, toLat, toLng, err))
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"eta_seconds":     route.DurationSecs,
		"distance_meters": route.DistanceMeters,
		"is_estimate":     route.IsEstimate,
	})
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
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to calculate route",
			fmt.Errorf("[navigation] route failed from=(%.5f,%.5f) to=(%.5f,%.5f): %w", fromLat, fromLng, toLat, toLng, err))
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
		"total_ascent_m":   route.AscentM,
		"total_descent_m":  route.DescentM,
		"elevation_aware":  route.ElevationAware,
		"is_estimate":      route.IsEstimate,
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
//	@Summary		Notify the rider that the driver has arrived
//	@Description	Sends the live `ride.updated` update to a connected rider, or
//	@Description	a backgrounded push when the rider is not connected.
//	@Description	Ancillary: it never changes the ride's stored status.
//	@Tags			driver
//	@Produce		json
//	@Security		BearerAuth
//	@Param			id	path		string	true	"Ride ID"
//	@Success		200	{object}	MessageResponse
//	@Failure		404	{object}	ErrorResponse	"Ride not found for this driver"
//	@Failure		500	{object}	ErrorResponse	"Notification could not be sent"
//	@Router			/api/v1/driver/rides/{id}/notify-arrival [post]
func (h *PlatformHandler) ArrivalNotification(c *gin.Context) {
	userID, _ := c.Get("user_id")
	driverID, _ := userID.(string)
	rideID := c.Param("id")

	if h.rideRepo == nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to notify rider of arrival",
			errors.New("ride repository is not configured"))
		return
	}

	ride, err := h.rideRepo.FindByID(rideID)
	if err != nil {
		respondRepo(c, err, "ride not found", "", "failed to notify rider of arrival")
		return
	}
	// Only the driver actually assigned to the ride may notify its rider. A
	// 404 (not 403) avoids confirming that somebody else's ride exists.
	if ride.DriverID == nil || *ride.DriverID != driverID {
		fail(c, http.StatusNotFound, "NOT_FOUND", "ride not found", nil)
		return
	}

	msg := websocket.OutgoingMessage{
		Type: "ride.updated",
		Data: websocket.RideUpdateData{
			RideID:    rideID,
			Status:    "driver_arrived",
			Timestamp: time.Now(),
		},
	}
	// A connected rider gets the live update; a backgrounded one gets a push.
	// SendToUser is a no-op when the rider has no socket.
	if h.hub != nil {
		h.hub.SendToUser(ride.RiderID, msg)
	}
	if (h.hub == nil || !h.hub.IsConnected(ride.RiderID)) && h.pushSvc != nil {
		go h.pushSvc.NotifyUser(ride.RiderID, push.Message{
			Title: "Driver arrived",
			Body:  "Your driver has arrived at the pickup point.",
			Data: map[string]string{
				"type":    "ride.updated",
				"status":  "driver_arrived",
				"ride_id": rideID,
			},
		})
	}

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
	lat1 string // e.g. "from_lat"
	lng1 string
	lat2 string
	lng2 string
}

var fromToKeys = paramSet{"from_lat", "from_lng", "to_lat", "to_lng"}

// parseCoordinates parses two lat/lng pairs from query params using the given
// key set. On the first missing/invalid value it writes the 422 response and
// returns ok=false.
func (h *PlatformHandler) parseCoordinates(c *gin.Context, keys paramSet) (lat1, lng1, lat2, lng2 float64, ok bool) {
	for _, key := range [4]string{keys.lat1, keys.lng1, keys.lat2, keys.lng2} {
		v, err := strconv.ParseFloat(c.Query(key), 64)
		if err != nil {
			fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid "+key,
				fmt.Errorf("invalid coordinate param %s value=%q: %w", key, c.Query(key), err))
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
