package handler

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
)

type RideHandler struct {
	rideService     *service.RideService
	dispatchService *service.DispatchService
	rideRepo        repository.RideRepository
}

func NewRideHandler(rideService *service.RideService, dispatchService *service.DispatchService,
	rideRepo repository.RideRepository) *RideHandler {
	return &RideHandler{
		rideService:     rideService,
		dispatchService: dispatchService,
		rideRepo:        rideRepo,
	}
}

type rideRequest struct {
	PickupLat      float64 `json:"pickup_lat" binding:"required"`
	PickupLng      float64 `json:"pickup_lng" binding:"required"`
	DropoffLat     float64 `json:"dropoff_lat" binding:"required"`
	DropoffLng     float64 `json:"dropoff_lng" binding:"required"`
	PickupAddress  string  `json:"pickup_address"`
	DropoffAddress string  `json:"dropoff_address"`
	VehicleType    string  `json:"vehicle_type"`

	// Stops is the ordered list of INTERMEDIATE waypoints, pickup excluded.
	// Optional, so a body without it is byte-identical to the pre-016 request.
	// Order in the array IS the visit order; no sequence is accepted. The final
	// destination is never sent here — it is dropoff_lat/dropoff_lng/
	// dropoff_address. See service.BuildItinerary for the rules.
	Stops []stopRequest `json:"stops"`
}

// stopRequest is one waypoint of a ride request.
//
// Lat/Lng are pointers so an ABSENT coordinate is distinguishable from a
// legitimate 0 (the equator, and the value a Go zero would carry). A non-pointer
// float64 cannot tell those apart.
//
// The `binding` tags are deliberately absent here: go-playground validates the
// top-level struct only and never descends into a slice element, so a required
// tag on this type would be silently inert and a missing coordinate would reach
// the handler as a nil dereference (a 500 with an empty body). CreateRide
// checks these pointers itself and answers 422.
type stopRequest struct {
	// Kind is optional and, when present, must be "stop". A "destination" stop
	// is rejected: the final destination is defined solely by the top-level
	// dropoff_lat/dropoff_lng/dropoff_address, so no client stop may claim it.
	Kind string `json:"kind"`
	// Lat and Lng are REQUIRED on every stop: an absent coordinate is a 422, and
	// 0 is a legitimate value, so presence cannot be inferred from the number.
	Lat     *float64 `json:"lat"`
	Lng     *float64 `json:"lng"`
	Address string   `json:"address"`
}

// changeDestinationRequest is the body of PUT /api/v1/rides/:id/destination.
type changeDestinationRequest struct {
	Lat *float64 `json:"lat" binding:"required"`
	Lng *float64 `json:"lng" binding:"required"`
	// Address is optional; omitting it clears the stored address rather than
	// keeping a stale one, because the coordinates no longer match it.
	Address string `json:"address"`
}

type updateRideStatusRequest struct {
	Status string `json:"status" binding:"required"`
}

type rateRideRequest struct {
	Score   int    `json:"score" binding:"required"`
	Comment string `json:"comment"`
}

