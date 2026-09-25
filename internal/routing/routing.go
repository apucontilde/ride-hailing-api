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

	// Uniform spatial grid over the node bbox: cells holds node IDs,
	// bucketed by row-major index row*gridCols+col. Used to answer
	// NearestNode in ~O(1) instead of a linear scan.
	gridRows, gridCols       int
	gridMinLat, gridMinLng   float64
	gridCellLat, gridCellLng float64
	cells                    [][]int64
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
	g.buildGrid()
	return g
}

// minGridSpan is the floor for a grid axis span, so single-node or single-row
// graphs never divide by zero when hashing nodes into cells.
const minGridSpan = 1e-9

// buildGrid buckets every node into a uniform grid over the node bbox. The
// number of cells per axis is ceil(sqrt(n)), giving ~one node per cell on
// average for reasonably uniform networks.
func (g *Graph) buildGrid() {
	n := len(g.list)
	if n == 0 {
		return
	}
	minLat, minLng := g.list[0].Lat, g.list[0].Lng
	maxLat, maxLng := minLat, minLng
	for _, node := range g.list[1:] {
		minLat = min(minLat, node.Lat)
		maxLat = max(maxLat, node.Lat)
		minLng = min(minLng, node.Lng)
		maxLng = max(maxLng, node.Lng)
	}
	spanLat := max(maxLat-minLat, minGridSpan)
	spanLng := max(maxLng-minLng, minGridSpan)

	c := int(math.Ceil(math.Sqrt(float64(n))))
	g.gridRows, g.gridCols = c, c
	g.gridMinLat, g.gridMinLng = minLat, minLng
	g.gridCellLat = spanLat / float64(c)
	g.gridCellLng = spanLng / float64(c)
	g.cells = make([][]int64, c*c)

	for _, node := range g.list {
		idx := g.rowFor(node.Lat)*g.gridCols + g.colFor(node.Lng)
		g.cells[idx] = append(g.cells[idx], node.ID)
	}
}

func (g *Graph) rowFor(lat float64) int {
	f := (lat - g.gridMinLat) / g.gridCellLat
	if f <= 0 {
		return 0
	}
	if f >= float64(g.gridRows-1) {
		return g.gridRows - 1
	}
	return int(f)
}

func (g *Graph) colFor(lng float64) int {
	f := (lng - g.gridMinLng) / g.gridCellLng
	if f <= 0 {
		return 0
	}
	if f >= float64(g.gridCols-1) {
		return g.gridCols - 1
	}
	return int(f)
}

// NodeByID returns the node with the given ID.
func (g *Graph) NodeByID(id int64) (Node, bool) {
	n, ok := g.nodes[id]
	return n, ok
}

// NearestNode returns the node closest to the given coordinates, using the
// spatial grid index.
func (g *Graph) NearestNode(lat, lng float64) (Node, bool) {
	return g.gridNearest(lat, lng)
}

// scanNearest is the linear haversine scan over the node list. It is retained
// as the reference implementation: tests and benchmarks cross-check the grid
// index against it for identical results.
func (g *Graph) scanNearest(lat, lng float64) (Node, bool) {
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

// gridNearest finds the nearest node via the spatial grid. It seeds the best
// result from the query's own cell, then scans only the candidate rectangle of
// cells that could still contain a closer node (derived conservatively from
// the seed distance). The result is never worse than the linear scan's.
func (g *Graph) gridNearest(lat, lng float64) (Node, bool) {
	if len(g.list) == 0 {
		return Node{}, false
	}
	row := g.rowFor(lat)
	col := g.colFor(lng)

	best := Node{}
	bestD := math.MaxFloat64
	found := false

	pick := func(id int64) {
		n := g.nodes[id]
		if d := haversineM(n.Lat, n.Lng, lat, lng); d < bestD {
			bestD = d
			best = n
			found = true
		}
	}
	for _, id := range g.cells[row*g.gridCols+col] {
		pick(id)
	}

	dLat, dLng := candidateBounds(lat, bestD)
	rLo := g.rowFor(lat - dLat)
	rHi := g.rowFor(lat + dLat)
	cLo := g.colFor(lng - dLng)
	cHi := g.colFor(lng + dLng)
	for r := rLo; r <= rHi; r++ {
		for c := cLo; c <= cHi; c++ {
			for _, id := range g.cells[r*g.gridCols+c] {
				pick(id)
			}
		}
	}
	return best, found
}

// candidateBounds converts a best distance in meters into a lat/lng rectangle
// (in degrees) guaranteed to contain every point closer than bestD to the
// query. The longitude bound uses the minimum expected cos(lat) inside the
// rectangle so the rectangle is never drawn too tight to prune a candidate.
func candidateBounds(lat, bestD float64) (dLat, dLng float64) {
	const r = 6371000.0
	const degRad = math.Pi / 180
	dLat = bestD / (r * degRad)
	worst := math.Abs(lat) + dLat
	if worst > 90 {
		worst = 90
	}
	cosLat := math.Cos(worst * degRad)
	if cosLat < 0.05 {
		cosLat = 0.05
	}
	dLng = bestD / (r * degRad * cosLat)
	return dLat, dLng
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
