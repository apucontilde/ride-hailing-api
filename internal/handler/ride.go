package handler

import (
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

	go h.dispatchService.Dispatch(ride)

	c.JSON(http.StatusCreated, gin.H{"ride": ride})
}

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

func (h *RideHandler) GetRideByID(c *gin.Context) {
	id := c.Param("id")
	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "ride not found"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ride": ride})
}

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

func (h *RideHandler) AdvanceStatus(c *gin.Context) {
	id := c.Param("id")
	actor, _ := c.Get("role")

	var req struct {
		Status string `json:"status" binding:"required"`
	}
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

func (h *RideHandler) RateRide(c *gin.Context) {
	id := c.Param("id")
	actor, _ := c.Get("role")
	userID, _ := c.Get("user_id")

	var req struct {
		Score   int    `json:"score" binding:"required"`
		Comment string `json:"comment"`
	}
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

func (h *RideHandler) TipDriver(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "stub",
		"message": "Payment integration pending",
	})
}