// CreateRide godoc
//
//	@Summary		Request a new ride
//	@Description	Creates a ride request and dispatches it to nearby drivers.
//	@Tags			rides
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			body	body		rideRequest	true	"Ride request"
//	@Success		201		{object}	RideWithStopsResponse
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Failed to create ride"
//	@Router			/api/v1/rides [post]
func (h *RideHandler) CreateRide(c *gin.Context) {
	riderID, _ := c.Get("user_id")

	var req rideRequest
	if !bindJSON(c, &req, "") {
		return
	}

	vehicleType := req.VehicleType
	if vehicleType == "" {
		vehicleType = "sedan"
	}

	inputs := make([]service.StopInput, 0, len(req.Stops))
	for i, s := range req.Stops {
		// See stopRequest: nothing validates these pointers, so an absent
		// coordinate is caught here, by hand, with the offending stop named.
		if s.Lat == nil || s.Lng == nil {
			missing := "Latitude"
			if s.Lat != nil {
				missing = "Longitude"
			}
			fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR",
				fmt.Sprintf("Invalid %s in stop %d", missing, i+1), nil)
			return
		}
		inputs = append(inputs, service.StopInput{
			Kind:    s.Kind,
			Lat:     *s.Lat,
			Lng:     *s.Lng,
			Address: s.Address,
		})
	}
	stops, err := service.BuildItinerary(inputs, req.DropoffLat, req.DropoffLng, req.DropoffAddress)
	if err != nil {
		// Itinerary validation is the client's doing, so 422. Only a
		// ValidationError may speak for itself in `message`; anything else
		// coming out of a pure function like this is a bug on our side and must
		// not be dressed up as the client's fault.
		var verr *service.ValidationError
		if errors.As(err, &verr) {
			fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", verr.Message, err)
			return
		}
		log.Printf("ride create: unexpected itinerary error: %v", err)
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to build ride itinerary", err)
		return
	}

	idempotencyKey, _ := c.Get("idempotency_key")
	idKey, _ := idempotencyKey.(string)

	ride, err := h.rideService.RequestRide(riderID.(string),
		req.PickupLat, req.PickupLng,
		req.DropoffLat, req.DropoffLng,
		req.PickupAddress, req.DropoffAddress,
		vehicleType, idKey, stops)

	if err != nil {
		respondRepo(c, err, "rider not found", "ride already requested", "failed to create ride")
		return
	}

	go func() {
		if err := h.dispatchService.Dispatch(ride); err != nil {
			log.Printf("ride %s: dispatch failed: %v", ride.ID, err)
		}
	}()

	c.JSON(http.StatusCreated, gin.H{"ride": ride, "stops": ride.Stops})
}

// GetCurrentRide godoc
//
//	@Summary		Get the current ride for the authenticated user
//	@Description	Returns the active ride for the current rider or driver, or `null`.
//	@Description	The ordered `stops` itinerary is a sibling of `ride` and is
//	@Description	always present (`[]` when there is no current ride).
//	@Tags			rides
//	@Produce		json
//	@Security		BearerAuth
//	@Success		200	{object}	RideWithStopsResponse
//	@Failure		500	{object}	ErrorResponse	"Failed to load ride stops"
//	@Router			/api/v1/rides/current [get]
func (h *RideHandler) GetCurrentRide(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")

	var ride interface{}
	var err error

	if role == "rider" {
		ride, err = h.rideRepo.FindCurrentRideByRider(userID.(string))
	} else {
		ride, err = h.rideRepo.FindCurrentRideByDriver(userID.(string))
	}

	if err != nil {
		// Distinguish "this user has no active ride" from "the load failed".
		// wrapDB maps sql.ErrNoRows to repository.ErrNotFound, and that is the
		// NORMAL case here: a 200 with ride=null is what the app polls for.
		// Anything else (dead database, timeout) is an outage and must NOT be
		// dressed up as "no ride" — the app would silently show the booking
		// screen while an active ride exists.
		if errors.Is(err, repository.ErrNotFound) {
			// `stops` still rides along as an empty array so the key is present
			// on both branches and a client never has to branch on it.
			c.JSON(http.StatusOK, gin.H{"ride": nil, "stops": []model.RideStop{}})
			return
		}
		respondRepo(c, err, "", "", "failed to load current ride")
		return
	}

	// A current ride exists, so load its itinerary. `stops` is always an
	// array, never null, so a client never has to branch on it.
	stops := []model.RideStop{}
	if r, ok := ride.(*model.Ride); ok && r != nil {
		loaded, err := h.rideRepo.FindStopsByRideID(r.ID)
		if err != nil {
			respondRepo(c, err, "", "", "failed to load ride stops")
			return
		}
		stops = loaded
	}

	c.JSON(http.StatusOK, gin.H{"ride": ride, "stops": stops})
}

// GetRideByID godoc
//
//	@Summary	Get a ride by ID
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	RideWithStopsResponse
//	@Failure	404	{object}	ErrorResponse	"Ride not found"
//	@Router		/api/v1/rides/{id} [get]
func (h *RideHandler) GetRideByID(c *gin.Context) {
	id := c.Param("id")
	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		respondRepo(c, err, "ride not found", "", "failed to load ride")
		return
	}

	// The itinerary is part of the answer, not a nice-to-have: a ride rendered
	// with "stops": [] and no error is a confident, road-less itinerary, which
	// is worse than an honest 5xx. This is a read, so failing it cannot corrupt
	// anything, and GET is safe to retry.
	stops, err := h.rideRepo.FindStopsByRideID(id)
	if err != nil {
		respondRepo(c, err, "", "", "failed to load ride stops")
		return
	}

	c.JSON(http.StatusOK, gin.H{"ride": ride, "stops": stops})
}

