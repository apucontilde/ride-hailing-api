//go:build integration

package repository

import (
	"math"
	"math/rand"
	"sort"
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/routing"
)

// Elevation acceptance suite — api_plans/[elevation]_calibration_and_rollout_gate.md.
//
// This file measures the elevation cost model against the REAL SJ import with
// real `skadi` DEM elevations already on the vertices. It builds the production
// graph the same way NativeNavigationRepo.roadGraph does (loadNodes/loadEdges/
// NewGraph on the repo's own pool), so the numbers are production behaviour, not
// a synthetic approximation. Every test seeds from a fixed rand source so a
// failure is reproducible run to run.
//
// The committed tests use a reduced sample (see `sampleN`) so `make
// test-integration` stays sane. The historical WEIGHT RESPONSE / GATE RESULT
// numbers in api_plans/[elevation]_calibration_and_rollout_gate.md were
// produced by THIS N=100 committed sweep plus a fuller N=250 scratch sweep
// (internal/repository/zz_sweep2_test.go). The plan's full N=2000 sample was
// subsequently run by Stage 2 of the now-condensed deadband-calibrate-and-flip
// execution plan (condensed in api_plans/STATUS.md under [elevation])
// (internal/repository/zz_stage2_sweep_test.go, gated behind RUN_STAGE2_SWEEP=1)
// and settled G2/G5 at asc12_db3.8. Both committed helpers use the same fixed
// seed, so the tests guard the *properties* the recorded blocks assert.

// sampleN is the committed-test sample size for the province-wide tests. It
// keeps the acceptance suite inside `go test`'s default 10-minute package
// timeout alongside the other integration tests. The historical gate numbers
// came from this N=100 sweep and a fuller N=250 scratch run; the N=2000 Stage-2
// run (zz_stage2_sweep_test.go) is the settled result. These committed tests
// guard the same *properties* at reduced resolution and stay fast.
const sampleN = 100

// provinceBBox is the San José province clip the importer produces
// (download-osm.sh), verified against the live 152,665-vertex import.
var provinceBBox = [4]float64{8.99, -84.54, 10.24, -83.39}

// defaultWeights is the recorded PRE-calibration provisional default that
// produced the historical N=100/N=250 sweep tables in the gate plan. It is kept
// frozen as a historical probe so those recorded numbers stay attributable and
// so TestElevationFlatAreaInvariance keeps being measured at the weights its
// recorded 97.0% result was taken at. The SHIPPED default is now the calibrated
// operating point asc12_db3.8 (AscentW=12, DeadbandM=3.8); Stage 2 of the
// now-condensed deadband-calibrate-and-flip execution plan re-ran the full sweep
// at that point (see zz_stage2_sweep_test.go and the gate plan's Stage-2 block).
var defaultWeights = routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3}

// ascentHeavy is the by-eye operating point the historical sweep found: median
// ascent ratio ~0.94 with median meters ratio still < 1.01. Kept frozen as the
// db=8 probe; the SHIPPED point is asc12 at the calibrated db=3.8, which the
// Stage-2 N=2000 sweep found at least as good (168 vs 150 qualifying pairs).
var ascentHeavy = routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 8}

// pair is a fixed, seeded origin/destination used by every sub-test.
type pair struct{ fromLat, fromLng, toLat, toLng float64 }

// seededPairs returns n random OD pairs inside bbox whose FLAT route succeeds
// (routable). Pairs that do not snap/route are counted (rejected) so a
// denominator that silently loses unroutable pairs is impossible: the
// accepted/rejected split is itself a recorded quantity.
func seededPairs(g *routing.Graph, bbox [4]float64, n int) (accepted []pair, rejected int) {
	r := rand.New(rand.NewSource(42))
	accepted = make([]pair, 0, n)
	for len(accepted) < n {
		aLat := bbox[0] + r.Float64()*(bbox[2]-bbox[0])
		aLng := bbox[1] + r.Float64()*(bbox[3]-bbox[1])
		bLat := bbox[0] + r.Float64()*(bbox[2]-bbox[0])
		bLng := bbox[1] + r.Float64()*(bbox[3]-bbox[1])
		if _, err := g.RouteWithWeights(aLat, aLng, bLat, bLng, routing.CostWeights{}); err != nil {
			rejected++
			continue
		}
		accepted = append(accepted, pair{aLat, aLng, bLat, bLng})
	}
	return accepted, rejected
}

