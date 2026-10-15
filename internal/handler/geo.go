package handler

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

// ArrivalEvaluator is the narrow seam the geo hot path uses to run the
// proximity arrival geofence (api_plans/[arrival]_proximity_arrival_geofence.md).
// *service.RideService implements it. It returns the additive nearby fields to
// carry on the driver.location event; it never returns an error, because a
// geofence failure must not fail the location update.
type ArrivalEvaluator interface {
	EvaluateArrival(ride *model.Ride, driverID string, lat, lng float64) (nearPickup bool, distanceToPickupM float64)
}

type GeoHandler struct {
	geoRepo  repository.GeoRepository
	rideRepo repository.RideRepository
	wsHub    *websocket.Hub
	arrival  ArrivalEvaluator
}

func NewGeoHandler(geoRepo repository.GeoRepository, rideRepo repository.RideRepository, wsHub *websocket.Hub, arrival ArrivalEvaluator) *GeoHandler {
	return &GeoHandler{geoRepo: geoRepo, rideRepo: rideRepo, wsHub: wsHub, arrival: arrival}
}

type locationUpdate struct {
	Lat     float64 `json:"lat" binding:"required"`
	Lng     float64 `json:"lng" binding:"required"`
	Heading float64 `json:"heading"`
	Speed   float64 `json:"speed"`
}

// findActiveRide resolves the caller's active ride for the derive-after-write
// path (track points + proximity arrival geofence). It enforces the plan §2.5
// honesty invariant: "no active ride" (ErrNotFound) is benign and silent, but
// any OTHER repository error is logged and treated the same way — no active
// ride, so the geofence is skipped. A down ride repo must never fabricate an
// arrival, and a lookup failure must never fail the location update.
func (h *GeoHandler) findActiveRide(driverID string) *model.Ride {
	ride, err := h.rideRepo.FindCurrentRideByDriver(driverID)
	if err != nil {
		if !errors.Is(err, repository.ErrNotFound) {
			log.Printf("driver %s: failed to load active ride for location update: %v", driverID, err)
		}
		return nil
	}
	return ride
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
	if !bindJSON(c, &req, "") {
		return
	}

	if req.Lat < -90 || req.Lat > 90 || req.Lng < -180 || req.Lng > 180 {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "lat/lng out of range", nil)
		return
	}

	if err := h.geoRepo.UpsertDriverPosition(driverID.(string), req.Lat, req.Lng, req.Heading, req.Speed, "online"); err != nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to update location", err)
		return
	}

	activeRide := h.findActiveRide(driverID.(string))
	if activeRide != nil {
		// Actual driven distance seam (migration 021,
		// api_plans/[tracking]_actual_trip_distance.md): while the ride is
		// in_progress, persist the fix as part of the ride's trace. Only
		// started→completed counts; the accepted/driver_arrived legs (en route
		// to pickup) are deliberately not part of the trip distance. The append
		// is best-effort: a trace write must never fail the location update, and
		// the distance is summed (with its noise gate) on the completed
		// transition, not here. A write failure costs distance accuracy, not the
		// live position stream.
		if activeRide.Status == "in_progress" {
			if terr := h.rideRepo.InsertRideTrackPoint(activeRide.ID, req.Lat, req.Lng, time.Now()); terr != nil {
				log.Printf("ride %s: failed to record track point: %v", activeRide.ID, terr)
			}
		}

		h.emitDriverLocation(activeRide, driverID.(string), req)
	}

	c.Status(http.StatusNoContent)
}

// emitDriverLocation builds the driver.location event for one fix and streams it
// to the ride's rider. It runs the proximity arrival geofence for the fix first
// (which may advance the ride to driver_arrived and broadcast ride.updated) and
// carries the evaluator's additive nearby fields on the event. It never fails
// the location update: the evaluator swallows its own errors and the hub send is
// best-effort.
func (h *GeoHandler) emitDriverLocation(ride *model.Ride, driverID string, fix locationUpdate) {
	data := websocket.DriverLocationData{
		RideID:   ride.ID,
		DriverID: driverID,
		Lat:      fix.Lat,
		Lng:      fix.Lng,
		Heading:  fix.Heading,
		Speed:    fix.Speed,
	}
	if h.arrival != nil {
		data.NearPickup, data.DistanceToPickupM = h.arrival.EvaluateArrival(ride, driverID, fix.Lat, fix.Lng)
	}
	h.wsHub.SendToUser(ride.RiderID, websocket.OutgoingMessage{
		Type: "driver.location",
		Data: data,
	})
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
	if !bindJSON(c, &reqs, "") {
		return
	}

	for _, r := range reqs {
		if r.Lat < -90 || r.Lat > 90 || r.Lng < -180 || r.Lng > 180 {
			fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "lat/lng out of range", nil)
			return
		}
		if err := h.geoRepo.UpsertDriverPosition(driverID.(string), r.Lat, r.Lng, r.Heading, r.Speed, "online"); err != nil {
			fail(c, http.StatusInternalServerError, "INTERNAL", "failed to update location", err)
			return
		}
	}

	// Batch-path geofence (plan §3 D7): the loop above upserts every fix
	// position-only; the arrival/nearby evaluation runs ONCE on the FINAL fix —
	// one evaluation, one possible transition, one driver.location event. The
	// intermediate fixes stay position-only, exactly as before.
	if len(reqs) > 0 {
		last := reqs[len(reqs)-1]
		if activeRide := h.findActiveRide(driverID.(string)); activeRide != nil {
			h.emitDriverLocation(activeRide, driverID.(string), last)
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
	if !bindJSON(c, &req, "") {
		return
	}

	if err := h.geoRepo.UpsertRiderPosition(riderID.(string), req.Lat, req.Lng); err != nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to update location", err)
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
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid lat", err)
		return
	}
	lng, err := strconv.ParseFloat(c.Query("lng"), 64)
	if err != nil {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid lng", err)
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
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to query drivers", err)
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
		respondRepo(c, err, "driver location not found", "", "failed to load driver location")
		return
	}
	c.JSON(http.StatusOK, loc)
}
