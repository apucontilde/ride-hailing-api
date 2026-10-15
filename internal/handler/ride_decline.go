package handler

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/service"
)

// DeclineRide godoc
//
//	@Summary	Decline a dispatched ride offer
//	@Tags		rides
//	@Produce	json
//	@Security	BearerAuth
//	@Param		id	path		string	true	"Ride ID"
//	@Success	200	{object}	MessageResponse
//	@Failure	400	{object}	ErrorResponse	"Malformed request"
//	@Failure	404	{object}	ErrorResponse	"No active offer to decline"
//	@Failure	422	{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/driver/rides/{id}/decline [post]
func (h *RideHandler) DeclineRide(c *gin.Context) {
	id := c.Param("id")
	driverID, _ := c.Get("user_id")

	if !uuidRE.MatchString(id) {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR", "invalid ride_id",
			fmt.Errorf("[rides] decline: invalid ride_id value=%q", id))
		return
	}

	ride, err := h.rideRepo.FindByID(id)
	if err != nil {
		respondRepo(c, err, "ride not found", "", "failed to load ride")
		return
	}
	_ = ride

	if err := h.dispatchService.DeclineOffer(driverID.(string), id); err != nil {
		if errors.Is(err, service.ErrNoActiveOffer) {
			fail(c, http.StatusNotFound, "NOT_FOUND", "no active offer to decline", err)
			return
		}
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to decline offer", err)
		return
	}

	c.JSON(http.StatusOK, gin.H{"status": "declined"})
}