// acceptanceGraph builds the production graph once per test, with elevation
// LIVE so the unknown-endpoint neighbour-mean propagation (Part 3a) runs — the
// same graph the request path actually routes on.
func acceptanceGraph(t *testing.T) *routing.Graph {
	t.Helper()
	db := connectPG(t)
	repo := newNativeRepo(db, nil, 0).configureElevation(
		routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		true, 0.99,
	)
	g, err := repo.roadGraph()
	if err != nil {
		t.Fatalf("roadGraph: %v", err)
	}
	return g
}

// routeWith routes one pair under a weight set, failing the test on error.
func routeWith(t *testing.T, g *routing.Graph, p pair, w routing.CostWeights) *routing.Path {
	t.Helper()
	path, err := g.RouteWithWeights(p.fromLat, p.fromLng, p.toLat, p.toLng, w)
	if err != nil {
		t.Fatalf("route (%v,%v)->(%v,%v): %v", p.fromLat, p.fromLng, p.toLat, p.toLng, err)
	}
	return path
}

// samePath reports whether two Paths traverse the identical node sequence.
func samePath(a, b *routing.Path) bool {
	if len(a.Nodes) != len(b.Nodes) {
		return false
	}
	for i := range a.Nodes {
		if a.Nodes[i] != b.Nodes[i] {
			return false
		}
	}
	return true
}

// median / quantile over a float slice (pure, no stats dep).
func median(v []float64) float64 {
	if len(v) == 0 {
		return math.NaN()
	}
	sort.Float64s(v)
	n := len(v)
	if n%2 == 1 {
		return v[n/2]
	}
	return (v[n/2-1] + v[n/2]) / 2
}

func quantile(v []float64, q float64) float64 {
	if len(v) == 0 {
		return math.NaN()
	}
	sort.Float64s(v)
	idx := int(q * float64(len(v)-1))
	if idx >= len(v) {
		idx = len(v) - 1
	}
	return v[idx]
}

// TestReportedMetersUnaffected asserts series invariant #1 end-to-end on real
// data: the reported distance is the true meters, independent of weights.
// (a) Under zero weights Path.Meters == Path.Cost (the flat router's cost IS
//
//	the road length — the property test this todo asserts across the whole
//	route, not just on synthetic unit fixtures).
//
// (b) Where the elevation search returns the SAME node path as flat, Meters is
//
//	byte-identical — so weights can change WHICH route, but never corrupt the
//	reported distance of a route.
func TestReportedMetersUnaffected(t *testing.T) {
	g := acceptanceGraph(t)
	pairs, _ := seededPairs(g, provinceBBox, sampleN)
	for _, p := range pairs {
		fp := routeWith(t, g, p, routing.CostWeights{})
		if math.Abs(fp.Meters-fp.Cost) > 1e-6*fp.Meters {
			t.Errorf("flat Meters %v != Cost %v (zero weights must be pure distance)", fp.Meters, fp.Cost)
		}
		for _, w := range []routing.CostWeights{defaultWeights, ascentHeavy} {
			ep := routeWith(t, g, p, w)
			if samePath(fp, ep) && math.Abs(ep.Meters-fp.Meters) > 1e-9 {
				t.Errorf("same path but Meters drifted: flat %v vs elev %v", fp.Meters, ep.Meters)
			}
		}
	}
}