// UpdateDestination godoc
//
//	@Summary		Change a ride's destination
//	@Description	Changes the final destination of a ride that is still open
//	@Description	(pending, accepted, driver_arrived or in_progress).
//	@Description	Only the ride's own rider may do this, and only the ride's own
//	@Description	rider. The booking-time fare is unchanged and no status transition
//	@Description	occurs: this is a data mutation. Re-request
//	@Description	`GET /api/v1/navigation/route` for the new leg.
//	@Tags			rides
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			id		path		string						true	"Ride ID"
//	@Param			body	body		changeDestinationRequest	true	"New destination"
//	@Success		200		{object}	RideWithStopsResponse
//	@Failure		400		{object}	ErrorResponse	"Malformed request body"
//	@Failure		404		{object}	ErrorResponse	"Ride not found"
//	@Failure		409		{object}	ErrorResponse	"Ride destination can no longer be changed"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Failed to update ride destination"
//	@Router			/api/v1/rides/{id}/destination [put]
func (h *RideHandler) UpdateDestination(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var req changeDestinationRequest
	if !bindJSON(c, &req, "") {
		return
	}
	if *req.Lat < -90 || *req.Lat > 90 || *req.Lng < -180 || *req.Lng > 180 {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "lat/lng out of range", nil)
		return
	}

	dest := model.RideStop{
		Kind:    model.DestinationKind,
		Lat:     *req.Lat,
		Lng:     *req.Lng,
		Address: req.Address,
	}

	ride, err := h.rideService.ChangeDestination(c.Param("id"), userID.(string), dest)
	if err != nil {
		// Exactly two 4xx outcomes exist here, and both are the caller's own
		// doing: no such ride (or not theirs — see the sentinel's doc), and a
		// ride whose itinerary is closed. Everything else, including a dead
		// database, must reach the rider as a 5xx: the apps react to any error
		// status by falling back, and a 4xx would read as "your request was
		// wrong" when in fact nothing was persisted.
		switch {
		case errors.Is(err, service.ErrNotRideRider), errors.Is(err, repository.ErrNotFound):
			fail(c, http.StatusNotFound, "NOT_FOUND", "ride not found", err)
		case errors.Is(err, service.ErrDestinationLocked), errors.Is(err, repository.ErrConflict):
			fail(c, http.StatusConflict, "CONFLICT",
				"ride destination can no longer be changed", err)
		default:
			fail(c, http.StatusInternalServerError, "INTERNAL",
				"failed to update ride destination", err)
		}
		return
	}

	stops, err := h.rideRepo.FindStopsByRideID(ride.ID)
	if err != nil {
		// The write is committed, so this 5xx is honest but must stay SAFE to
		// retry: PUT of an absolute destination is idempotent, so a retry
		// re-applies the same destination and cannot double-apply or duplicate
		// a stop. Returning the ride with "stops": [] instead would tell the
		// rider their itinerary is empty when it is not.
		log.Printf("ride %s: destination changed but stops could not be reloaded: %v", ride.ID, err)
		fail(c, http.StatusInternalServerError, "INTERNAL",
			"ride destination was changed but its stops could not be loaded", err)
		return
	}

	c.JSON(http.StatusOK, gin.H{"ride": ride, "stops": stops})
}

