package routing

import (
	"errors"
	"testing"
)

// Test graph geometry:
//
//	A(10.0,10.0) --11132m--> B(10.1,10.0) --11132m--> C(10.1,10.1)
//	                   \
//	                    11132m
//	                     \
//	                      D(10.2,10.0)
//
//	X(20.0,20.0)  -- isolated node, no edges.
func testGraph() *Graph {
	nodes := []Node{
		{ID: 1, Lat: 10.0, Lng: 10.0}, // A
		{ID: 2, Lat: 10.1, Lng: 10.0}, // B
		{ID: 3, Lat: 10.1, Lng: 10.1}, // C
		{ID: 4, Lat: 10.2, Lng: 10.0}, // D
		{ID: 5, Lat: 20.0, Lng: 20.0}, // X
	}
	edges := []Edge{
		{Source: 1, Target: 2, Cost: 11132},
		{Source: 2, Target: 1, Cost: 11132},
		{Source: 2, Target: 3, Cost: 11132},
		{Source: 1, Target: 4, Cost: 22264},
	}
	return NewGraph(nodes, edges)
}

func TestRouteDirectNeighbor(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.1, 10.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 2 || path[0] != 1 || path[1] != 2 {
		t.Fatalf("expected path [1 2], got %v", path)
	}
	if cost != 11132 {
		t.Fatalf("expected cost 11132, got %v", cost)
	}
}

func TestRouteMultiHop(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.1, 10.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 3 || path[0] != 1 || path[1] != 2 || path[2] != 3 {
		t.Fatalf("expected path [1 2 3], got %v", path)
	}
	if cost != 22264 {
		t.Fatalf("expected cost 22264, got %v", cost)
	}
}

func TestRoutePicksCheapestOfTwo(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.2, 10.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 2 || path[0] != 1 || path[1] != 4 {
		t.Fatalf("expected path [1 4], got %v", path)
	}
	if cost != 22264 {
		t.Fatalf("expected cost 22264, got %v", cost)
	}
}

func TestRouteUnreachable(t *testing.T) {
	g := testGraph()
	_, _, err := g.Route(10.0, 10.0, 20.0, 20.0)
	if !errors.Is(err, ErrNoRoute) {
		t.Fatalf("expected ErrNoRoute, got %v", err)
	}
}

func TestRouteSameStartEnd(t *testing.T) {
	g := testGraph()
	path, cost, err := g.Route(10.0, 10.0, 10.0, 10.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(path) != 1 || path[0] != 1 {
		t.Fatalf("expected path [1], got %v", path)
	}
	if cost != 0 {
		t.Fatalf("expected zero cost, got %v", cost)
	}
}

func TestRouteEmptyGraph(t *testing.T) {
	g := NewGraph(nil, nil)
	_, _, err := g.Route(10.0, 10.0, 10.1, 10.1)
	if !errors.Is(err, ErrNoRoute) {
		t.Fatalf("expected ErrNoRoute on empty graph, got %v", err)
	}
}

func TestNearestNode(t *testing.T) {
	g := testGraph()
	n, ok := g.NearestNode(10.05, 10.01)
	if !ok {
		t.Fatal("expected a nearest node")
	}
	if n.ID != 2 {
		t.Fatalf("expected node 2, got %d", n.ID)
	}
}

// grid3x3 returns a 3x3 lattice of nodes with no edges, exercising multiple
// cells and cell boundaries.
func grid3x3() *Graph {
	var nodes []Node
	for i := 0; i < 3; i++ {
		for j := 0; j < 3; j++ {
			nodes = append(nodes, Node{
				ID:  int64(i*3 + j + 1),
				Lat: 10.0 + float64(i)*0.1,
				Lng: 10.0 + float64(j)*0.1,
			})
		}
	}
	return NewGraph(nodes, nil)
}

func TestNearestNodeGridEquivalent(t *testing.T) {
	grids := map[string]*Graph{
		"testGraph": testGraph(),
		"grid3x3":   grid3x3(),
	}
	points := []struct {
		lat, lng float64
	}{
		{10.05, 10.01},   // interior
		{10.0, 10.0},     // exactly on a node
		{10.055, 10.055}, // near a cell corner
		{10.19, 10.01},   // near the bbox edge
		{10.2, 10.2},     // on bbox max corner
	}
	for name, g := range grids {
		for _, p := range points {
			want, wantOK := g.scanNearest(p.lat, p.lng)
			got, gotOK := g.gridNearest(p.lat, p.lng)
			if wantOK != gotOK {
				t.Fatalf("%s: point (%.4f,%.4f): scan ok=%v grid ok=%v", name, p.lat, p.lng, wantOK, gotOK)
			}
			if wantOK && (got.ID != want.ID) {
				t.Fatalf("%s: point (%.4f,%.4f): scan=%d grid=%d", name, p.lat, p.lng, want.ID, got.ID)
			}
		}
	}
}

func TestNearestNodeGridEquivalentRandom(t *testing.T) {
	grids := map[string]*Graph{
		"testGraph": testGraph(),
		"grid3x3":   grid3x3(),
	}
	// Deterministic sweep across the bbox and beyond, including points that
	// hash to clamped border cells or far outside the grid.
	for name, g := range grids {
		for i := 0; i < 500; i++ {
			lat := 8.0 + float64(i%37)*0.4
			lng := 9.5 + float64(i%29)*0.5
			want, wantOK := g.scanNearest(lat, lng)
			got, gotOK := g.gridNearest(lat, lng)
			if wantOK != gotOK {
				t.Fatalf("%s: point (%.4f,%.4f): scan ok=%v grid ok=%v", name, lat, lng, wantOK, gotOK)
			}
			if wantOK && (got.ID != want.ID) {
				t.Fatalf("%s: point (%.4f,%.4f): scan=%d grid=%d", name, lat, lng, want.ID, got.ID)
			}
		}
	}
}

func TestNearestNodeGridOutOfBounds(t *testing.T) {
	g := testGraph()
	for _, p := range []struct{ lat, lng float64 }{
		{30.0, 30.0},   // far outside the bbox
		{5.0, 5.0},     // below the bbox
		{-10.0, 40.0},  // mixed out-of-bounds
		{10.15, 10.15}, // just outside on one axis
	} {
		n, ok := g.gridNearest(p.lat, p.lng)
		if !ok || n.ID == 0 {
			t.Fatalf("gridNearest(%v) must return a valid node without panicking, got %+v ok=%v", p, n, ok)
		}
	}
}

func TestNearestNodeGridDegenerate(t *testing.T) {
	single := NewGraph([]Node{{ID: 1, Lat: 10.0, Lng: 10.0}}, nil)
	if _, ok := single.NearestNode(10.0, 10.0); !ok {
		t.Fatal("expected single-node graph to snap")
	}
	if _, ok := single.NearestNode(20.0, 30.0); !ok {
		t.Fatal("expected out-of-range query on single-node graph to clamp to the node")
	}

	empty := NewGraph(nil, nil)
	if _, ok := empty.NearestNode(10.0, 10.0); ok {
		t.Fatal("expected empty graph to return no node")
	}
}
