package service

// TEMPORARY pre-fix probe. Records the regression's runtime behaviour with
// symbols that exist on the BROKEN code, so the evidence does not depend on the
// new sentinel. Deleted once the permanent tests are in place.

import (
	"testing"

	"ride-hailing-api/internal/routing"
)

func TestPreFixProbeUncoveredPinBecomesAnError(t *testing.T) {
	// N1 (region path). What the pre-fix repository returned for a pin the
	// resolver's SQL snap COVERED but the Go graph gate REJECTED:
	// routing.ErrNoRoute, indistinguishable from "no path between covered pins".
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.routesErr = routing.ErrNoRoute

	got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	t.Logf("PRE-FIX N1 region path: route=%+v err=%v (handler answers 500 INTERNAL)", got, err)
	if err == nil {
		t.Fatal("probe: expected the pre-fix 500 path")
	}
}

func TestPreFixProbeLegacyUncoveredPinBecomesAnError(t *testing.T) {
	// N2 (legacy path): a repo without RegionSource has no estimate branch at
	// all, so the same gate error is a 500 for every deployment that reaches it.
	repo := &navRepoFake{err: routing.ErrNoRoute}

	got, err := NewNavigationService(repo).GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	t.Logf("PRE-FIX N2 legacy path: route=%+v err=%v (handler answers 500 INTERNAL)", got, err)
	if err == nil {
		t.Fatal("probe: expected the pre-fix 500 path")
	}
}
