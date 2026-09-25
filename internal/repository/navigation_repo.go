package repository

import (
	"errors"
	"fmt"
	"sync"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
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

// ValidRegionID reports whether a region id is safe to interpolate into SQL:
// letters, digits, underscore and dash only. Registry ids are operator-provided
// (the importer's --region flag), never user input, but the pgRouting repo
// formats one into the edges_sql statement handed to pgr_dijkstra (the function
// takes a statement, not a bound table), so the id is validated before it can
// break out of a string literal.
func ValidRegionID(regionID string) bool {
	if regionID == "" {
		return false
	}
	for _, c := range regionID {
		inSet := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '_' || c == '-'
		if !inSet {
			return false
		}
	}
	return true
}

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

type regionRow struct {
	RegionID   string  `db:"region_id"`
	Level      string  `db:"level"`
	Parent     string  `db:"parent_region"`
	Default    bool    `db:"default_region"`
	LonMin     float64 `db:"bbox_lon_min"`
	LatMin     float64 `db:"bbox_lat_min"`
	LonMax     float64 `db:"bbox_lon_max"`
	LatMax     float64 `db:"bbox_lat_max"`
	Datasource string  `db:"datasource"`
}

// regionsSQL reads the routing-regions registry (plan 04). parent_region and
// datasource are nullable by design, so they are COALESCEd to "" — the local
// database and a root region are both "empty", never NULL.
const regionsSQL = `
SELECT region_id,
       level,
       COALESCE(parent_region, '') AS parent_region,
       default_region,
       bbox_lon_min,
       bbox_lat_min,
       bbox_lon_max,
       bbox_lat_max,
       COALESCE(datasource, '') AS datasource
FROM routing_regions
ORDER BY region_id`

// snapRegionSQL is snapSQL scoped to ONE region (api_plans/05). The region
// filter is a parameter, never interpolated. As in snapSQL the ORDER BY <-> term
// is index-assisted ordering only (degrees on a 4326 column); the real distance
// is the geodesic ::geography one. Param order is lng first inside
// ST_MakePoint(lng, lat), matching the column's lon/lat layout.
const snapRegionSQL = `
SELECT id,
       lat,
       lng,
       ST_Distance(
         the_geom::geography,
         ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography
       ) AS distance_m
FROM road_network_vertices_pgr
WHERE region_id = $3
ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint($2, $1), 4326)
LIMIT 1`

// loadRegisteredRegions is the shared registry reader for every repo.
func loadRegisteredRegions(db *sqlx.DB) ([]model.RegionRef, error) {
	var rows []regionRow
	if err := db.Select(&rows, regionsSQL); err != nil {
		return nil, fmt.Errorf("failed to load routing regions: %w", err)
	}
	regions := make([]model.RegionRef, 0, len(rows))
	for _, row := range rows {
		regions = append(regions, model.RegionRef{
			RegionID:   row.RegionID,
			Level:      row.Level,
			Parent:     row.Parent,
			Default:    row.Default,
			BBox:       [4]float64{row.LonMin, row.LatMin, row.LonMax, row.LatMax},
			Datasource: row.Datasource,
		})
	}
	return regions, nil
}

// snapInRegion is the shared region-scoped snap. ok=false means "not covered":
// no vertex in that region, or the nearest one is beyond radiusM (radiusM <= 0
// disables the check, matching the config semantics). The datasource is the
// LOCAL pool on this plan; plan 06 adds the per-datasource pool map and this
// argument selects it.
func snapInRegion(db *sqlx.DB, lat, lng float64, datasource, regionID string, radiusM float64) (model.SnapResult, bool) {
	if datasource != "" {
		// A region living in another datasource has no rows in the local pool,
		// so it cannot cover a pin here. Returned as "not covered" rather than
		// an error: the resolver then tries the next candidate.
		return model.SnapResult{}, false
	}
	var row snapRow
	if err := db.Get(&row, snapRegionSQL, lat, lng, regionID); err != nil {
		return model.SnapResult{}, false
	}
	if radiusM > 0 && row.DistanceM > radiusM {
		return model.SnapResult{}, false
	}
	return model.SnapResult{
		VertexID:  row.ID,
		DistanceM: row.DistanceM,
		Lat:       row.Lat,
		Lng:       row.Lng,
	}, true
}

// NativeNavigationRepo routes through the in-process A* graph
// (internal/routing), the pre-pgRouting engine. It stays first-class: the
// default engine and the fallback when ROUTING_ENGINE=pgrouting is requested
// on a DB without the extension (api_plans/03).
type NativeNavigationRepo struct {
	db *sqlx.DB

	// snapRadiusM is ROUTING_SNAP_RADIUS_M for the region-scoped snap
	// (api_plans/05). 0 means always snap, the same semantics the pgRouting
	// repo has always used.
	snapRadiusM float64

	mu     sync.Mutex
	graph  *routing.Graph
	graphs map[string]*routing.Graph
	// The unscoped legacy graph and its "already tried" flag stay separate:
	// GetShortestPath is the frozen pre-region contract.
	graphAttempted bool
}

// NewNavigationRepo builds the native repo. snapRadiusM is optional (a variadic
// so pre-region call sites keep compiling); omitted means "always snap".
func NewNavigationRepo(db *sqlx.DB, snapRadiusM ...float64) *NativeNavigationRepo {
	r := &NativeNavigationRepo{db: db, graphs: make(map[string]*routing.Graph)}
	if len(snapRadiusM) > 0 {
		r.snapRadiusM = snapRadiusM[0]
	}
	return r
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

// regionGraph is roadGraph for ONE region: the region-scoped subgraph is
// loaded once and cached, so a second city on the same stack neither sees the
// first city's vertices nor re-pays the load. Per-region memory accounting and
// eviction (ROUTING_MAX_REGIONS_IN_MEMORY) are plan 06's job; this plan only
// needs the cache to be per-region rather than global. Like the unscoped load,
// an empty region is retried on every call so an import takes effect without a
// restart.
func (r *NativeNavigationRepo) regionGraph(regionID string) (*routing.Graph, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if g, ok := r.graphs[regionID]; ok {
		return g, nil
	}

	nodes, err := r.loadNodesInRegion(regionID)
	if err != nil {
		return nil, err
	}
	if len(nodes) == 0 {
		return nil, fmt.Errorf("road network not imported for region %q: run scripts/import-road-network.sh --region %s", regionID, regionID)
	}
	edges, err := r.loadEdgesInRegion(regionID)
	if err != nil {
		return nil, err
	}

	g := routing.NewGraph(nodes, edges)
	r.graphs[regionID] = g
	return g, nil
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

func (r *NativeNavigationRepo) loadNodesInRegion(regionID string) ([]routing.Node, error) {
	query := `
		SELECT
			id,
			ST_Y(the_geom) AS lat,
			ST_X(the_geom) AS lng
		FROM road_network_vertices_pgr
		WHERE region_id = $1
	`
	var rows []roadNode
	if err := r.db.Select(&rows, query, regionID); err != nil {
		return nil, fmt.Errorf("failed to load road network vertices for region %q: %w", regionID, err)
	}
	nodes := make([]routing.Node, 0, len(rows))
	for _, row := range rows {
		nodes = append(nodes, routing.Node{ID: row.ID, Lat: row.Lat, Lng: row.Lng})
	}
	return nodes, nil
}

func (r *NativeNavigationRepo) loadEdgesInRegion(regionID string) ([]routing.Edge, error) {
	query := `
		SELECT source, target, cost
		FROM road_network_edges_pgr
		WHERE region_id = $1
	`
	var rows []roadEdge
	if err := r.db.Select(&rows, query, regionID); err != nil {
		return nil, fmt.Errorf("failed to load road network edges for region %q: %w", regionID, err)
	}
	edges := make([]routing.Edge, 0, len(rows))
	for _, row := range rows {
		edges = append(edges, routing.Edge{Source: row.Source, Target: row.Target, Cost: row.Cost})
	}
	return edges, nil
}

// RegisteredRegions satisfies the service's RegionSource capability
// (structurally — repository never imports service).
func (r *NativeNavigationRepo) RegisteredRegions() ([]model.RegionRef, error) {
	return loadRegisteredRegions(r.db)
}

// Snap finds the nearest road vertex to a pin inside one region.
func (r *NativeNavigationRepo) Snap(lat, lng float64, datasource, regionID string) (model.SnapResult, bool) {
	return snapInRegion(r.db, lat, lng, datasource, regionID, r.snapRadiusM)
}

// GetShortestPath is the frozen pre-region contract: it routes against the
// WHOLE network, unscoped, exactly as it did before api_plans/05.
func (r *NativeNavigationRepo) GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	g, err := r.roadGraph()
	if err != nil {
		return nil, err
	}
	return routeResults(g, fromLat, fromLng, toLat, toLng)
}

// RouteInRegion routes against one region's subgraph only.
func (r *NativeNavigationRepo) RouteInRegion(regionID string, fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	g, err := r.regionGraph(regionID)
	if err != nil {
		return nil, err
	}
	return routeResults(g, fromLat, fromLng, toLat, toLng)
}

// routeResults runs A* on a graph and shapes the node list the service
// consumes: NodeSeq is the path order and the LAST node carries the total
// accumulated cost (the route distance in meters).
func routeResults(g *routing.Graph, fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
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
