package routing

import (
	"fmt"
	"math"
)

// CostWeights parameterizes the elevation cost model. The ZERO VALUE is
// distance-only routing — bit-for-bit the pre-elevation engine — so callers
// that never touch elevation cannot change behaviour by accident.
type CostWeights struct {
	// AscentW is the search-cost surcharge, in pseudo-meters, charged per
	// meter of climb. MUST be >= 0. 0 = climbing is free.
	AscentW float64
	// DescentW is the same for descending, normally much smaller than
	// AscentW. This is the knob that makes "keep going down" worth choosing
	// over "go up and over". MUST be >= 0 and DescentW*MaxGrade < 1.
	DescentW float64
	// MaxGrade clamps |dz/meters| per edge, so no single DEM artifact can
	// dominate a route. Typical roads are <= 0.15. It bounds the influence of
	// ONE edge, not the total climb of a path: a path of n steep edges still
	// accumulates n * meters * (1 + AscentW*MaxGrade). There is no ascent
	// budget in the model.
	MaxGrade float64
	// DeadbandM zeroes elevation deltas whose magnitude is <= this, in
	// meters. SRTM-class DEMs carry several meters of vertical error, and
	// without a deadband, DEM noise reads as grade and reshuffles every flat
	// route. The default is CALIBRATED, not provisional: 3.8 m is the measured
	// p95 of |dz| over 43,673 certifiably-flat edges on the live SJ import
	// (relief-certified, independent of the edge's own dz). Full measurement
	// and justification: defaultElevationDeadbandM in
	// internal/config/config.go and gate G6 of
	// api_plans/[elevation]_calibration_and_rollout_gate.md.
	DeadbandM float64
}

// Path is a weighted-search result. Meters is the true road length (what the
// API must report); Cost is the elevation-weighted search cost (what the
// search minimized); AscentM/DescentM are pre-deadband real metres; Expanded is
// the number of nodes the A* search popped off the open set (the hot-path cost
// of the weighted heuristic, measured by the elevation calibration stage).
type Path struct {
	Nodes    []int64
	Meters   float64
	Cost     float64
	AscentM  float64
	DescentM float64
	Expanded int
}

// weightedEdgeCost returns the directional cost of traversing one edge u→v of
// length `meters` with a signed elevation delta `dz` (= z(v) - z(u)) meters
// under the given weights. meters > 0 always (NewGraph drops Cost <= 0), so
// dz/meters cannot divide by zero.
func weightedEdgeCost(meters, dz float64, w CostWeights) float64 {
	dz = deadband(dz, w.DeadbandM)
	g := dz / meters
	g = clamp(g, -w.MaxGrade, w.MaxGrade)
	if g > 0 {
		return meters * (1 + w.AscentW*g) // == meters + w.AscentW*dz
	}
	return meters * (1 + w.DescentW*g)
}

// deadband zeroes dz when its magnitude is <= m.
func deadband(dz, m float64) float64 {
	if math.Abs(dz) <= m {
		return 0
	}
	return dz
}

// clamp bounds x to [lo, hi].
func clamp(x, lo, hi float64) float64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// heuristicScale is the lower-bound factor D = 1 - DescentW*MaxGrade. Zero or
// negative means the weight combination is invalid and MUST be rejected by
// Validate.
//
// Why D is correct (Part 2 of the stage — the obligation this model discharges):
//
// The A* heuristic is plain haversine, which lower-bounds DISTANCE. If any edge
// cost can be LESS than its meters, haversine stops being a lower bound on the
// weighted cost, and A* silently returns suboptimal paths. Since the descent
// grade is clamped to -MaxGrade, every edge satisfies
//
//	cost = meters·(1 + w·g) >= meters·(1 + DescentW·(-MaxGrade)) = D·meters.
//
// Admissible: for any path P from n to the goal, cost(P) >= D·len(P); a road
// path is never shorter than the straight line, so len(P) >= haversine(n, goal),
// hence h(n) = D·haversine(n, goal) <= cost(P).
//
// Consistent: haversine(u,goal) <= meters(u,v) + haversine(v,goal) by the
// triangle inequality, so h(u) = D·haversine(u,goal) <= D·meters(u,v) + h(v)
// <= cost(u,v) + h(v).
//
// Non-negative costs: D > 0 ⟹ every cost >= D·meters > 0, so A* terminates and
// each node expands at most once. Therefore validate requires D > 0.
func (w CostWeights) heuristicScale() float64 { return 1 - w.DescentW*w.MaxGrade }

// Validate reports whether the weights admit a correct A* search. It rejects:
//
//   - AscentW < 0 or DescentW < 0. The sign check is NOT optional: the Part 2
//     proof needs the lower bound on BOTH branches, and a negative weight
//     silently inverts it. With DescentW = -0.3, MaxGrade = 0.15 the scale
//     becomes 1.045, so the heuristic claims cost >= 1.045 * haversine while a
//     descent edge costs LESS than meters — inadmissible AND inconsistent.
//   - DescentW*MaxGrade >= 1 (D <= 0: costs collapse to zero and the search
//     degenerates).
//   - MaxGrade < 0.
//   - any of the four fields being NaN or +/-Inf.
func (w CostWeights) Validate() error {
	if math.IsNaN(w.AscentW) || math.IsInf(w.AscentW, 0) {
		return fmt.Errorf("AscentW is not finite: %v", w.AscentW)
	}
	if math.IsNaN(w.DescentW) || math.IsInf(w.DescentW, 0) {
		return fmt.Errorf("DescentW is not finite: %v", w.DescentW)
	}
	if math.IsNaN(w.MaxGrade) || math.IsInf(w.MaxGrade, 0) {
		return fmt.Errorf("MaxGrade is not finite: %v", w.MaxGrade)
	}
	if math.IsNaN(w.DeadbandM) || math.IsInf(w.DeadbandM, 0) {
		return fmt.Errorf("DeadbandM is not finite: %v", w.DeadbandM)
	}
	if w.AscentW < 0 {
		return fmt.Errorf("AscentW must be >= 0, got %v", w.AscentW)
	}
	if w.DescentW < 0 {
		return fmt.Errorf("DescentW must be >= 0, got %v", w.DescentW)
	}
	if w.MaxGrade < 0 {
		return fmt.Errorf("MaxGrade must be >= 0, got %v", w.MaxGrade)
	}
	if w.heuristicScale() <= 0 {
		return fmt.Errorf("DescentW*MaxGrade must be < 1 (got DescentW=%v, MaxGrade=%v)",
			w.DescentW, w.MaxGrade)
	}
	return nil
}