// GetRideHistory godoc
//
//	@Summary		List ride history
//	@Description	Returns a paginated list of past rides for the current rider or driver.
//	@Description	`stops` is a sibling map of ride id to that ride's ordered
//	@Description	itinerary, loaded in one query; `rides` is unchanged.
//	@Tags			rides
//	@Produce		json
//	@Security		BearerAuth
//	@Param			page		query		int	false	"Page number"				default(1)
//	@Param			per_page	query		int	false	"Items per page (max 50)"	default(20)
//	@Success		200			{object}	RideListResponse
//	@Failure		500			{object}	ErrorResponse	"Query failed"
//	@Router			/api/v1/rides/history [get]
func (h *RideHandler) GetRideHistory(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	perPage, _ := strconv.Atoi(c.DefaultQuery("per_page", "20"))
	if page < 1 {
		page = 1
	}
	if perPage < 1 || perPage > 50 {
		perPage = 20
	}
	offset := (page - 1) * perPage

	var rides interface{}
	var total int
	var err error

	if role == "rider" {
		rides, total, err = h.rideRepo.FindRidesByRider(userID.(string), perPage, offset)
	} else {
		rides, total, err = h.rideRepo.FindRidesByDriver(userID.(string), perPage, offset)
	}

	if err != nil {
		respondRepo(c, err, "rides not found", "", "failed to load ride history")
		return
	}

	totalPages := (total + perPage - 1) / perPage

	// The itinerary of every ride on the page, in ONE query. The response is
	// unchanged (`rides` stays a flat array of ride objects) and each ride's
	// stops arrive as a sibling `stops` array keyed by ride id, so an older
	// client sees exactly what it saw before.
	stopsByRide := map[string][]model.RideStop{}
	if rideList, ok := rides.([]model.Ride); ok && len(rideList) > 0 {
		ids := make([]string, 0, len(rideList))
		for i := range rideList {
			ids = append(ids, rideList[i].ID)
		}
		loaded, err := h.rideRepo.FindStopsByRideIDs(ids)
		if err != nil {
			respondRepo(c, err, "", "", "failed to load ride stops")
			return
		}
		stopsByRide = loaded
	}

	c.JSON(http.StatusOK, gin.H{
		"rides":       rides,
		"total":       total,
		"page":        page,
		"per_page":    perPage,
		"total_pages": totalPages,
		"stops":       stopsByRide,
	})
}

// GetRatings godoc
//
//	@Summary		List submitted ratings
//	@Description	Returns a paginated list of ratings the current rider or driver submitted.
//	@Tags			rides
//	@Produce		json
//	@Security		BearerAuth
//	@Param			page		query		int	false	"Page number"				default(1)
//	@Param			per_page	query		int	false	"Items per page (max 50)"	default(20)
//	@Success		200			{object}	RatingListResponse
//	@Failure		500			{object}	ErrorResponse	"Query failed"
//	@Router			/api/v1/rider/ratings [get]
//	@Router			/api/v1/driver/ratings [get]
func (h *RideHandler) GetRatings(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	perPage, _ := strconv.Atoi(c.DefaultQuery("per_page", "20"))
	if page < 1 {
		page = 1
	}
	if perPage < 1 || perPage > 50 {
		perPage = 20
	}
	offset := (page - 1) * perPage

	raterRole := "rider"
	if role == "driver" {
		raterRole = "driver"
	}

	ratings, total, err := h.rideRepo.FindRatingsByRater(userID.(string), raterRole, perPage, offset)
	if err != nil {
		respondRepo(c, err, "ratings not found", "", "failed to load ratings")
		return
	}

	items := make([]RatingItem, 0, len(ratings))
	for _, r := range ratings {
		items = append(items, RatingItem{
			ID:        r.ID,
			RideID:    r.RideID,
			RaterRole: r.RaterRole,
			Score:     r.Score,
			Comment:   r.Comment,
			CreatedAt: r.CreatedAt,
		})
	}

	totalPages := (total + perPage - 1) / perPage

	c.JSON(http.StatusOK, gin.H{
		"ratings":     items,
		"total":       total,
		"page":        page,
		"per_page":    perPage,
		"total_pages": totalPages,
	})
}

// CancelRide godoc
//
//	@Summary	Cancel a ride
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	RideResponse
//	@Failure	400	{object}	ErrorResponse	"Ride cannot be cancelled"
//	@Router		/api/v1/rides/{id}/cancel [post]
func (h *RideHandler) CancelRide(c *gin.Context) {
	id := c.Param("id")
	actor, _ := c.Get("role")

	ride, err := h.rideService.CancelRide(id, actor.(string))
	if err != nil {
		fail(c, http.StatusBadRequest, "BAD_REQUEST", "ride cannot be cancelled", err)
		return
	}

	c.JSON(http.StatusOK, gin.H{"ride": ride})
}

