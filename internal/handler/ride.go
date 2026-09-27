package handler

import (
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

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
//	@Success		201		{object}	RideResponse
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Failed to create ride"
//	@Router			/api/v1/rides [post]
func (h *RideHandler) CreateRide(c *gin.Context) {
	riderID, _ := c.Get("user_id")

	var req rideRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	vehicleType := req.VehicleType
	if vehicleType == "" {
		vehicleType = "sedan"
	}

	idempotencyKey, _ := c.Get("idempotency_key")
	idKey, _ := idempotencyKey.(string)

	ride, err := h.rideService.RequestRide(riderID.(string),
		req.PickupLat, req.PickupLng,
		req.DropoffLat, req.DropoffLng,
		req.PickupAddress, req.DropoffAddress,
		vehicleType, idKey)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": err.Error()}})
		return
	}

	go func() {
		if err := h.dispatchService.Dispatch(ride); err != nil {
			log.Printf("ride %s: dispatch failed: %v", ride.ID, err)
		}
	}()

	c.JSON(http.StatusCreated, gin.H{"ride": ride})
}

// GetCurrentRide godoc
//
//	@Summary		Get the current ride for the authenticated user
//	@Description	Returns the active ride for the current rider or driver, or `null`.
//	@Tags			rides
//	@Produce		json
//	@Security		BearerAuth
//	@Success		200	{object}	RideResponse
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
		c.JSON(http.StatusOK, gin.H{"ride": nil})
		return
	}

	c.JSON(http.StatusOK, gin.H{"ride": ride})
}

// GetRideByID godoc
//
//	@Summary	Get a ride by ID
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	RideResponse
//	@Failure	404	{object}	ErrorResponse	"Ride not found"
//	@Router		/api/v1/rides/{id} [get]
func (h *RideHandler) GetRideByID(c *gin.Context) {
	id := c.Param("id")
	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "ride not found"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ride": ride})
}

// GetRideHistory godoc
//
//	@Summary		List ride history
//	@Description	Returns a paginated list of past rides for the current rider or driver.
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
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": err.Error()}})
		return
	}

	totalPages := (total + perPage - 1) / perPage

	c.JSON(http.StatusOK, gin.H{
		"rides":       rides,
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
		c.JSON(http.StatusBadRequest, gin.H{"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()}})
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
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	ride, err := h.rideService.AdvanceStatus(id, req.Status, actor.(string))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()}})
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
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "ride not found"}})
		return
	}

	rateeID := ride.DriverID
	raterRole := "rider"
	if actor == "driver" {
		rateeID = &ride.RiderID
		raterRole = "driver"
	}

	if rateeID == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": gin.H{"code": "BAD_REQUEST", "message": "no ratee found"}})
		return
	}

	if err := h.rideService.Rate(id, raterRole, userID.(string), *rateeID, req.Score, req.Comment); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()}})
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
			c.JSON(http.StatusConflict, gin.H{"error": gin.H{"code": "CONFLICT", "message": err.Error()}})
			return
		}
		c.JSON(http.StatusBadRequest, gin.H{"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()}})
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
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "ride not found"}})
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
