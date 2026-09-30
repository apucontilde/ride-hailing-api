package repository

import (
	"testing"

	"ride-hailing-api/internal/routing"
)

// DB-free unit tests for the elevation plumbing's pure helpers: the NULL ->
// "unknown" (EleM 0) conversion, the coverage/known accounting, and the
// NULL-endpoint fix-up that keeps an unknown vertex from reading as sea level
// beside a real altitude (Part 3a).

func TestToRoutingNodesNULLvsZero(t *testing.T) {
	ele100 := 100.0
	zero := 0.0
	rows := []roadNode{
		{ID: 1, Lat: 1, Lng: 1, EleM: &ele100}, // real sample
		{ID: 2, Lat: 2, Lng: 2, EleM: &zero},   // sea level
		{ID: 3, Lat: 3, Lng: 3, EleM: nil},     // no sample
	}
	nodes, known := toRoutingNodes(rows)

	if len(nodes) != 3 {
		t.Fatalf("got %d nodes, want 3", len(nodes))
	}
	if nodes[0].EleM != 100 {
		t.Errorf("node 1 EleM = %v, want 100", nodes[0].EleM)
	}
	if nodes[1].EleM != 0 {
		t.Errorf("node 2 EleM = %v, want 0", nodes[1].EleM)
	}
	if nodes[2].EleM != 0 {
		t.Errorf("node 3 EleM = %v, want 0 (unknown)", nodes[2].EleM)
	}
	// Only the two non-NULL rows are "known" — sea level counts, no-sample does not.
	if !known[1] || !known[2] || known[3] {
		t.Errorf("known = %v; want {1:true, 2:true, 3:false}", known)
	}
}

func TestFillUnknownElevationPropagatesKnownNeighbour(t *testing.T) {
	nodes := []routing.Node{
		{ID: 1, EleM: 100}, // known
		{ID: 2, EleM: 0},   // unknown
		{ID: 3, EleM: 50},  // known
	}
	edges := []routing.Edge{
		{Source: 1, Target: 2, Cost: 10},
		{Source: 2, Target: 3, Cost: 10},
	}
	known := map[int64]bool{1: true, 3: true}

	fillUnknownElevation(nodes, edges, known)

	// Node 2's two known neighbours average to 75.
	if nodes[1].EleM != 75 {
		t.Errorf("node 2 EleM = %v, want 75", nodes[1].EleM)
	}
	// Known nodes are untouched.
	if nodes[0].EleM != 100 || nodes[2].EleM != 50 {
		t.Errorf("known nodes mutated: %v", nodes)
	}
}

func TestFillUnknownElevationNoKnownNeighbourKeepsZero(t *testing.T) {
	nodes := []routing.Node{
		{ID: 1, EleM: 0}, // unknown
		{ID: 2, EleM: 0}, // unknown
	}
	edges := []routing.Edge{{Source: 1, Target: 2, Cost: 10}}
	known := map[int64]bool{}

	fillUnknownElevation(nodes, edges, known)

	for i, n := range nodes {
		if n.EleM != 0 {
			t.Errorf("node %d EleM = %v, want 0 (no known neighbour)", i, n.EleM)
		}
	}
}

func TestResolveElevationGate(t *testing.T) {
	// A repo with elevation configured but inactive config must resolve to flat.
	r := &NativeNavigationRepo{
		elevOn:   false,
		elev:     routing.CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3},
		minCover: 0.99,
	}
	nodes := []routing.Node{{ID: 1, EleM: 100}, {ID: 2, EleM: 110}}
	edges := []routing.Edge{{Source: 1, Target: 2, Cost: 10}}
	known := map[int64]bool{1: true, 2: true}

	if w := r.resolveElevation(nodes, edges, known); w != (routing.CostWeights{}) {
		t.Errorf("disabled config resolved to non-flat weights %+v", w)
	}

	// Enabled + full coverage -> the configured weights.
	r.elevOn = true
	if w := r.resolveElevation(nodes, edges, known); w != r.elev {
		t.Errorf("enabled full coverage resolved to %+v, want %+v", w, r.elev)
	}

	// Enabled but zero coverage -> flat.
	if w := r.resolveElevation(nodes, edges, map[int64]bool{}); w != (routing.CostWeights{}) {
		t.Errorf("zero coverage resolved to non-flat weights %+v", w)
	}
}
