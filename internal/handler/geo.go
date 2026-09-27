package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

type GeoHandler struct {
	geoRepo  repository.GeoRepository
	rideRepo repository.RideRepository
	wsHub    *websocket.Hub
}

func NewGeoHandler(geoRepo repository.GeoRepository, rideRepo repository.RideRepository, wsHub *websocket.Hub) *GeoHandler {
	return &GeoHandler{geoRepo: geoRepo, rideRepo: rideRepo, wsHub: wsHub}
}

type locationUpdate struct {
	Lat     float64 `json:"lat" binding:"required"`
	Lng     float64 `json:"lng" binding:"required"`
	Heading float64 `json:"heading"`
	Speed   float64 `json:"speed"`
}

// UpdateDriverLocation godoc
//
//	@Summary		Update a driver's live location
//	@Description	Upserts the driver position and streams it to the rider over WebSocket.
//	@Tags			geo
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			body	body	locationUpdate	true	"Location update"
//	@Success		204		"No content"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Update failed"
//	@Router			/api/v1/geo/driver/location [put]
func (h *GeoHandler) UpdateDriverLocation(c *gin.Context) {
	driverID, _ := c.Get("user_id")
	var req locationUpdate
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	if req.Lat < -90 || req.Lat > 90 || req.Lng < -180 || req.Lng > 180 {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "lat/lng out of range"}})
		return
	}

	if err := h.geoRepo.UpsertDriverPosition(driverID.(string), req.Lat, req.Lng, req.Heading, req.Speed, "online"); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to update location"}})
		return
	}

	activeRide, err := h.rideRepo.FindCurrentRideByDriver(driverID.(string))
	if err == nil {
		h.wsHub.SendToUser(activeRide.RiderID, websocket.OutgoingMessage{
			Type: "driver.location",
			Data: websocket.DriverLocationData{
				RideID:   activeRide.ID,
				DriverID: driverID.(string),
				Lat:      req.Lat,
				Lng:      req.Lng,
				Heading:  req.Heading,
				Speed:    req.Speed,
			},
		})
	}

	c.Status(http.StatusNoContent)
}

// UpdateDriverLocationBatch godoc
//
//	@Summary	Batch update a driver's live location
//	@Tags		geo
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body	[]locationUpdate	true	"List of location updates"
//	@Success	204		"No content"
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/geo/driver/location/batch [put]
func (h *GeoHandler) UpdateDriverLocationBatch(c *gin.Context) {
	driverID, _ := c.Get("user_id")
	var reqs []locationUpdate
	if err := c.ShouldBindJSON(&reqs); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	for _, r := range reqs {
		if r.Lat < -90 || r.Lat > 90 || r.Lng < -180 || r.Lng > 180 {
			c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": "lat/lng out of range"}})
			return
		}
		if err := h.geoRepo.UpsertDriverPosition(driverID.(string), r.Lat, r.Lng, r.Heading, r.Speed, "online"); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to update location"}})
			return
		}
	}

	c.Status(http.StatusNoContent)
}

// UpdateRiderLocation godoc
//
//	@Summary	Update a rider's live location
//	@Tags		geo
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body	locationUpdate	true	"Location update"
//	@Success	204		"No content"
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/geo/rider/location [put]
func (h *GeoHandler) UpdateRiderLocation(c *gin.Context) {
	riderID, _ := c.Get("user_id")
	var req locationUpdate
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	if err := h.geoRepo.UpsertRiderPosition(riderID.(string), req.Lat, req.Lng); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to update location"}})
		return
	}
	c.Status(http.StatusNoContent)
}

// GetNearbyDrivers godoc
//
//	@Summary		Find nearby drivers
//	@Description	Returns online drivers within a radius of the given coordinates.
//	@Tags			geo
//	@Produce		json
//	@Security		BearerAuth
//	@Param			lat		query		number	true	"Latitude"
//	@Param			lng		query		number	true	"Longitude"
//	@Param			radius	query		number	false	"Search radius in meters (default 5000)"	default(5000)
//	@Param			limit	query		int		false	"Maximum results (max 50)"					default(20)
//	@Success		200		{object}	NearbyDriversResponse
//	@Failure		422		{object}	ErrorResponse	"Invalid parameters"
//	@Failure		500		{object}	ErrorResponse	"Query failed"
//	@Router			/api/v1/geo/nearby-drivers [get]
func (h *GeoHandler) GetNearbyDrivers(c *gin.Context) {
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

	radius := 5000.0
	if r := c.Query("radius"); r != "" {
		radius, _ = strconv.ParseFloat(r, 64)
	}

	limit := 20
	if l := c.Query("limit"); l != "" {
		limit, _ = strconv.Atoi(l)
	}
	if limit > 50 {
		limit = 50
	}

	drivers, err := h.geoRepo.FindNearbyDrivers(lat, lng, radius, limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to query drivers"}})
		return
	}

	c.JSON(http.StatusOK, gin.H{"drivers": drivers})
}

// GetDriverLocation godoc
//
//	@Summary	Get a driver's current location
//	@Tags		geo
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Driver ID"
//	@Success	200	{object}	DriverLocationResponse
//	@Failure	404	{object}	ErrorResponse	"Driver location not found"
//	@Router		/api/v1/drivers/{id}/location [get]
func (h *GeoHandler) GetDriverLocation(c *gin.Context) {
	driverID := c.Param("id")
	loc, err := h.geoRepo.GetDriverLocation(driverID)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "driver location not found"}})
		return
	}
	c.JSON(http.StatusOK, loc)
}
