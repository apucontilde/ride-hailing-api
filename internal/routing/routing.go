// Package routing implements shortest-path routing over a road network
// graph. pgRouting is not available in the dev Postgres image, so the API
// loads the graph once from PostGIS tables and runs A* with a plain
// straight-line (haversine) heuristic. Edge costs are road lengths in
// meters, so the accumulated cost is the route distance in meters.
package routing

import (
	"container/heap"
	"errors"
	"math"
)

var ErrNoRoute = errors.New("no route found")

// Node is a road network vertex with a WGS84 coordinate.
type Node struct {
	ID  int64
	Lat float64
	Lng float64
}

// Edge is a directed traverse of a road segment. Cost is the segment length
// in meters. The graph is built undirected, so each stored edge is added in
// both directions.
type Edge struct {
	Source int64
	Target int64
	Cost   float64
}

type adjEdge struct {
	to   int64
	cost float64
}

// Graph is an immutable road network ready for point-to-point routing.
type Graph struct {
	nodes map[int64]Node
	list  []Node
	adj   map[int64][]adjEdge
}

// NewGraph builds a graph from a node list and edge list. Self-loops and
// edges whose endpoints are not in the node set are dropped.
func NewGraph(nodes []Node, edges []Edge) *Graph {
	g := &Graph{
		nodes: make(map[int64]Node, len(nodes)),
		list:  make([]Node, 0, len(nodes)),
		adj:   make(map[int64][]adjEdge),
	}
	for _, n := range nodes {
		if _, ok := g.nodes[n.ID]; ok {
			continue
		}
		g.nodes[n.ID] = n
		g.list = append(g.list, n)
	}
	for _, e := range edges {
		if _, ok := g.nodes[e.Source]; !ok {
			continue
		}
		if _, ok := g.nodes[e.Target]; !ok {
			continue
		}
		if e.Source == e.Target || e.Cost <= 0 {
			continue
		}
		g.adj[e.Source] = append(g.adj[e.Source], adjEdge{to: e.Target, cost: e.Cost})
		g.adj[e.Target] = append(g.adj[e.Target], adjEdge{to: e.Source, cost: e.Cost})
	}
	return g
}

// NodeByID returns the node with the given ID.
func (g *Graph) NodeByID(id int64) (Node, bool) {
	n, ok := g.nodes[id]
	return n, ok
}

// NearestNode returns the node closest to the given coordinates.
func (g *Graph) NearestNode(lat, lng float64) (Node, bool) {
	best := Node{}
	bestD := math.MaxFloat64
	found := false
	for _, n := range g.list {
		d := haversineM(n.Lat, n.Lng, lat, lng)
		if d < bestD {
			bestD = d
			best = n
			found = true
		}
	}
	return best, found
}

// Route returns the ordered node IDs of the shortest path from (fromLat,
// fromLng) to (toLat, toLng), snapping both endpoints to their nearest nodes,
// plus the total distance in meters. The first path node is the snapped
// origin and the last is the snapped destination.
func (g *Graph) Route(fromLat, fromLng, toLat, toLng float64) ([]int64, float64, error) {
	start, ok := g.NearestNode(fromLat, fromLng)
	if !ok {
		return nil, 0, ErrNoRoute
	}
	goal, ok := g.NearestNode(toLat, toLng)
	if !ok {
		return nil, 0, ErrNoRoute
	}

	if start.ID == goal.ID {
		return []int64{start.ID}, 0, nil
	}

	open := &nodeHeap{}
	heap.Init(open)
	heap.Push(open, &item{node: start.ID, g: 0, f: 0})

	cameFrom := make(map[int64]int64)
	gScore := map[int64]float64{start.ID: 0}
	closed := make(map[int64]bool)

	for open.Len() > 0 {
		cur := heap.Pop(open).(*item)
		if closed[cur.node] {
			continue
		}
		closed[cur.node] = true

		if cur.node == goal.ID {
			return g.reconstruct(cameFrom, start.ID, goal.ID, gScore[goal.ID])
		}

		for _, e := range g.adj[cur.node] {
			if closed[e.to] {
				continue
			}
			tent := gScore[cur.node] + e.cost
			if prev, ok := gScore[e.to]; !ok || tent < prev {
				cameFrom[e.to] = cur.node
				gScore[e.to] = tent
				heur := g.haversineTo(e.to, goal.ID)
				heap.Push(open, &item{node: e.to, g: tent, f: tent + heur})
			}
		}
	}

	return nil, 0, ErrNoRoute
}

func (g *Graph) haversineTo(from, to int64) float64 {
	a := g.nodes[from]
	b := g.nodes[to]
	return haversineM(a.Lat, a.Lng, b.Lat, b.Lng)
}

func (g *Graph) reconstruct(cameFrom map[int64]int64, start, goal int64, cost float64) ([]int64, float64, error) {
	path := []int64{goal}
	for node := goal; node != start; {
		prev, ok := cameFrom[node]
		if !ok {
			return nil, 0, ErrNoRoute
		}
		path = append(path, prev)
		node = prev
	}
	for i, j := 0, len(path)-1; i < j; i, j = i+1, j-1 {
		path[i], path[j] = path[j], path[i]
	}
	return path, cost, nil
}

func haversineM(lat1, lng1, lat2, lng2 float64) float64 {
	const r = 6371000.0
	phi1 := lat1 * math.Pi / 180
	phi2 := lat2 * math.Pi / 180
	dPhi := (lat2 - lat1) * math.Pi / 180
	dLambda := (lng2 - lng1) * math.Pi / 180
	a := math.Sin(dPhi/2)*math.Sin(dPhi/2) +
		math.Cos(phi1)*math.Cos(phi2)*math.Sin(dLambda/2)*math.Sin(dLambda/2)
	return 2 * r * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

type item struct {
	node int64
	g    float64
	f    float64
}

type nodeHeap []*item

func (h nodeHeap) Len() int            { return len(h) }
func (h nodeHeap) Less(i, j int) bool  { return h[i].f < h[j].f }
func (h nodeHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *nodeHeap) Push(x interface{}) { *h = append(*h, x.(*item)) }
func (h *nodeHeap) Pop() interface{} {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}
