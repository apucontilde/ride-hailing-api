package service

import (
	"log"
	"sync"
	"time"

	"ride-hailing-api/internal/repository"
)

// DriverLivenessSweeper reconciles stored liveness on a ticker.
//
// WHY IT EXISTS: MarkStaleDriversOffline is the only thing that can move
// driver_positions.status back to 'offline' for a driver whose app simply died,
// so without a caller the column drifts monotonically toward 'online'. Dispatch
// search already filters those rows out on freshness, so this is honesty about
// the stored dispatch view, not dispatch eligibility — TouchDriverPresence is
// what makes a stationary driver dispatchable.
//
// What it does NOT touch, so nobody reads more into it than is there:
// drivers.status (the profile record — only the driver's own status write may
// change it) and the GET /api/v1/drivers/:id/location payload, whose query
// selects no status column (internal/repository/geo_repo.go:127-134).
type DriverLivenessSweeper struct {
	geoRepo  repository.GeoRepository
	interval time.Duration
	stop     chan struct{}
	stopOnce sync.Once
	done     chan struct{}
}

// DefaultSweeperInterval is how often the liveness sweep runs. It is well under
// the 30s liveness window so a driver is reconciled within a few seconds of
// going quiet, without turning the sweep into meaningful database load: it is
// one indexed UPDATE of a small table.
const DefaultSweeperInterval = 10 * time.Second

// NewDriverLivenessSweeper builds a sweeper. An interval <= 0 falls back to
// DefaultSweeperInterval rather than becoming a hot loop.
func NewDriverLivenessSweeper(geoRepo repository.GeoRepository, interval time.Duration) *DriverLivenessSweeper {
	if interval <= 0 {
		interval = DefaultSweeperInterval
	}
	return &DriverLivenessSweeper{
		geoRepo:  geoRepo,
		interval: interval,
		stop:     make(chan struct{}),
		done:     make(chan struct{}),
	}
}

// Start runs one sweep immediately, then one per interval, until Stop. The
// immediate sweep matters on boot: a process restart should not wait a full
// interval to clean up drivers the previous instance abandoned.
func (s *DriverLivenessSweeper) Start() {
	go func() {
		defer close(s.done)
		s.sweepOnce("boot")
		ticker := time.NewTicker(s.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				s.sweepOnce("tick")
			case <-s.stop:
				return
			}
		}
	}()
}

// Stop ends the loop and waits for the in-flight sweep to finish, so a
// shutting-down process cannot close its database underneath a running UPDATE.
// It is safe to call from several goroutines: the close is done once, and every
// caller still waits for done.
func (s *DriverLivenessSweeper) Stop() {
	s.stopOnce.Do(func() { close(s.stop) })
	<-s.done
}

// Interval reports the configured sweep period.
func (s *DriverLivenessSweeper) Interval() time.Duration { return s.interval }

// sweepOnce runs a single reconciliation. A failure is logged and NOT retried
// fast: the next tick is the retry, and hammering a database that is already in
// trouble makes the outage worse.
func (s *DriverLivenessSweeper) sweepOnce(trigger string) {
	if err := s.geoRepo.MarkStaleDriversOffline(); err != nil {
		log.Printf("[dispatch] liveness sweep (%s) failed, will retry in %s: %v",
			trigger, s.interval, err)
	}
}