// TestElevationFlatAreaInvariance measures how often the elevation plugin
// reshuffles a route on the FLATTEST 2 km cell in the province (lat 9.84..9.86,
// lng -83.96..-83.94; 33 m relief). No ≤15 m, ≥500-vertex truly-flat box exists
// in this hilly import, so this is the best available control and is recorded
// as UNcertified in the calibration plan. At the default weights the deadband
// damps the gentle slope to ~zero, so elevation and flat routes are near-
// identical — the anti-regression check that catches a broken DEM.
func TestElevationFlatAreaInvariance(t *testing.T) {
	g := acceptanceGraph(t)
	box := [4]float64{9.8400, -83.9599, 9.8600, -83.9400}
	pairs, rejected := seededPairs(g, box, 200)
	if len(pairs) == 0 {
		t.Fatal("no routable pairs in the flat box")
	}

	identical := 0
	var maxMetersDelta float64
	for _, p := range pairs {
		fp := routeWith(t, g, p, routing.CostWeights{})
		ep := routeWith(t, g, p, defaultWeights)
		if samePath(fp, ep) {
			identical++
		}
		if d := ep.Meters/fp.Meters - 1; d > maxMetersDelta {
			maxMetersDelta = d
		}
	}
	identicalPct := 100.0 * float64(identical) / float64(len(pairs))
	t.Logf("flat-box invariance: %d/%d identical (%.1f%%), max meters delta %.4f, rejected %d",
		identical, len(pairs), identicalPct, maxMetersDelta, rejected)

	if identicalPct < 95 {
		t.Errorf("flat invariance %.1f%% identical < 95%% — DEM bias or deadband too small", identicalPct)
	}
	if maxMetersDelta > 0.02 {
		t.Errorf("flat-box meters delta %.4f > 2%%", maxMetersDelta)
	}
}

// TestElevationDetourBounds asserts the p99 detour ceiling (G4): no weight set
// we would contemplate ships a pathological detour. The hard ceiling is 1.25.
func TestElevationDetourBounds(t *testing.T) {
	g := acceptanceGraph(t)
	pairs, _ := seededPairs(g, provinceBBox, sampleN)
	var detours []float64
	for _, p := range pairs {
		fp := routeWith(t, g, p, routing.CostWeights{})
		for _, w := range []routing.CostWeights{defaultWeights, ascentHeavy} {
			ep := routeWith(t, g, p, w)
			detours = append(detours, ep.Meters/fp.Meters)
		}
	}
	sort.Float64s(detours)
	p90 := detours[int(0.90*float64(len(detours)-1))]
	p99 := detours[int(0.99*float64(len(detours)-1))]
	t.Logf("detour bounds: p90 %.4f p99 %.4f over %d weighted routes", p90, p99, len(detours))
	if p99 > 1.25 {
		t.Errorf("p99 meters ratio %.4f > 1.25 — pathological detour ships", p99)
	}
}

// TestElevationFindsClimbAvoidanceCases asserts genuine climb-avoidance cases
// EXIST on real data (G2): at a calibrated weight there are OD pairs where the
// elevation route climbs materially less than flat, within a bounded detour.
func TestElevationFindsClimbAvoidanceCases(t *testing.T) {
	g := acceptanceGraph(t)
	pairs, _ := seededPairs(g, provinceBBox, sampleN)
	var quals int
	for _, p := range pairs {
		fp := routeWith(t, g, p, routing.CostWeights{})
		ep := routeWith(t, g, p, ascentHeavy)
		if ep.AscentM < 0.75*fp.AscentM && ep.Meters <= 1.05*fp.Meters {
			quals++
		}
	}
	t.Logf("climb-avoidance: %d/%d pairs qualify at ascent-heavy weights", quals, len(pairs))
	if quals == 0 {
		t.Errorf("no qualifying climb-avoidance pair in %d pairs — feature has nothing to do", len(pairs))
	}
}

