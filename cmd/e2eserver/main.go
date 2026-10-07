// Command e2eserver boots the real API (router, handlers, dispatch service and
// WebSocket hub) against in-memory repositories so the Playwright suite in
// e2e/ can drive the real rider and driver web UIs.
//
// Why not Postgres? The e2e suite asserts on dispatch behaviour that depends on
// driver_positions rows, and a real DB is not always available in CI or on a
// laptop. This harness boots the identical router.SetupWithRepos wiring the
// production server uses, so the only substitution is the storage layer.
//
// The critical difference from the Go test harness (tests/testutil): the geo
// repo is STRICT — it never invents a nearby driver. With the lenient mock a
// ride is always dispatched to a fictional "simulated-driver", so "the driver
// never received the offer" can never fail. That fabrication is what let the
// original bug reach main.
//
// Usage:
//
//	go run ./cmd/e2eserver -addr :8099
//
// It prints "READY <url>" on stdout once listening, and shuts down on SIGINT.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/router"
	"ride-hailing-api/tests/testutil"
)

func main() {
	addr := flag.String("addr", ":8099", "listen address")
	seedPlaces := flag.Bool("seed-places", true, "seed a few places so the rider's destination search returns results")
	flag.Parse()

	cfg := config.Load()
	// The suite fires a lot of auth and ride requests quickly; keep rate
	// limiting out of the picture so it cannot flake a UI test.
	cfg.RateLimitRegister = 9999
	cfg.RateLimitLogin = 9999
	cfg.RateLimitGeneral = 999999
	cfg.RateLimitRide = 999999

	userRepo := testutil.NewMockUserRepo()
	rideRepo := testutil.NewMockRideRepo()
	geoRepo := testutil.NewStrictMockGeoRepo() // <- no fabricated drivers
	navRepo := testutil.NewMockNavigationRepo()
	placesRepo := testutil.NewMockPlacesRepo()

	if *seedPlaces {
		// Coordinates cluster near the pickup the e2e specs use, so the
		// rider's "Where to?" search returns a hit. Address is a *string in
		// model.PlaceSeed.
		addr1, addr2, addr3 := "1 E2E Way", "2 E2E Way", "3 E2E Way"
		placesRepo.Seed(
			model.PlaceSeed{Name: "E2E Destination Plaza", Category: "landmark", Address: &addr1, Lat: 40.7580, Lng: -73.9855},
			model.PlaceSeed{Name: "E2E Transit Center", Category: "transit", Address: &addr2, Lat: 40.7600, Lng: -73.9800},
			model.PlaceSeed{Name: "E2E Museum", Category: "landmark", Address: &addr3, Lat: 40.7550, Lng: -73.9900},
		)
	}

	r := router.SetupWithRepos(cfg, userRepo, rideRepo, geoRepo, navRepo, placesRepo, nil,
		router.WithDeviceTokenRepository(testutil.NewMockDeviceTokenRepo()),
		router.WithFeedbackRepository(testutil.NewMockFeedbackRepo()),
		router.WithFareRepository(testutil.NewMockFareRepo()),
	)

	srv := &http.Server{
		Addr:              *addr,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-stop
		log.Println("shutting down e2eserver")
		_ = srv.Close()
	}()

	fmt.Printf("READY http://127.0.0.1%s\n", *addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("e2eserver failed: %v", err)
	}
}
