package service

import (
	"log"
	"sync"
	"time"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// PendingRideSweeper is the server-side owner of orphaned `pending` rides
// (api_plans/[rides]_orphaned_pending_expiry.md). A `pending` row otherwise has
// no owner once the in-process dispatch goroutine dies (process restart, failed
// terminal write, panic), so GET /rides/current used to return it forever and
// the rider app reopened the matching screen on every login.
//
// It closes rows to no_driver_available through the landed CAS
// UpdateRideStatusFrom(id, []string{"pending"}, ...): the expected-from set is
// exactly {pending}, so an accept that wins the race is never reverted. Every
// closure writes a ride_events row with actor "system" and reason
// boot_reconcile (boot) or stale_pending_sweep (tick) — that is how support
// distinguishes a sweep from a genuine empty search.
//
// Do not use the zero value; construct with NewPendingRideSweeper.
//
// It sends no WebSocket/push frames (D6): GET /rides/current is the source of
// truth and a still-polling rider observes the terminal/no-ride state on the
// next poll. Failures are logged and retried on the next tick, never fatal.
type PendingRideSweeper struct {
	repo            repository.PendingRideRepository
	staleAfter      time.Duration
	interval        time.Duration
	reconcileOnBoot bool
	stop            chan struct{}
	stopOnce        sync.Once
	done            chan struct{}

	// mu guards started, which makes Start a no-op after the first call and
	// lets Stop distinguish "never started" (return immediately) from "started,
	// wait for done" without blocking on a done channel that will never close.
	mu      sync.Mutex
	started bool
}

// NewPendingRideSweeper builds a sweeper. Non-positive durations fall back to
// the config defaults rather than becoming a zero cutoff or a hot loop.
func NewPendingRideSweeper(repo repository.PendingRideRepository, staleAfter, interval time.Duration, reconcileOnBoot bool) *PendingRideSweeper {
	if staleAfter <= 0 {
		staleAfter = config.DefaultRidePendingStaleAfter
	}
	if interval <= 0 {
		interval = config.DefaultRideSweepInterval
	}
	return &PendingRideSweeper{
		repo:            repo,
		staleAfter:      staleAfter,
		interval:        interval,
		reconcileOnBoot: reconcileOnBoot,
		stop:            make(chan struct{}),
		done:            make(chan struct{}),
	}
}

// Start runs the boot reconciliation SYNCHRONOUSLY (unless disabled by
// RIDE_BOOT_RECONCILE=off) and only then starts the ticker goroutine, so main
// begins serving requests after restart orphans are already closed. A boot
// failure is logged and never blocks startup. Calling Start more than once is a
// no-op: a second call must neither re-run the boot pass nor start a second
// ticker (which would double-close done on Stop).
//
// Start after a Start+Stop pair is inert: Stop closes the stop channel exactly
// once and it is never re-opened, so calling Start again does nothing. Only
// Stop before Start is a documented no-op that leaves the sweeper usable.
func (s *PendingRideSweeper) Start() {
	s.mu.Lock()
	if s.started {
		s.mu.Unlock()
		return
	}
	s.started = true
	s.mu.Unlock()

	if s.reconcileOnBoot {
		s.sweepOnce("boot")
	}
	go func() {
		defer close(s.done)
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

// Stop ends the loop and waits for the in-flight sweep to finish. It is
// idempotent and safe before Start: with no goroutine running there is no done
// channel to wait for, so an early or repeated call returns immediately instead
// of hanging forever. The stop channel is closed at most once.
func (s *PendingRideSweeper) Stop() {
	s.mu.Lock()
	started := s.started
	s.mu.Unlock()
	if !started {
		return
	}
	s.stopOnce.Do(func() { close(s.stop) })
	<-s.done
}

// sweepOnce runs one pass. trigger is "boot" (every pending row, regardless of
// age) or "tick" (only rows older than staleAfter). A list error is logged and
// retried on the next tick, never fast-retried. A per-row CAS/event failure is
// logged and does not abort the remaining ids.
func (s *PendingRideSweeper) sweepOnce(trigger string) {
	reason := "stale_pending_sweep"
	var ids []string
	var err error
	if trigger == "boot" {
		reason = "boot_reconcile"
		ids, err = s.repo.FindPendingRideIDs()
	} else {
		ids, err = s.repo.FindStalePendingRideIDs()
	}
	if err != nil {
		log.Printf("[rides] pending sweep (%s) list failed, will retry in %s: %v",
			trigger, s.interval, err)
		return
	}

	closed := 0
	for _, id := range ids {
		updated, err := s.repo.UpdateRideStatusFrom(id, []string{"pending"}, "no_driver_available", nil)
		if err != nil {
			log.Printf("[rides] pending sweep (%s): close ride %s failed: %v", trigger, id, err)
			continue
		}
		if !updated {
			// An accept/cancel won the race: leave the row and write no event.
			log.Printf("[rides] pending sweep (%s): ride %s left pending (raced), skipping", trigger, id)
			continue
		}
		closed++
		if err := s.repo.CreateEvent(&model.RideEvent{
			RideID:     id,
			FromStatus: "pending",
			ToStatus:   "no_driver_available",
			Actor:      "system",
			Reason:     reason,
		}); err != nil {
			// The ride row is already committed; a missing audit row must not
			// fail the sweep or trigger a retry that could double-close.
			log.Printf("[rides] pending sweep (%s): event for ride %s failed: %v", trigger, id, err)
		}
	}
	if closed > 0 {
		log.Printf("[rides] pending sweep (%s): closed %d ride(s) as no_driver_available (stale after %s)",
			trigger, closed, s.staleAfter)
	}
}
