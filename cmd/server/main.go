// @title						Ride-Hailing API
// @version					0.1.0
// @description				Go + Gin ride-hailing backend: auth, rides, driver dispatch, geolocation, navigation, and places.
// @host						localhost:8080
// @BasePath					/
// @securityDefinitions.apikey	BearerAuth
// @in							header
// @name						Authorization
// @description				JWT access token. Include as `Authorization: Bearer <token>`.
package main

import (
	"fmt"
	"log"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/database"
	"ride-hailing-api/internal/router"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("%v", err)
	}
}

// run holds the real startup so that every early return unwinds through
// run's defers — logging a fatal from main() instead would skip db.Close().
func run() error {
	cfg := config.Load()

	db, err := database.Connect(cfg)
	if err != nil {
		return fmt.Errorf("failed to connect to database: %w", err)
	}
	defer func() { _ = db.Close() }()

	if err := database.RunMigrations(db); err != nil {
		return fmt.Errorf("failed to run migrations: %w", err)
	}

	if err := database.SeedPlaces(db, cfg); err != nil {
		return fmt.Errorf("failed to seed places: %w", err)
	}

	r := router.Setup(cfg, db)

	addr := ":" + cfg.ServerPort
	log.Printf("server starting on %s", addr)
	if err := r.Run(addr); err != nil {
		return fmt.Errorf("server failed: %w", err)
	}
	return nil
}
