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
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/router"
	"ride-hailing-api/internal/service"
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

	// Driver liveness sweep (api_plans
	// [dispatch]_reliability_and_no_driver_false_negative).
	//
	// MarkStaleDriversOffline was on the GeoRepository interface with no
	// production caller anywhere in the tree, so a driver who stopped
	// publishing positions stayed stored as "online" forever in the dispatch
	// view. It has a caller now: this sweeper, immediately at boot and then
	// once per DefaultSweeperInterval.
	//
	// Scope, stated narrowly because it is easy to over-claim: the sweep writes
	// driver_positions.status and NOTHING else. That is the column dispatch
	// filters on, so it is what honesty about dispatch-eligibility means. It
	// does not touch drivers.status (the profile record — only the driver's own
	// status write may change that), and it does not change what
	// GET /api/v1/drivers/:id/location answers: that query selects no status
	// column at all (internal/repository/geo_repo.go:127-134), so a driver
	// whose app died reads the same before and after a sweep.
	//
	// It is NOT a keep-alive and does not make anyone dispatchable — that is
	// GeoRepository.TouchDriverPresence, called by the driver status handler
	// whenever the request asks for status "online". That check is STATELESS
	// (internal/handler/driver.go:190: `body.Status == "online"`, the status
	// the client asked for, not the driver's previous one) — there is no
	// offline→online state machine anywhere in this path, and a repeat "online"
	// write simply refreshes again. The two are complementary: the presence
	// write makes a just-online/stationary driver visible to dispatch, and the
	// sweep makes the stored dispatch status honest again once they go quiet.
	//
	// A second GeoRepo over the same `*sqlx.DB` is deliberate: it is a thin
	// struct around the existing connection pool, so it adds no connections and
	// no configuration, and it keeps the sweeper's lifecycle in main rather
	// than inside the router where it would be untestable.
	sweeper := service.NewDriverLivenessSweeper(repository.NewGeoRepo(db), service.DefaultSweeperInterval)
	sweeper.Start()
	defer sweeper.Stop()

	// Pending-ride lifecycle (api_plans/[rides]_orphaned_pending_expiry.md).
	//
	// A `pending` ride has no owner once its in-process dispatch goroutine dies,
	// so the sweeper closes orphaned rows to no_driver_available: ALL pending
	// rows at boot (single-instance invariant; RIDE_BOOT_RECONCILE=off for
	// multi-replica/rolling deploys) and only rows older than
	// RIDE_PENDING_STALE_AFTER on each tick. Start() runs the boot reconcile
	// synchronously before serving. The router builds its own RideRepo with the
	// same threshold so the GET /rides/current read guard and this sweep agree.
	//
	// A second RideRepo over the same pool is deliberate, exactly like the
	// liveness GeoRepo above: a thin struct around the existing connection pool,
	// with the lifecycle kept in main rather than inside the router.
	rideRepo := repository.NewRideRepo(db, repository.WithPendingStaleAfter(cfg.RideLifecycle.PendingStaleAfter))
	rideSweeper := service.NewPendingRideSweeper(rideRepo,
		cfg.RideLifecycle.PendingStaleAfter,
		cfg.RideLifecycle.SweepInterval,
		cfg.RideLifecycle.BootReconcile)
	rideSweeper.Start()
	// This defer is reached only on a normal return from run(): the process has
	// no signal-driven graceful shutdown (same pre-existing pattern as the
	// liveness sweeper above). Stop is idempotent and safe before Start.
	defer rideSweeper.Stop()

	addr := ":" + cfg.ServerPort
	log.Printf("server starting on %s", addr)
	if err := r.Run(addr); err != nil {
		return fmt.Errorf("server failed: %w", err)
	}
	return nil
}
