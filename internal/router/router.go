package router

import (
	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/handler"
	"ride-hailing-api/internal/middleware"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
	"ride-hailing-api/internal/websocket"
)

func Setup(cfg *config.Config, db *sqlx.DB) *gin.Engine {
	return SetupWithRepos(cfg,
		repository.NewUserRepo(db),
		repository.NewRideRepo(db),
		repository.NewGeoRepo(db),
		db,
	)
}

func SetupWithRepos(cfg *config.Config, userRepo repository.UserRepository, rideRepo repository.RideRepository, geoRepo repository.GeoRepository, db *sqlx.DB) *gin.Engine {
	r := gin.Default()

	// Services
	authService := service.NewAuthService(cfg, userRepo)
	riderService := service.NewRiderService(userRepo)
	rideService := service.NewRideService(rideRepo, userRepo)
	dispatchService := service.NewDispatchService(rideRepo, geoRepo)

	// Handlers
	healthHandler := handler.NewHealthHandler(db)
	authHandler := handler.NewAuthHandler(authService)
	riderHandler := handler.NewRiderHandler(riderService, userRepo)
	driverHandler := handler.NewDriverHandler(userRepo)
	geoHandler := handler.NewGeoHandler(geoRepo)
	rideHandler := handler.NewRideHandler(rideService, dispatchService, rideRepo)
	platformHandler := handler.NewPlatformHandler()

	// Middleware
	authMw := middleware.AuthRequired(authService)
	generalRL := middleware.NewRateLimiter(cfg.RateLimitGeneral, cfg.RateLimitWindow)
	loginRL := middleware.NewRateLimiter(cfg.RateLimitLogin, cfg.RateLimitWindow)
	registerRL := middleware.NewRateLimiter(cfg.RateLimitRegister, cfg.RateLimitWindow)
	rideRL := middleware.NewRateLimiter(cfg.RateLimitRide, cfg.RateLimitWindow)
	idempotencyMw := middleware.Idempotency(db)

	// Health & debug
	r.GET("/health", healthHandler.Liveness)
	r.GET("/health/ready", healthHandler.Readiness)
	r.GET("/api/v1/version", platformHandler.Version)

	// Auth
	auth := r.Group("/api/v1/auth")
	auth.POST("/register", registerRL.Middleware(), authHandler.Register)
	auth.POST("/login", loginRL.Middleware(), authHandler.Login)
	auth.POST("/refresh", authMw, authHandler.Login)
	auth.POST("/logout", authMw, authHandler.Login)
	auth.POST("/forgot-password", loginRL.Middleware(), authHandler.Login)
	auth.POST("/reset-password", authMw, authHandler.Login)
	auth.POST("/verify-email", authMw, authHandler.Login)
	auth.POST("/verify-phone", authMw, authHandler.Login)
	auth.POST("/social", loginRL.Middleware(), authHandler.Login)

	// Rider
	rider := r.Group("/api/v1/rider")
	rider.Use(authMw, middleware.RequireRole("rider"))
	rider.GET("/me", riderHandler.GetProfile)
	rider.PUT("/me", riderHandler.UpdateProfile)
	rider.PUT("/me/status", riderHandler.UpdateStatus)
	rider.DELETE("/me", riderHandler.DeleteAccount)
	rider.GET("/me/preferences", platformHandler.StubPayment)
	rider.PUT("/me/preferences", platformHandler.StubPayment)
	rider.GET("/ratings", platformHandler.StubPayment)
	rider.GET("/favorites", platformHandler.StubPayment)
	rider.POST("/favorites", platformHandler.StubPayment)
	rider.DELETE("/favorites/:id", platformHandler.StubPayment)
	rider.GET("/payment-methods", platformHandler.StubPayment)
	rider.POST("/payment-methods", platformHandler.StubPayment)
	rider.DELETE("/payment-methods/:id", platformHandler.StubPayment)

	// Driver register (no role check — user must register first)
	r.POST("/api/v1/driver/register", authMw, driverHandler.Register)

	// Driver
	driver := r.Group("/api/v1/driver")
	driver.Use(authMw, middleware.RequireRole("driver"))
	driver.GET("/me", driverHandler.GetProfile)
	driver.PUT("/me", driverHandler.UpdateProfile)
	driver.PUT("/me/status", driverHandler.UpdateStatus)
	driver.GET("/me/documents", platformHandler.StubPayment)
	driver.POST("/me/documents", platformHandler.StubPayment)
	driver.GET("/me/vehicle", driverHandler.Register)
	driver.PUT("/me/vehicle", driverHandler.Register)
	driver.GET("/me/earnings", platformHandler.StubPayment)
	driver.GET("/ratings", platformHandler.StubPayment)

	// Driver rides
	driverRides := r.Group("/api/v1/driver/rides")
	driverRides.Use(authMw, middleware.RequireRole("driver"), rideRL.Middleware())
	driverRides.GET("/current", rideHandler.GetCurrentRide)
	driverRides.GET("/history", rideHandler.GetRideHistory)
	driverRides.GET("/queue", platformHandler.DriverRideQueue)
	driverRides.GET("/:id", rideHandler.GetRideByID)
	driverRides.GET("/:id/rider", platformHandler.DriverRiderInfo)
	driverRides.POST("/:id/accept", rideHandler.AcceptRide)
	driverRides.POST("/:id/decline", platformHandler.StubPayment)
	driverRides.PUT("/:id/status", rideHandler.AdvanceStatus)
	driverRides.POST("/:id/cancel", rideHandler.CancelRide)
	driverRides.POST("/:id/rate", rideHandler.RateRide)
	driverRides.POST("/:id/notify-arrival", platformHandler.ArrivalNotification)

	// Geo
	geo := r.Group("/api/v1/geo")
	geo.PUT("/driver/location", authMw, middleware.RequireRole("driver"), geoHandler.UpdateDriverLocation)
	geo.PUT("/driver/location/batch", authMw, middleware.RequireRole("driver"), geoHandler.UpdateDriverLocationBatch)
	geo.PUT("/rider/location", authMw, middleware.RequireRole("rider"), geoHandler.UpdateRiderLocation)
	geo.GET("/nearby-drivers", authMw, geoHandler.GetNearbyDrivers)
	geo.GET("/eta", authMw, platformHandler.EstimatesETA)
	geo.GET("/isochrone", authMw, platformHandler.StubPayment)

	// Rides
	rides := r.Group("/api/v1/rides")
	rides.Use(authMw, generalRL.Middleware())
	rides.POST("", middleware.RequireRole("rider"), idempotencyMw, rideHandler.CreateRide)
	rides.GET("/current", rideHandler.GetCurrentRide)
	rides.GET("/history", rideHandler.GetRideHistory)
	rides.GET("/:id", rideHandler.GetRideByID)
	rides.GET("/:id/receipt", rideHandler.GetRideReceipt)
	rides.POST("/:id/cancel", rideHandler.CancelRide)
	rides.POST("/:id/rate", rideHandler.RateRide)
	rides.POST("/:id/tip", rideHandler.TipDriver)
	rides.PUT("/:id/destination", platformHandler.UpdateDestination)

	// Navigation
	nav := r.Group("/api/v1/navigation")
	nav.Use(authMw)
	nav.GET("/route", platformHandler.NavigationRoute)

	// Places
	places := r.Group("/api/v1/places")
	places.Use(authMw)
	places.GET("/autocomplete", platformHandler.PlacesAutocomplete)
	places.GET("/geocode", platformHandler.PlacesGeocode)
	places.GET("/details", platformHandler.PlacesDetails)

	// Estimates
	estimates := r.Group("/api/v1/estimates")
	estimates.Use(authMw)
	estimates.GET("/price", platformHandler.EstimatesPrice)
	estimates.GET("/eta", platformHandler.EstimatesETA)

	// Promotions
	promos := r.Group("/api/v1/promotions")
	promos.Use(authMw)
	promos.GET("", platformHandler.PromotionsList)
	promos.POST("/apply", platformHandler.ApplyPromotion)

	// Platform
	platform := r.Group("/api/v1")
	platform.Use(authMw)
	platform.POST("/sos", platformHandler.SOS)
	platform.POST("/feedback", platformHandler.Feedback)
	platform.POST("/devices", platformHandler.DeviceRegister)
	platform.DELETE("/devices/:token", platformHandler.DeviceUnregister)

	// Heatmap
	r.GET("/api/v1/heatmap", authMw, platformHandler.Heatmap)

	// Driver location tracking (for rider)
	r.GET("/api/v1/drivers/:id/location", authMw, geoHandler.GetDriverLocation)

	// Driver earnings withdraw (stub)
	r.POST("/api/v1/driver/earnings/withdraw", authMw, middleware.RequireRole("driver"), platformHandler.StubPayment)

	// WebSocket
	wsHub := websocket.NewHub()
	r.GET("/ws", authMw, wsHub.HandleWS)

	return r
}
