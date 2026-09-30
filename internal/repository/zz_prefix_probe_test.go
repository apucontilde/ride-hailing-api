package repository

// TEMPORARY pre-fix probe: what the native graph gate actually returns for a
// pin beyond the radius. Deleted once the permanent tests are in place.

import (
	"errors"
	"testing"

	"ride-hailing-api/internal/routing"
)

// A pin whose GO haversine distance is 50113 m — the number the reviewer's
// probe measured for a pin PostGIS measured as 49850 m — under the shipped
// 50000 m radius.
func TestPreFixProbeGateErrorIdentity(t *testing.T) {
	g := nativeTestGraph()
	lat, lng := pinAtSnapDistanceM(g, 9.9300, -84.0800, 50113, -1)

	d := snapDistanceM(g, lat, lng)
	t.Logf("PRE-FIX gate: goHaversine=%.1f m radius=50000 -> WithinSnapRadius=%v",
		d, WithinSnapRadius(d, 50000))

	_, err := routeResults(g, routing.CostWeights{}, 50000, gateIsAuthority, lat, lng, 9.9400, -84.0800)
	t.Logf("PRE-FIX gate error identity: %v (errors.Is ErrNoRoute=%v)", err, errors.Is(err, routing.ErrNoRoute))

	if err == nil {
		t.Fatal("probe: an uncovered pin must be rejected pre-fix")
	}
}
