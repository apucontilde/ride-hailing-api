package service

import (
	"math"
	"time"

	"ride-hailing-api/internal/model"
)

// Actuals are captured fare-agnostically on the completed transition
// (api_plans/[tracking]_actual_trip_distance.md): duration from the status
// timestamps, driven distance from the raw location fixes recorded while the
// ride was in_progress (migration 021). Nothing here prices anything.

const (
	// minFixSegmentM is the GPS jitter floor. Successive fixes closer than this
	// are treated as a stationary receiver wobbling, not travel, and contribute
	// no distance. Without it, a parked car emitting fixes for 30 minutes would
	// accumulate a phantom kilometre-scale "distance" purely from noise.
	//
	// The trade-off is conservative: genuinely very slow movement (below ~3 m
	// per accepted fix) is undercounted. That is preferable to overbooking a
	// teleport or a stationary jitter cloud.
	minFixSegmentM = 3.0

	// maxPlausibleSpeedMps is the teleport gate: the implied speed of a segment
	// (segment metres / seconds since the previous fix) above which the segment
	// is dropped. 60 m/s is ~216 km/h, comfortably above any road vehicle but
	// below a GPS glitch or a driver app that jumped cells after an outage.
	maxPlausibleSpeedMps = 60.0
)

// DrivenDistanceMeters sums the straight-line (haversine) distance between
// successive usable fixes and returns metres. It returns nil — NOT 0 — when the
// trace is unusable: fewer than two fixes, or every segment gated out, so the
// caller stores SQL NULL and the fare stage falls back to the booked route
// distance rather than a fabricated number.
//
// Noise/teleport gate, applied pairwise against the previously accepted fix:
//
//   - non-increasing timestamps (out-of-order or duplicate instants) are
//     dropped;
//   - segments shorter than minFixSegmentM are treated as jitter and dropped;
//   - segments whose implied speed exceeds maxPlausibleSpeedMps are treated as
//     teleports and dropped.
//
// A dropped segment RE-ANCHORS to the current fix, so one glitch never poisons
// every later segment (a genuine teleport would otherwise leave the anchor
// stranded and stall all further accumulation). The cost of re-anchoring is
// that a spike-and-return undercounts the return leg, which is the safe
// direction for a fare.
//
// Accuracy limits: this is a straight-line lower bound on the path actually
// driven, not a map-matched odometer. Sparse or throttled fixes and any gap
// undercount curves and switchbacks; there is no accuracy-radius, heading or
// elevation filtering. It is honest enough for the time/distance recompute,
// which must never invent a distance where the trace is unusable.
func DrivenDistanceMeters(fixes []model.RideTrackPoint) *float64 {
	if len(fixes) < 2 {
		return nil
	}

	var total float64
	accepted := false
	prev := fixes[0]
	for i := 1; i < len(fixes); i++ {
		cur := fixes[i]
		dt := cur.RecordedAt.Sub(prev.RecordedAt).Seconds()
		seg := HaversineMeters(prev.Lat, prev.Lng, cur.Lat, cur.Lng)

		switch {
		case dt <= 0:
			// Out-of-order or same-instant fix: no defensible speed, drop it.
		case seg < minFixSegmentM:
			// Stationary jitter, not travel.
		case seg/dt > maxPlausibleSpeedMps:
			// Implausible jump: a GPS teleport or cell hand-off, never a fare.
		default:
			total += seg
			accepted = true
		}
		prev = cur
	}

	if !accepted {
		return nil
	}
	return &total
}

// ActualDurationSeconds computes completed-started as whole seconds. It returns
// nil when either timestamp is missing (the ride never started, or the clock is
// absent), never a fabricated 0; a real sub-second trip honestly rounds to 0.
func ActualDurationSeconds(started, completed *time.Time) *int {
	if started == nil || completed == nil {
		return nil
	}
	secs := int(completed.Sub(*started).Seconds())
	if secs < 0 {
		return nil
	}
	return &secs
}

// earthRadiusM is the mean Earth radius used by HaversineMeters.
const earthRadiusM = 6371000.0

// HaversineMeters is the great-circle distance between two WGS-84 points in
// metres. It is the straight-line seam between two location fixes; road
// curvature is NOT accounted for (see DrivenDistanceMeters accuracy limits).
func HaversineMeters(lat1, lng1, lat2, lng2 float64) float64 {
	const rad = math.Pi / 180
	dLat := (lat2 - lat1) * rad
	dLng := (lng2 - lng1) * rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLng/2)*math.Sin(dLng/2)
	return 2 * earthRadiusM * math.Asin(math.Sqrt(math.Min(1, a)))
}
