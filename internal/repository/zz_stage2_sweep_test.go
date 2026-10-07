//go:build integration

package repository

// Stage 2 scratch instrument for the now-condensed deadband-calibrate-and-flip
// execution plan (condensed in api_plans/STATUS.md under [elevation]).
//
// NOT a shipped test: this is the offline N=2000 Part 4a sweep and the G5
// real-graph hot-path re-measurement at the operating point. It mirrors the
// convention of zz_sweep2_test.go (build-tagged integration, zz_ name) and
// reuses the COMMITTED seeded generator `seededPairs` (seed 42), so its sample
// is the same distribution the committed guard uses — just at the plan's full
// N. The committed TestElevationWeightsSweep stays the small guard.
//
// Run:
//
//	go test -tags=integration -run TestZZStage2Sweep2000 -v -count=1 \
//	    -timeout 90m ./internal/repository/
//	go test -tags=integration -run '^$' -bench BenchmarkRouteRealSJStage2 \
//	    -benchmem -count=1 -timeout 30m ./internal/repository/

import (
	"fmt"
	"os"
	"testing"

	"ride-hailing-api/internal/routing"
)

// stage2N is the plan's full sample size (Stage 2, item 1).
const stage2N = 2000

// The calibrated deadband (Stage 1 / G6) and the by-eye operating point, named
// distinctly so the historical committed probes (defaultWeights/ascentHeavy)
// are not silently re-pointed.
var (
	stage2Asc12DB38 = routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}
	stage2Asc12DB8  = routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 8}
)