// TestElevationWeightsSweep is the committed subset of the full Part 4a sweep.
// It asserts ONLY the mandatory property G7 (monotonicity of median ascent as
// AscentW rises) — a cheap, genuine guard against a sign error in the cost
// model — and prints the metric table for review.
func TestElevationWeightsSweep(t *testing.T) {
	g := acceptanceGraph(t)
	pairs, rejected := seededPairs(g, provinceBBox, sampleN)
	t.Logf("sweep sample: %d routable pairs (%d rejected: no route/snap)", len(pairs), rejected)

	settings := []sweepPoint{
		{name: "default", w: defaultWeights},
		{name: "asc3_db5", w: routing.CostWeights{AscentW: 3, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 5}},
		{name: "asc6_db5", w: routing.CostWeights{AscentW: 6, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 5}},
		{name: "asc12_db8", w: ascentHeavy},
	}

	flatAscent := make([]float64, len(pairs))
	flatMeters := make([]float64, len(pairs))
	flatExpanded := 0
	for i, p := range pairs {
		fp := routeWith(t, g, p, routing.CostWeights{})
		flatAscent[i] = fp.AscentM
		flatMeters[i] = fp.Meters
		flatExpanded += fp.Expanded
	}

	cols := make([][]float64, len(settings))
	detourCols := make([][]float64, len(settings))
	qual := make([]int, len(settings))
	expanded := make([]int, len(settings))
	for i, p := range pairs {
		for si, s := range settings {
			ep, err := g.RouteWithWeights(p.fromLat, p.fromLng, p.toLat, p.toLng, s.w)
			if err != nil {
				continue
			}
			ar := 1.0
			if flatAscent[i] > 1e-9 {
				ar = ep.AscentM / flatAscent[i]
			}
			cols[si] = append(cols[si], ar)
			detourCols[si] = append(detourCols[si], ep.Meters/flatMeters[i])
			expanded[si] += ep.Expanded
			if ep.AscentM < 0.75*flatAscent[i] && ep.Meters <= 1.05*flatMeters[i] {
				qual[si]++
			}
		}
	}

	t.Logf("flat baseline: %d route (Expanded sum %d)", len(pairs), flatExpanded)
	t.Logf("%-10s | ascent-med | meters-med | p90    | p99    | qualify | expanded", "setting")
	for si, s := range settings {
		t.Logf("%-10s | %.4f     | %.4f     | %.4f | %.4f | %-7d | %d",
			s.name, median(cols[si]), median(detourCols[si]),
			quantile(detourCols[si], 0.90), quantile(detourCols[si], 0.99),
			qual[si], expanded[si])
	}

	// G7: median ascent ratio is non-increasing as AscentW rises.
	prev := 0.0
	for si, s := range settings {
		m := median(cols[si])
		if si > 0 && m > prev+1e-6 {
			t.Errorf("monotonicity violated: %s ascent-med %.4f > previous %.4f (sign error?)", s.name, m, prev)
		}
		prev = m
	}
}

// sweepPoint is one row of the WEIGHT RESPONSE curve.
type sweepPoint struct {
	name string
	w    routing.CostWeights
}

// G6 — the certified-flat-street Δz estimator. The estimator is SPLIT in two:
//
//   - the pure statistic and the flatness certification live in
//     navigation_repo.go (flatEdgeDeadbandM / sampleQuantile / flatEdgeAbsDz),
//     DB-free and unit-tested on synthetic Δz sets; and
//   - this collector, which alone touches the live graph: it loads the two
//     tables and hands them to the pure certifier.
//
// See flatEdgeAbsDz for the flatness rule. It is deliberately NOT "sort by
// |Δz|" (that is circular — it would always read a tiny spread): it certifies
// TERRAIN (9-cell local relief, computed from the whole vertex set) around the
// edge's endpoints, independently of the edge's own Δz.

// collectFlatEdgeAbsDz loads the region's vertices and edges and returns the
// |Δz| samples of its certified-flat edges. Empty means the rule certified
// nothing (a real finding, never silently treated as a zero deadband — the pure
// estimator falls back instead).
func collectFlatEdgeAbsDz(t *testing.T, db *sqlx.DB, regionID string) []float64 {
	t.Helper()
	var verts []roadNode
	if err := db.Select(&verts, `
		SELECT id, lat, lng, elevation_m
		FROM road_network_vertices_pgr
		WHERE region_id = $1`, regionID); err != nil {
		t.Fatalf("load vertices for %q: %v", regionID, err)
	}
	var edges []roadEdge
	if err := db.Select(&edges, `
		SELECT source, target, cost
		FROM road_network_edges_pgr
		WHERE region_id = $1`, regionID); err != nil {
		t.Fatalf("load edges for %q: %v", regionID, err)
	}
	return flatEdgeAbsDz(verts, edges)
}

