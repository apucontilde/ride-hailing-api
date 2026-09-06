package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
)

type RiderHandler struct {
	riderService *service.RiderService
	userRepo     repository.UserRepository
}

func NewRiderHandler(riderService *service.RiderService, userRepo repository.UserRepository) *RiderHandler {
	return &RiderHandler{riderService: riderService, userRepo: userRepo}
}

type updateRiderRequest struct {
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	PhotoURL  string `json:"photo_url"`
	Phone     string `json:"phone"`
}

type updateStatusRequest struct {
	Status string `json:"status" binding:"required"`
}

// GetProfile godoc
//	@Summary	Get the rider profile
//	@Tags		rider
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	RiderProfileResponse
//	@Failure	404	{object}	ErrorResponse	"Rider not found"
//	@Router		/api/v1/rider/me [get]
func (h *RiderHandler) GetProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	rider, err := h.userRepo.FindRiderByID(userID.(string))
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "rider not found"}})
		return
	}
	user, _ := h.userRepo.FindByID(userID.(string))
	c.JSON(http.StatusOK, gin.H{
		"user":  sanitizeUser(user),
		"rider": rider,
	})
}

// UpdateProfile godoc
//	@Summary	Update the rider profile
//	@Tags		rider
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		updateRiderRequest	true	"Profile fields to update"
//	@Success	200		{object}	RiderResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/rider/me [put]
func (h *RiderHandler) UpdateProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body updateRiderRequest
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	rider, _ := h.userRepo.FindRiderByID(userID.(string))
	rider.FirstName = body.FirstName
	rider.LastName = body.LastName
	rider.PhotoURL = body.PhotoURL
	h.userRepo.UpdateRider(rider)

	if body.Phone != "" {
		user, _ := h.userRepo.FindByID(userID.(string))
		user.Phone = body.Phone
		h.userRepo.UpdateUser(user)
	}

	c.JSON(http.StatusOK, gin.H{"rider": rider})
}

// UpdateStatus godoc
//	@Summary	Update the rider status
//	@Tags		rider
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		updateStatusRequest	true	"New status (e.g. idle)"
//	@Success	200		{object}	RiderResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/rider/me/status [put]
func (h *RiderHandler) UpdateStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body updateStatusRequest
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	rider, _ := h.userRepo.FindRiderByID(userID.(string))
	rider.Status = body.Status
	h.userRepo.UpdateRider(rider)
	c.JSON(http.StatusOK, gin.H{"rider": rider})
}

// DeleteAccount godoc
//	@Summary		Deactivate the rider account
//	@Description	Soft-deletes the authenticated user's account.
//	@Tags			rider
//	@Produce		json
//	@Security		BearerAuth
//	@Success		200	{object}	MessageResponse
//	@Router			/api/v1/rider/me [delete]
func (h *RiderHandler) DeleteAccount(c *gin.Context) {
	userID, _ := c.Get("user_id")
	h.userRepo.SoftDeleteUser(userID.(string))
	c.JSON(http.StatusOK, gin.H{"message": "account deactivated"})
}

func sanitizeUser(u *model.User) gin.H {
	return gin.H{
		"id":    u.ID,
		"email": u.Email,
		"phone": u.Phone,
		"role":  u.Role,
		"status": u.Status,
	}
}
