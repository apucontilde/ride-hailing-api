//go:build integration

package repository

import (
	"fmt"
	"math"
	"math/rand"
	"sort"
	"testing"

	"ride-hailing-api/internal/routing"
)

type spair struct{ aLat, aLng, bLat, bLng float64 }

func zzSamplePairs(g *routing.Graph, bbox [4]float64, n int) []spair {
	r := rand.New(rand.NewSource(42))
	var out []spair
	tries := 0
	for len(out) < n && tries < n*10 {
		tries++
		aLat := bbox[0] + r.Float64()*(bbox[2]-bbox[0])
		aLng := bbox[1] + r.Float64()*(bbox[3]-bbox[1])
		bLat := bbox[0] + r.Float64()*(bbox[2]-bbox[0])
		bLng := bbox[1] + r.Float64()*(bbox[3]-bbox[1])
		if _, err := g.RouteWithWeights(aLat, aLng, bLat, bLng, routing.CostWeights{}); err != nil {
			continue
		}
		out = append(out, spair{aLat, aLng, bLat, bLng})
	}
	return out
}

func TestZZSweep2(t *testing.T) {
	db := connectPG(t)
	repo := newNativeRepo(db, nil, 0).configureElevation(
		routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		true, 0.99,
	)
	g, err := repo.roadGraph()
	if err != nil {
		t.Fatal(err)
	}
	bbox := [4]float64{8.99, -84.54, 10.24, -83.39}
	pairs := zzSamplePairs(g, bbox, 250)

	flat := make(map[int]*routing.Path, len(pairs))
	for i, p := range pairs {
		fp, err := g.RouteWithWeights(p.aLat, p.aLng, p.bLat, p.bLng, routing.CostWeights{})
		if err != nil {
			t.Fatalf("flat route %d: %v", i, err)
		}
		flat[i] = fp
	}

	settings := []struct {
		name string
		w    routing.CostWeights
	}{
		{"default", routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3}},
		{"asc3_db5", routing.CostWeights{AscentW: 3, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 5}},
		{"asc6_db5", routing.CostWeights{AscentW: 6, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 5}},
		{"asc12_db8", routing.CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 8}},
		{"asc25_db8", routing.CostWeights{AscentW: 25, DescentW: 0.1, MaxGrade: 0.25, DeadbandM: 8}},
	}
	n := len(settings)
	medAscent := make([]*ratios, n)
	medMeters := make([]*ratios, n)
	detour := make([]*ratios, n)
	quals := make([]int, n)
	for i := range settings {
		medAscent[i] = &ratios{}
		medMeters[i] = &ratios{}
		detour[i] = &ratios{}
	}
	for i, p := range pairs {
		fp := flat[i]
		for si, s := range settings {
			ep, err := g.RouteWithWeights(p.aLat, p.aLng, p.bLat, p.bLng, s.w)
			if err != nil {
				continue
			}
			ar := ep.AscentM / fp.AscentM
			if fp.AscentM < 1e-9 {
				ar = 1
			}
			mr := ep.Meters / fp.Meters
			medAscent[si].add(ar)
			medMeters[si].add(mr)
			detour[si].add(mr)
			if ep.AscentM < 0.75*fp.AscentM && ep.Meters <= 1.05*fp.Meters {
				quals[si]++
			}
		}
	}
	for si, s := range settings {
		fmt.Printf("SWEEP %-10s | ascent-med %.4f | meters-med %.4f p90 %.4f p99 %.4f | qualify %d\n",
			s.name, medAscent[si].median(), medMeters[si].median(), detour[si].p(0.90), detour[si].p(0.99), quals[si])
	}
}

type ratios struct{ v []float64 }

func (r *ratios) add(x float64) { r.v = append(r.v, x) }
func (r *ratios) median() float64 {
	if len(r.v) == 0 {
		return math.NaN()
	}
	sort.Float64s(r.v)
	n := len(r.v)
	if n%2 == 1 {
		return r.v[n/2]
	}
	return (r.v[n/2-1] + r.v[n/2]) / 2
}
func (r *ratios) p(q float64) float64 {
	if len(r.v) == 0 {
		return math.NaN()
	}
	sort.Float64s(r.v)
	idx := int(q * float64(len(r.v)-1))
	if idx >= len(r.v) {
		idx = len(r.v) - 1
	}
	return r.v[idx]
}
