package repository

import (
	"errors"
	"fmt"
	"sync"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/routing"
)

type RouteResult struct {
	NodeID  int     `db:"node_id"`
	NodeSeq int     `db:"node_seq"`
	Cost    float64 `db:"cost"`
	AggCost float64 `db:"agg_cost"`
	Lat     float64 `db:"lat"`
	Lng     float64 `db:"lng"`
}

type NavigationRepository interface {
	GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error)
}

var _ NavigationRepository = (*NativeNavigationRepo)(nil)

type roadNode struct {
	ID  int64   `db:"id"`
	Lat float64 `db:"lat"`
	Lng float64 `db:"lng"`
}

type roadEdge struct {
	Source int64   `db:"source"`
	Target int64   `db:"target"`
	Cost   float64 `db:"cost"`
}

// NativeNavigationRepo routes through the in-process A* graph
// (internal/routing), the pre-pgRouting engine. It stays first-class: the
// default engine and the fallback when ROUTING_ENGINE=pgrouting is requested
// on a DB without the extension (api_plans/03).
type NativeNavigationRepo struct {
	db *sqlx.DB

	mu             sync.Mutex
	graph          *routing.Graph
	graphAttempted bool
}

func NewNavigationRepo(db *sqlx.DB) *NativeNavigationRepo {
	return &NativeNavigationRepo{db: db}
}

// roadGraph loads the PostGIS road network once and caches it as an
// immutable routing graph. A successful load is remembered; an empty
// network (dev DB before scripts/import-road-network.sh) is retried on
// every call so a later import takes effect without a restart.
func (r *NativeNavigationRepo) roadGraph() (*routing.Graph, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.graphAttempted {
		return r.graph, nil
	}

	nodes, err := r.loadNodes()
	if err != nil {
		return nil, err
	}
	if len(nodes) == 0 {
		return nil, errors.New("road network not imported: run scripts/import-road-network.sh")
	}
	edges, err := r.loadEdges()
	if err != nil {
		return nil, err
	}

	r.graph = routing.NewGraph(nodes, edges)
	r.graphAttempted = true
	return r.graph, nil
}

func (r *NativeNavigationRepo) loadNodes() ([]routing.Node, error) {
	query := `
		SELECT
			id,
			ST_Y(the_geom) AS lat,
			ST_X(the_geom) AS lng
		FROM road_network_vertices_pgr
	`
	var rows []roadNode
	if err := r.db.Select(&rows, query); err != nil {
		return nil, fmt.Errorf("failed to load road network vertices: %w", err)
	}
	nodes := make([]routing.Node, 0, len(rows))
	for _, row := range rows {
		nodes = append(nodes, routing.Node{ID: row.ID, Lat: row.Lat, Lng: row.Lng})
	}
	return nodes, nil
}

func (r *NativeNavigationRepo) loadEdges() ([]routing.Edge, error) {
	query := `
		SELECT source, target, cost
		FROM road_network_edges_pgr
	`
	var rows []roadEdge
	if err := r.db.Select(&rows, query); err != nil {
		return nil, fmt.Errorf("failed to load road network edges: %w", err)
	}
	edges := make([]routing.Edge, 0, len(rows))
	for _, row := range rows {
		edges = append(edges, routing.Edge{Source: row.Source, Target: row.Target, Cost: row.Cost})
	}
	return edges, nil
}

func (r *NativeNavigationRepo) GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	g, err := r.roadGraph()
	if err != nil {
		return nil, err
	}

	path, totalCost, err := g.Route(fromLat, fromLng, toLat, toLng)
	if err != nil {
		return nil, err
	}

	results := make([]RouteResult, 0, len(path))
	for i, id := range path {
		n, ok := g.NodeByID(id)
		if !ok {
			return nil, fmt.Errorf("route references unknown node %d", id)
		}
		results = append(results, RouteResult{
			NodeID:  int(n.ID),
			NodeSeq: i,
			Lat:     n.Lat,
			Lng:     n.Lng,
		})
	}
	if len(results) > 0 {
		results[len(results)-1].AggCost = totalCost
	}
	return results, nil
}
