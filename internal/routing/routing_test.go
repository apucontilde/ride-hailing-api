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
