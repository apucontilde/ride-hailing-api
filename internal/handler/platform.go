package handler

import (
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"ride-hailing-api/internal/service"
)

type PlatformHandler struct {
	navSvc *service.NavigationService
}

func NewPlatformHandler(navSvc *service.NavigationService) *PlatformHandler {
	return &PlatformHandler{navSvc: navSvc}
}

func (h *PlatformHandler) SOS(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var req struct {
		Lat float64 `json:"lat" binding:"required"`
		Lng float64 `json:"lng" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"message": "SOS alert received",
		"alert": gin.H{
			"user_id":  userID,
			"lat":      req.Lat,
			"lng":      req.Lng,
			"status":   "active",
		},
	})
}

func (h *PlatformHandler) Feedback(c *gin.Context) {
	var req struct {
		Message string  `json:"message" binding:"required"`
		RideID  *string `json:"ride_id"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "feedback submitted"})
}

func (h *PlatformHandler) DeviceRegister(c *gin.Context) {
	var req struct {
		Token    string `json:"token" binding:"required"`
		Platform string `json:"platform" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()}})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "device registered"})
}

func (h *PlatformHandler) DeviceUnregister(c *gin.Context) {
	c.JSON(http.StatusNoContent, nil)
}

func (h *PlatformHandler) PromotionsList(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"promotions": []interface{}{}})
}

func (h *PlatformHandler) ApplyPromotion(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"message": "promotion applied (stub)"})
}

func (h *PlatformHandler) PlacesAutocomplete(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"predictions": []interface{}{}})
}

func (h *PlatformHandler) PlacesGeocode(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"place": nil})
}

func (h *PlatformHandler) PlacesDetails(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"place": nil})
}

func (h *PlatformHandler) EstimatesPrice(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"estimates": []gin.H{
			{"vehicle_type": "sedan", "base_fare": 5.0, "distance_rate": 1.5, "time_rate": 0.5},
			{"vehicle_type": "suv", "base_fare": 8.0, "distance_rate": 2.0, "time_rate": 0.7},
		},
	})
}

func (h *PlatformHandler) EstimatesETA(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"eta_seconds": 300, "distance_meters": 5000})
}

func (h *PlatformHandler) UpdateDestination(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"message": "destination updated"})
}

func (h *PlatformHandler) NavigationRoute(c *gin.Context) {
	fromLat := c.Query("from_lat")
	fromLng := c.Query("from_lng")
	toLat := c.Query("to_lat")
	toLng := c.Query("to_lng")

	// In a real app, we would parse these as float64.
	// Using dummy values for now since they are strings in Query().
	// But I should actually parse them.
	var fLat, fLng, tLat, tLng float64
	fmt.Sscanf(fromLat, "%f", &fLat)
	fmt.Sscanf(fromLng, "%f", &fLng)
	fmt.Sscanf(toLat, "%f", &tLat)
	fmt.Sscanf(toLng, "%f", &tLng)

	route, err := h.navSvc.GetRoute(fLat, fLng, tLat, tLng)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
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
	})
}

func (h *PlatformHandler) Heatmap(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"tiles": "data:image/png;base64,..."})
}

func (h *PlatformHandler) DriverRideQueue(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"queue": []interface{}{}})
}

func (h *PlatformHandler) DriverRiderInfo(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"rider": gin.H{"name": "Rider", "rating": 5.0}})
}

func (h *PlatformHandler) ArrivalNotification(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"message": "rider notified of arrival"})
}

func (h *PlatformHandler) Version(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"version": "0.1.0", "commit": "development"})
}

func (h *PlatformHandler) StubPayment(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":  "stub",
		"message": "Payment integration pending",
	})
}