// AdvanceStatus godoc
//
//	@Summary	Advance a ride to the next status
//	@Tags		rides
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id		path		string					true	"Ride ID"
//	@Param		body	body		updateRideStatusRequest	true	"New status"
//	@Success	200		{object}	RideResponse
//	@Failure	400		{object}	ErrorResponse	"Invalid status transition"
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/rides/{id}/status [put]
func (h *RideHandler) AdvanceStatus(c *gin.Context) {
	id := c.Param("id")
	actor, _ := c.Get("role")

	var req updateRideStatusRequest
	if !bindJSON(c, &req, "") {
		return
	}

	ride, err := h.rideService.AdvanceStatus(id, req.Status, actor.(string))
	if err != nil {
		fail(c, http.StatusBadRequest, "BAD_REQUEST", "invalid status transition", err)
		return
	}

	c.JSON(http.StatusOK, gin.H{"ride": ride})
}

// RateRide godoc
//
//	@Summary		Rate a completed ride
//	@Description	Submits a 1-5 rating for the other party on a completed ride.
//	@Tags			rides
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			id		path		string			true	"Ride ID"
//	@Param			body	body		rateRideRequest	true	"Rating payload"
//	@Success		200		{object}	MessageResponse
//	@Failure		400		{object}	ErrorResponse	"Invalid rating"
//	@Failure		404		{object}	ErrorResponse	"Ride not found"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Router			/api/v1/rides/{id}/rate [post]
func (h *RideHandler) RateRide(c *gin.Context) {
	id := c.Param("id")
	actor, _ := c.Get("role")
	userID, _ := c.Get("user_id")

	var req rateRideRequest
	if !bindJSON(c, &req, "") {
		return
	}

	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		respondRepo(c, err, "ride not found", "", "failed to load ride")
		return
	}

	rateeID := ride.DriverID
	raterRole := "rider"
	if actor == "driver" {
		rateeID = &ride.RiderID
		raterRole = "driver"
	}

	if rateeID == nil {
		fail(c, http.StatusBadRequest, "BAD_REQUEST", "no ratee found", nil)
		return
	}

	if err := h.rideService.Rate(id, raterRole, userID.(string), *rateeID, req.Score, req.Comment); err != nil {
		fail(c, http.StatusBadRequest, "BAD_REQUEST", "invalid rating", err)
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "rating submitted"})
}

// AcceptRide godoc
//
//	@Summary	Accept a dispatched ride offer
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	MessageResponse
//	@Failure	400	{object}	ErrorResponse	"Cannot accept ride"
//	@Failure	409	{object}	ErrorResponse	"Ride already taken"
//	@Router		/api/v1/rides/{id}/accept [post]
func (h *RideHandler) AcceptRide(c *gin.Context) {
	id := c.Param("id")
	driverID, _ := c.Get("user_id")

	if err := h.dispatchService.AcceptRide(id, driverID.(string)); err != nil {
		if _, ok := err.(*service.DispatchConflictError); ok {
			fail(c, http.StatusConflict, "CONFLICT", "ride already accepted", err)
			return
		}
		fail(c, http.StatusBadRequest, "BAD_REQUEST", "cannot accept ride", err)
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "ride accepted"})
}

// GetRideReceipt godoc
//
//	@Summary	Get the fare breakdown for a ride
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	RideReceiptResponse
//	@Failure	404	{object}	ErrorResponse	"Ride not found"
//	@Router		/api/v1/rides/{id}/receipt [get]
func (h *RideHandler) GetRideReceipt(c *gin.Context) {
	id := c.Param("id")
	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		respondRepo(c, err, "ride not found", "", "failed to load ride")
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"receipt": gin.H{
			"base_fare":        ride.BaseFare,
			"distance_fare":    ride.DistanceFare,
			"time_fare":        ride.TimeFare,
			"surge_multiplier": ride.SurgeMultiplier,
			"total":            ride.TotalFare,
		},
	})
}

// TipDriver godoc
//
//	@Summary	Tip a driver (stub)
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	StubResponse
//	@Router		/api/v1/rides/{id}/tip [post]
func (h *RideHandler) TipDriver(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "stub",
		"message": "Payment integration pending",
	})
}