// TestZZStage2Sweep2000 runs the Part 4a grid at N=2000. It reports the full
// metric set per setting (ascent-median ratio, meters-median, p90, p99,
// qualifying pairs, Expanded) and asserts the mandatory G7 monotonicity along
// the AscentW axis at DeadbandM=3.8. It is deliberately scratch: run explicitly,
// never part of the committed suite.
func TestZZStage2Sweep2000(t *testing.T) {
	if os.Getenv("RUN_STAGE2_SWEEP") != "1" {
		t.Skip("scratch N=2000 sweep: set RUN_STAGE2_SWEEP=1 to run (~41 min)")
	}
	g := acceptanceGraph(t)
	pairs, rejected := seededPairs(g, provinceBBox, stage2N)
	fmt.Printf("STAGE2 sample: %d routable pairs, %d rejected (no route/no snap)\n", len(pairs), rejected)

	// Flat baseline, computed once. Only scalars are retained so the 2,000
	// full paths do not sit in memory for the whole sweep.
	flatAscent := make([]float64, len(pairs))
	flatMeters := make([]float64, len(pairs))
	flatExpanded := 0
	flatClimbing := 0
	for i, p := range pairs {
		fp := routeWith(t, g, p, routing.CostWeights{})
		flatAscent[i] = fp.AscentM
		flatMeters[i] = fp.Meters
		flatExpanded += fp.Expanded
		if fp.AscentM > 1e-9 {
			flatClimbing++
		}
	}
	fmt.Printf("STAGE2 flat baseline: Expanded sum %d, pairs with AscentM>0: %d/%d\n",
		flatExpanded, flatClimbing, len(pairs))

	// Part 4a grid. `weighted` excludes the (all-1.0) flat row from the ratio
	// tables but keeps the zero-weight baseline reported separately. The
	// AscentW axis is run at the CALIBRATED deadband (3.8); the DeadbandM axis
	// at asc12; `default_1.5_db3` is the historical shipped default; asc12_db8
	// is the by-eye point.
	settings := []sweepPoint{
		{name: "default_1.5_db3", w: routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3}},
		{name: "asc0.5_db3.8", w: routing.CostWeights{AscentW: 0.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}},
		{name: "asc1.5_db3.8", w: routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}},
		{name: "asc3_db3.8", w: routing.CostWeights{AscentW: 3, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}},
		{name: "asc6_db3.8", w: routing.CostWeights{AscentW: 6, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}},
		{name: "asc12_db3.8", w: stage2Asc12DB38},
		{name: "asc25_db3.8", w: routing.CostWeights{AscentW: 25, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}},
		{name: "asc12_db3", w: routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3}},
		{name: "asc12_db5", w: routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 5}},
		{name: "asc12_db8", w: stage2Asc12DB8},
	}

	ascentRatios := make([][]float64, len(settings))
	metersRatios := make([][]float64, len(settings))
	qual := make([]int, len(settings))
	expanded := make([]int, len(settings))
	weightedRoutes := make([]int, len(settings))

	for i, p := range pairs {
		for si, s := range settings {
			ep, err := g.RouteWithWeights(p.fromLat, p.fromLng, p.toLat, p.toLng, s.w)
			if err != nil {
				continue
			}
			weightedRoutes[si]++
			ar := 1.0
			if flatAscent[i] > 1e-9 {
				ar = ep.AscentM / flatAscent[i]
			}
			ascentRatios[si] = append(ascentRatios[si], ar)
			metersRatios[si] = append(metersRatios[si], ep.Meters/flatMeters[i])
			expanded[si] += ep.Expanded
			if ep.AscentM < 0.75*flatAscent[i] && ep.Meters <= 1.05*flatMeters[i] {
				qual[si]++
			}
		}
	}

	fmt.Printf("STAGE2 %-16s | ascent-med | meters-med | p90    | p99    | qualify | expanded | routed\n", "setting")
	for si, s := range settings {
		fmt.Printf("STAGE2 %-16s | %.4f     | %.4f     | %.4f | %.4f | %-7d | %-8d | %d\n",
			s.name, median(ascentRatios[si]), median(metersRatios[si]),
			quantile(metersRatios[si], 0.90), quantile(metersRatios[si], 0.99),
			qual[si], expanded[si], weightedRoutes[si])
	}

	// G7 monotonicity along the AscentW axis (fixed DescentW=0.3, MaxGrade=0.15,
	// DeadbandM=3.8): the first six settings in `settings`.
	axis := []int{1, 2, 3, 4, 5, 6}
	prev := 0.0
	for k, si := range axis {
		m := median(ascentRatios[si])
		fmt.Printf("STAGE2 MONO %-12s ascent-med %.4f\n", settings[si].name, m)
		if k > 0 && m > prev+1e-6 {
			t.Errorf("G7 monotonicity violated: %s ascent-med %.4f > previous %.4f",
				settings[si].name, m, prev)
		}
		prev = m
	}
}

// BenchmarkRouteRealSJStage2 is the G5 re-measurement the 2026-09-29 audit
// flagged: the recorded 1.08x was taken at {1.5,0.3,0.15,3}, NOT at the shipped
// operating point. This measures the live 183k-edge graph at the calibrated
// deadband (asc12_db3.8) and the by-eye point (asc12_db8) against the flat
// router.
func BenchmarkRouteRealSJStage2(b *testing.B) {
	db, err := connectBenchPG(b)
	if err != nil {
		b.Skipf("no database available: %v", err)
	}
	repo := newNativeRepo(db, nil, 0).configureElevation(routing.CostWeights{}, true, 0.99)
	g, err := repo.roadGraph()
	if err != nil {
		b.Skipf("no road network: %v", err)
	}
	pairs, _ := seededPairs(g, provinceBBox, 20)
	b.ReportAllocs()

	run := func(b *testing.B, w routing.CostWeights) {
		for i := 0; i < b.N; i++ {
			p := pairs[i%len(pairs)]
			if _, err := g.RouteWithWeights(p.fromLat, p.fromLng, p.toLat, p.toLng, w); err != nil {
				b.Fatal(err)
			}
		}
	}
	b.Run("flat", func(b *testing.B) { run(b, routing.CostWeights{}) })
	b.Run("asc12_db3.8", func(b *testing.B) { run(b, stage2Asc12DB38) })
	b.Run("asc12_db8", func(b *testing.B) { run(b, stage2Asc12DB8) })
}
