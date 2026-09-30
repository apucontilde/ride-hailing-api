package repository

import (
	"errors"
	"strings"
	"testing"
	"time"
)

// DriverPresenceMaxAgeS is a safety bound, so its VALUE is a decision and is
// pinned here: 5 minutes is long enough that a driver who just published a fix
// always has a refreshable position, and short enough that "where they were
// half an hour ago" never counts as "where they are".
//
// The bound is deliberately much longer than DriverLivenessWindow: a stationary
// driver's row ages past the liveness window in 30s and is re-armed on the next
// online write for as long as the fix itself is fresh. The two windows answer
// different questions.
func TestDriverPresenceMaxAge(t *testing.T) {
	const want = 5 * time.Minute
	if got := time.Duration(DriverPresenceMaxAgeS) * time.Second; got != want {
		t.Errorf("DriverPresenceMaxAgeS = %v, want %v", got, want)
	}
	if DriverPresenceMaxAgeS <= int(DriverLivenessWindow/time.Second) {
		t.Errorf("DriverPresenceMaxAgeS = %d s must be longer than the %s liveness window, "+
			"or a stationary driver could never be re-armed", DriverPresenceMaxAgeS, DriverLivenessWindow)
	}
	// The bound binds as a typed float64 const, never as a time.Duration: see
	// driverLivenessSeconds for the silent-corruption hazard that guards.
	if seconds := driverPresenceMaxAgeSeconds; seconds != float64(DriverPresenceMaxAgeS) {
		t.Errorf("driverPresenceMaxAgeSeconds = %v, want %v", seconds, float64(DriverPresenceMaxAgeS))
	}
}

// The "no dispatchable position" error is what the handler keys off, so it has
// to wrap ErrNotFound and has to say the age bound is one of the reasons — the
// log line is the only signal a support trace has for "the driver is online but
// dispatch cannot see them".
func TestPresenceErrorNamesTheAgeBound(t *testing.T) {
	err := presenceUndispatchable("drv-1")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want it to wrap ErrNotFound", err)
	}
	if !strings.Contains(err.Error(), "older than") {
		t.Errorf("err = %v; the message must name the staleness branch, not just 'no position'", err)
	}
	if !strings.Contains(err.Error(), "drv-1") {
		t.Errorf("err = %v; the message must name the driver", err)
	}
}
