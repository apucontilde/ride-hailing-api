//	@title						Ride-Hailing API
//	@version					0.1.0
//	@description				Go + Gin ride-hailing backend: auth, rides, driver dispatch, geolocation, navigation, and places.
//	@host						localhost:8080
//	@BasePath					/
//	@securityDefinitions.apikey	BearerAuth
//	@in							header
//	@name						Authorization
//	@description				JWT access token. Include as `Authorization: Bearer <token>`.
package main

import (
	"log"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/database"
	"ride-hailing-api/internal/router"
)

func main() {
	cfg := config.Load()

	db, err := database.Connect(cfg)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer db.Close()

	if err := database.RunMigrations(db); err != nil {
		log.Fatalf("failed to run migrations: %v", err)
	}

	if err := database.SeedPlaces(db, cfg); err != nil {
		log.Fatalf("failed to seed places: %v", err)
	}

	r := router.Setup(cfg, db)

	addr := ":" + cfg.ServerPort
	log.Printf("server starting on %s", addr)
	if err := r.Run(addr); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}