// defaultRegionID returns the region the resolver falls back to, so the
// calibration measures the same graph production routes on.
func defaultRegionID(t *testing.T, db *sqlx.DB) string {
	t.Helper()
	regions, err := loadRegisteredRegions(db)
	if err != nil {
		t.Fatalf("load routing regions: %v", err)
	}
	for _, r := range regions {
		if r.Default {
			return r.RegionID
		}
	}
	if len(regions) > 0 {
		return regions[0].RegionID
	}
	t.Skip("no routing regions registered")
	return ""
}

// TestElevationDeadbandCalibration is the G6 MEASUREMENT run: it collects the
// certified-flat |Δz| samples from the live graph and reports the calibrated
// DeadbandM that was written into config.go. It asserts only that the result is
// a usable, finite value of plausible magnitude; the value itself is recorded in
// api_plans/[elevation]_calibration_and_rollout_gate.md.
func TestElevationDeadbandCalibration(t *testing.T) {
	db := connectPG(t)
	regionID := defaultRegionID(t, db)
	samples := collectFlatEdgeAbsDz(t, db, regionID)
	if len(samples) == 0 {
		t.Fatalf("no certified-flat edges in region %q", regionID)
	}

	floor := sampleQuantile(append([]float64(nil), samples...), 0.50)
	measured := flatEdgeDeadbandM(samples)

	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	at := func(q float64) float64 { return sorted[int(q*float64(len(sorted)-1))] }

	t.Logf("G6 flat-street calibration (%s): rule h<=%.0fm AND 3x3(%.3f deg) relief<=%.0fm; n=%d",
		regionID, flatEdgeMaxLengthM, flatReliefCellDeg, flatReliefMaxM, len(samples))
	t.Logf("  |dz| p50=%.3f p90=%.3f p95=%.3f p99=%.3f max=%.3f (DEM noise floor p50=%.3f)",
		at(0.50), at(0.90), at(0.95), at(0.99), sorted[len(sorted)-1], floor)
	t.Logf("  calibrated DeadbandM = p95 = %.1f m", measured)

	if math.IsNaN(measured) || math.IsInf(measured, 0) || measured <= 0 {
		t.Fatalf("calibrated deadband %v is not a usable value", measured)
	}
	if measured > 20 {
		t.Errorf("calibrated deadband %.1f m is implausibly large for certified-flat streets", measured)
	}
}

// BenchmarkRouteRealSJ is the real-data cost benchmark (Part 5): absolute
// per-route latency over the live 183k-edge graph, flat vs elevation. This is
// the input plan 06 needs for its per-region latency budget.
func BenchmarkRouteRealSJ(b *testing.B) {
	db, err := connectBenchPG(b)
	if err != nil {
		b.Skipf("no database available: %v", err)
	}
	repo := newNativeRepo(db, nil, 0).configureElevation(
		routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		true, 0.99,
	)
	g, err := repo.roadGraph()
	if err != nil {
		b.Skipf("no road network: %v", err)
	}
	pairs, _ := seededPairs(g, provinceBBox, 20)
	b.ReportAllocs()

	b.Run("flat", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			p := pairs[i%len(pairs)]
			if _, err := g.RouteWithWeights(p.fromLat, p.fromLng, p.toLat, p.toLng, routing.CostWeights{}); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("elev", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			p := pairs[i%len(pairs)]
			if _, err := g.RouteWithWeights(p.fromLat, p.fromLng, p.toLat, p.toLng, defaultWeights); err != nil {
				b.Fatal(err)
			}
		}
	})
}

// connectBenchPG connects to the live DB for a benchmark; it skips rather than
// fails when the DB is absent (same convention as the other integration paths).
func connectBenchPG(b *testing.B) (*sqlx.DB, error) {
	b.Helper()
	return sqlx.Connect("postgres", config.Load().DatabaseURL())
}
