package service

import (
	"math"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
)

// pt builds a track fix at (lat,lng) recorded at base+d.
func pt(lat, lng float64, base time.Time, d time.Duration) model.RideTrackPoint {
	return model.RideTrackPoint{Lat: lat, Lng: lng, RecordedAt: base.Add(d)}
}

// TestDrivenDistanceSumsSyntheticSequence pins the happy path: closely spaced
// fixes along a line sum to their straight-line length.
func TestDrivenDistanceSumsSyntheticSequence(t *testing.T) {
	base := time.Now()
	// 0.0001 deg of longitude at the equator is ~11.13 m.
	fixes := []model.RideTrackPoint{
		pt(0, 0, base, 0),
		pt(0, 0.0001, base, time.Second),
		pt(0, 0.0002, base, 2*time.Second),
		pt(0, 0.0003, base, 3*time.Second),
	}
	got := DrivenDistanceMeters(fixes)
	if got == nil {
		t.Fatal("expected a distance for a usable trace, got nil")
	}
	// ~33.4 m of straight-line travel.
	if *got < 30 || *got > 37 {
		t.Fatalf("distance = %.2f m, want ~33.4 m", *got)
	}
}

// TestDrivenDistanceRejectsTeleport pins the noise gate: an implausible jump is
// dropped and does not book a phantom kilometre.
func TestDrivenDistanceRejectsTeleport(t *testing.T) {
	base := time.Now()
	fixes := []model.RideTrackPoint{
		pt(0, 0, base, 0),
		pt(0, 0.0001, base, time.Second),   // ~11.1 m, accepted
		pt(1, 0, base, 2*time.Second),      // ~111 km in 1s -> teleport, dropped
		pt(0, 0.0002, base, 3*time.Second), // back across the teleport, dropped
	}
	got := DrivenDistanceMeters(fixes)
	if got == nil {
		t.Fatal("expected a distance, got nil")
	}
	if *got > 15 {
		t.Fatalf("distance = %.2f m, want only the ~11.1 m pre-teleport segment", *got)
	}
	if *got < 9 {
		t.Fatalf("distance = %.2f m, want the pre-teleport segment counted", *got)
	}
}

// TestDrivenDistanceToleratesGap pins that a large jump over a LONG interval
// (a signal gap) is accepted: the gate is speed, not raw distance.
func TestDrivenDistanceToleratesGap(t *testing.T) {
	base := time.Now()
	fixes := []model.RideTrackPoint{
		pt(0, 0, base, 0),
		pt(0, 0.001, base, 10*time.Minute), // ~111 m over 600 s -> plausible
	}
	got := DrivenDistanceMeters(fixes)
	if got == nil {
		t.Fatal("expected a distance for a slow long segment, got nil")
	}
	if *got < 110 || *got > 113 {
		t.Fatalf("distance = %.2f m, want ~111.3 m", *got)
	}
}

// TestDrivenDistanceNilWhenUnusable pins the NULL contract: no fixes, a single
// fix, or only jitter must yield nil, never a fabricated 0.
func TestDrivenDistanceNilWhenUnusable(t *testing.T) {
	base := time.Now()
	cases := map[string][]model.RideTrackPoint{
		"nil":  nil,
		"none": {},
		"single": {
			pt(0, 0, base, 0),
		},
		"jitter only": {
			pt(0, 0, base, 0),
			pt(0, 0.00001, base, time.Second), // ~1.1 m, below the 3 m floor
			pt(0, 0.00002, base, 2*time.Second),
		},
	}
	for name, fixes := range cases {
		if got := DrivenDistanceMeters(fixes); got != nil {
			t.Errorf("%s: distance = %v, want nil", name, *got)
		}
	}
}

// TestActualDurationSeconds pins the timestamp actual and its NULL-on-missing
// contract.
func TestActualDurationSeconds(t *testing.T) {
	start := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	end := start.Add(95 * time.Second)

	if got := ActualDurationSeconds(&start, &end); got == nil || *got != 95 {
		t.Fatalf("duration = %v, want 95", got)
	}
	if got := ActualDurationSeconds(nil, &end); got != nil {
		t.Fatalf("duration with nil start = %v, want nil", *got)
	}
	if got := ActualDurationSeconds(&start, nil); got != nil {
		t.Fatalf("duration with nil end = %v, want nil", *got)
	}
	// Clock skew (completed before started) is unusable, not a negative value.
	if got := ActualDurationSeconds(&end, &start); got != nil {
		t.Fatalf("duration with end before start = %v, want nil", *got)
	}
}

// TestHaversineMeters sanity-checks the seam against a known distance.
func TestHaversineMeters(t *testing.T) {
	// 0.001 deg of latitude is ~111.2 m everywhere.
	got := HaversineMeters(0, 0, 0.001, 0)
	if math.Abs(got-111.19) > 1.0 {
		t.Fatalf("haversine = %.2f m, want ~111.19 m", got)
	}
}
