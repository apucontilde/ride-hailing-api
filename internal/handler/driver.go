package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type DriverHandler struct {
	userRepo repository.UserRepository
}

func NewDriverHandler(userRepo repository.UserRepository) *DriverHandler {
	return &DriverHandler{userRepo: userRepo}
}

type updateDriverRequest struct {
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	PhotoURL  string `json:"photo_url"`
}

// Register godoc
//
//	@Summary		Register the authenticated user as a driver
//	@Description	Promotes the current user to the driver role and creates a driver profile.
//	@Tags			driver
//	@Produce		json
//	@Security		BearerAuth
//	@Success		201	{object}	DriverResponse
//	@Router			/api/v1/driver/register [post]
func (h *DriverHandler) Register(c *gin.Context) {
	userID, _ := c.Get("user_id")

	user, _ := h.userRepo.FindByID(userID.(string))
	user.Role = "driver"
	if err := h.userRepo.UpdateUser(user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to update user role"}})
		return
	}

	driver := &model.Driver{
		UserID:           user.ID,
		Status:           "offline",
		OnboardingStatus: "documents_submitted",
	}
	if err := h.userRepo.CreateDriver(driver); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to create driver profile"}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"driver": driver})
}

// GetProfile godoc
//
//	@Summary	Get the driver profile
//	@Tags		driver
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	DriverResponse
//	@Failure	404	{object}	ErrorResponse	"Driver not found"
//	@Router		/api/v1/driver/me [get]
func (h *DriverHandler) GetProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	driver, err := h.userRepo.FindDriverByID(userID.(string))
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "driver not found"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

// UpdateProfile godoc
//
//	@Summary	Update the driver profile
//	@Tags		driver
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		updateDriverRequest	true	"Profile fields to update"
//	@Success	200		{object}	DriverResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/driver/me [put]
func (h *DriverHandler) UpdateProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body updateDriverRequest
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	driver, _ := h.userRepo.FindDriverByID(userID.(string))
	driver.FirstName = body.FirstName
	driver.LastName = body.LastName
	driver.PhotoURL = body.PhotoURL
	if err := h.userRepo.UpdateDriver(driver); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to update driver profile"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

// UpdateStatus godoc
//
//	@Summary	Update the driver availability status
//	@Tags		driver
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		updateStatusRequest	true	"New status (e.g. online, offline)"
//	@Success	200		{object}	DriverResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/driver/me/status [put]
func (h *DriverHandler) UpdateStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body updateStatusRequest
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	driver, _ := h.userRepo.FindDriverByID(userID.(string))
	driver.Status = body.Status
	if err := h.userRepo.UpdateDriver(driver); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": gin.H{"code": "INTERNAL", "message": "failed to update driver status"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}
