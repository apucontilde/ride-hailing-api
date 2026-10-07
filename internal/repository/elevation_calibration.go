package repository

import (
	"math"
	"sort"
)

// The certified-flat-street deadband calibration (api_plans/[elevation], gate G6,
// now-condensed deadband-calibrate-and-flip execution plan). The shipped DeadbandM must be a MEASURED value, not a datasheet
// guess: this file is the PURE half of that measurement. It imports no database
// code, holds no *sqlx.DB, and is unit-tested on synthetic sets
// (navigation_elevation_test.go). The DB-backed half
// (collectFlatEdgeAbsDz, integration-tagged) only loads the two tables and
// calls flatEdgeAbsDz; the statistic never touches Postgres.

const (
	// flatEdgeDeadbandQuantile is the quantile of |Δz| the deadband is set to.
	// On a genuinely flat street the true Δz is ~0, so the upper tail of the
	// observed |Δz| is DEM sampling noise: the p95 sits above that noise and
	// below real terrain relief, matching the retired DEM-ingest plan's rule
	// that "DeadbandM must sit above the [flat-street] noise floor".
	flatEdgeDeadbandQuantile = 0.95
	// flatEdgeDeadbandFallbackM is returned for an empty (or all-non-finite)
	// sample set: the pre-calibration provisional default, kept so an empty
	// graph (a dev DB before import) still yields a sane, finite deadband
	// rather than 0 or NaN.
	flatEdgeDeadbandFallbackM = 3.0
)

// flatEdgeDeadbandM returns the calibrated DeadbandM from the |Δz| samples of a
// certifiably-flat edge set — the p95 of |Δz|, rounded to one decimal.
//
// It never returns NaN and never panics. Empty input, all-non-finite input and
// any non-finite quantile all fall back to flatEdgeDeadbandFallbackM; negative
// samples are treated as magnitudes; the result is never negative.
func flatEdgeDeadbandM(absDz []float64) float64 {
	vals := make([]float64, 0, len(absDz))
	for _, v := range absDz {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			continue
		}
		if v < 0 {
			v = -v
		}
		vals = append(vals, v)
	}
	if len(vals) == 0 {
		return flatEdgeDeadbandFallbackM
	}
	d := sampleQuantile(vals, flatEdgeDeadbandQuantile)
	if math.IsNaN(d) || math.IsInf(d, 0) || d < 0 {
		return flatEdgeDeadbandFallbackM
	}
	return math.Round(d*10) / 10
}

// sampleQuantile returns the q-th quantile (0..1) of v using the nearest-rank
// ("discrete") convention, matching the SQL percentile_disc the calibration
// measurement uses. It sorts v in place. Empty input returns 0; callers that
// must not see a fallback guard it themselves (flatEdgeDeadbandM does).
func sampleQuantile(v []float64, q float64) float64 {
	if len(v) == 0 {
		return 0
	}
	if q < 0 {
		q = 0
	}
	if q > 1 {
		q = 1
	}
	sort.Float64s(v)
	idx := int(q * float64(len(v)-1))
	if idx < 0 {
		idx = 0
	}
	if idx >= len(v) {
		idx = len(v) - 1
	}
	return v[idx]
}

// The certified-flat edge-set rule. It certifies TERRAIN, not edges, so the
// measured |Δz| spread is the DEM noise and not a circular re-read of the very
// quantity being calibrated:
//
//   - flatReliefCellDeg (0.001° ≈ 111 m, ~3.6 skadi 1-arcsec posts): the
//     vertex set is gridded at this resolution and each cell stores its min/max
//     elevation_m.
//   - flatReliefMaxM: a cell's LOCAL RELIEF is max−min over the 3×3 block of
//     cells (~330 m across), i.e. it aggregates every vertex around the edge
//     and does not depend on the edge's own Δz.
//   - flatEdgeMaxLengthM: an edge is certified flat only if it is short enough
//     that the bounded local relief cannot hide real climb along it, AND both
//     endpoints sit in cells whose local relief is ≤ flatReliefMaxM.
const (
	flatReliefCellDeg  = 0.001
	flatReliefMaxM     = 15.0
	flatEdgeMaxLengthM = 75.0
)

// flatEdgeAbsDz applies the certified-flat rule to a loaded vertex/edge set and
// returns the per-edge |Δz| (metres) of the qualifying edges. It is pure and
// DB-free, so the certification is unit-testable; the integration-tagged
// collector only loads the two tables and calls this.
//
// Vertices without a DEM sample (EleM nil) participate in neither the relief
// statistics nor the edge samples — an unknown endpoint is not a flatness
// signal.
func flatEdgeAbsDz(verts []roadNode, edges []roadEdge) []float64 {
	type cell struct {
		mn, mx float64
		seen   bool
	}
	cells := make(map[[2]int]cell, len(verts))
	ele := make(map[int64]float64, len(verts))
	vcell := make(map[int64][2]int, len(verts))

	cellKey := func(lat, lng float64) [2]int {
		return [2]int{
			int(math.Floor(lat / flatReliefCellDeg)),
			int(math.Floor(lng / flatReliefCellDeg)),
		}
	}

	for _, v := range verts {
		if v.EleM == nil {
			continue
		}
		e := *v.EleM
		ele[v.ID] = e
		k := cellKey(v.Lat, v.Lng)
		vcell[v.ID] = k
		c := cells[k]
		if !c.seen {
			c = cell{mn: e, mx: e, seen: true}
		} else {
			c.mn = math.Min(c.mn, e)
			c.mx = math.Max(c.mx, e)
		}
		cells[k] = c
	}

	relief := make(map[[2]int]float64, len(cells))
	for k := range cells {
		mn, mx := math.Inf(1), math.Inf(-1)
		for dy := -1; dy <= 1; dy++ {
			for dx := -1; dx <= 1; dx++ {
				if c, ok := cells[[2]int{k[0] + dy, k[1] + dx}]; ok {
					mn = math.Min(mn, c.mn)
					mx = math.Max(mx, c.mx)
				}
			}
		}
		relief[k] = mx - mn
	}

	out := make([]float64, 0, len(edges))
	for _, e := range edges {
		if e.Cost <= 0 || e.Cost > flatEdgeMaxLengthM {
			continue
		}
		aEle, okA := ele[e.Source]
		bEle, okB := ele[e.Target]
		if !okA || !okB {
			continue
		}
		ka, okA := vcell[e.Source]
		kb, okB := vcell[e.Target]
		if !okA || !okB {
			continue
		}
		if relief[ka] > flatReliefMaxM || relief[kb] > flatReliefMaxM {
			continue
		}
		out = append(out, math.Abs(bEle-aEle))
	}
	return out
}
