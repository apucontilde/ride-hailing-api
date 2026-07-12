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

func (h *DriverHandler) Register(c *gin.Context) {
	userID, _ := c.Get("user_id")

	user, _ := h.userRepo.FindByID(userID.(string))
	user.Role = "driver"
	h.userRepo.UpdateUser(user)

	driver := &model.Driver{
		UserID:           user.ID,
		Status:           "offline",
		OnboardingStatus: "documents_submitted",
	}
	h.userRepo.CreateDriver(driver)

	c.JSON(http.StatusCreated, gin.H{"driver": driver})
}

func (h *DriverHandler) GetProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	driver, err := h.userRepo.FindDriverByID(userID.(string))
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": gin.H{"code": "NOT_FOUND", "message": "driver not found"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

func (h *DriverHandler) UpdateProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body struct {
		FirstName string `json:"first_name"`
		LastName  string `json:"last_name"`
		PhotoURL  string `json:"photo_url"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	driver, _ := h.userRepo.FindDriverByID(userID.(string))
	driver.FirstName = body.FirstName
	driver.LastName = body.LastName
	driver.PhotoURL = body.PhotoURL
	h.userRepo.UpdateDriver(driver)
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

func (h *DriverHandler) UpdateStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body struct {
		Status string `json:"status" binding:"required"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	driver, _ := h.userRepo.FindDriverByID(userID.(string))
	driver.Status = body.Status
	h.userRepo.UpdateDriver(driver)
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}
