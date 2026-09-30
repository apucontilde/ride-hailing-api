package repository

import (
	"errors"
	"fmt"
	"log"
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
	// AscentM/DescentM/ElevationAware are additive route totals (api_plans
	// [elevation] stage 01). Like AggCost they are only meaningful on the LAST
	// row: the native engine sets them from routing.Path.AscentM/DescentM and
	// from whether the graph was built elevation-aware. pgRouting leaves them
	// zero because the flag is inert there. AscentM/DescentM are RAW metres,
	// never the weighted quantity the search minimized.
	AscentM        float64
	DescentM       float64
	ElevationAware bool
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
	// EleM is a POINTER on purpose: NULL (no sample) and 0 (sea level) are
	// different facts and the coverage gate needs to tell them apart. sqlx maps
	// a SQL NULL into a nil *float64 and a real value into an allocated one.
	EleM *float64 `db:"elevation_m"`
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
		return nil, wrapDB("load routing regions", err)
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

// snapInRegion is the shared region-scoped snap, run against the pool that
// owns the region (api_plans/06 selects it from the region's datasource).
// ok=false means "not covered": no vertex in that region, the nearest one is
// beyond radiusM (radiusM <= 0 disables the check, matching the config
// semantics), or the pool itself could not answer.
func snapInRegion(db *sqlx.DB, lat, lng float64, regionID string, radiusM float64) (model.SnapResult, bool) {
	if db == nil {
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

// regionGraphEntry is one cached per-region graph plus the datasource it was
// loaded from. Keeping the datasource lets an operator re-point a region at
// another city database and have the next request rebuild instead of routing on
// the stale graph.
type regionGraphEntry struct {
	graph      *routing.Graph
	datasource string
	// weights is the elevation cost model that graph was BUILT with (the
	// coverage-gate result for that region's vertices). It is stored next to the
	// graph so a request routes with the same weights the graph's Node.EleM
	// values were prepared for.
	weights routing.CostWeights
}

// graphLoad is the in-flight marker for one region's first build. Concurrent
// requests for the SAME region share the single load (a city graph is ~150 MB
// and seconds to build); requests for OTHER regions never wait on it, which is
// the "one city never blocks another" property in-process, not just in the DB.
type graphLoad struct {
	done    chan struct{}
	graph   *routing.Graph
	weights routing.CostWeights
	err     error
}

// NativeNavigationRepo routes through the in-process A* graph
// (internal/routing), the pre-pgRouting engine. It stays first-class: the
// default engine and the fallback when ROUTING_ENGINE=pgrouting is requested
// on a DB without the extension (api_plans/03).
//
// Per city it holds ONE lazily built, cached graph (api_plans/06), and per
// datasource its own pool (see DatasourcePools).
type NativeNavigationRepo struct {
	db *sqlx.DB

	// pools resolves a region's datasource to its pool. nil means "local only",
	// which is what a single-city deployment gets.
	pools *DatasourcePools

	// snapRadiusM is ROUTING_SNAP_RADIUS_M for the region-scoped snap
	// (api_plans/05). 0 means always snap, the same semantics the pgRouting
	// repo has always used.
	snapRadiusM float64

	// maxRegions is ROUTING_MAX_REGIONS_IN_MEMORY: how many per-region graphs to
	// keep. 0 = keep them all (~150-200 MB per city, the default for a handful
	// of cities); a positive N evicts the least-recently-used region beyond N so
	// a pod can hold a deliberate subset.
	maxRegions int

	mu     sync.Mutex
	graph  *routing.Graph
	graphs map[string]*regionGraphEntry
	// graphOrder is the LRU order of graphs: least recently used first. It
	// always mirrors the keys of graphs.
	graphOrder []string
	// loading holds the per-region build in flight (see graphLoad).
	loading map[string]*graphLoad
	// The unscoped legacy graph and its "already tried" flag stay separate:
	// GetShortestPath is the frozen pre-region contract, and it is never evicted.
	graphAttempted bool

	// legacyWeights is the elevation cost model the unscoped graph was built
	// with (the coverage-gate result for the whole, un-scoped network).
	legacyWeights routing.CostWeights

	// elev is the elevation cost model requested via config (zero value = flat).
	// elevOn is ROUTING_ELEVATION=on. minCover is the coverage fraction required
	// before the weights are honoured; below it (or with no samples) routing
	// degrades to flat, never garbage (STATUS.md invariant). The *resolved*
	// weights (post-coverage-gate) are stored per graph, next to the cache
	// entry, because coverage is a per-region fact discovered at build time.
	elev     routing.CostWeights
	elevOn   bool
	minCover float64
}

// NewNavigationRepo builds the native repo against the LOCAL pool only.
// snapRadiusM is optional (a variadic so pre-region call sites keep compiling);
// omitted means "always snap".
func NewNavigationRepo(db *sqlx.DB, snapRadiusM ...float64) *NativeNavigationRepo {
	r := newNativeRepo(db, nil, 0)
	if len(snapRadiusM) > 0 {
		r.snapRadiusM = snapRadiusM[0]
	}
	return r
}

// NewNavigationRepoWithDatasources builds the native repo for the multi-city
// shape: pools resolves every region's datasource, maxRegions caps the cached
// per-region graphs (0 = unlimited). maxRegions <= 0 is treated as unlimited.
func NewNavigationRepoWithDatasources(db *sqlx.DB, pools *DatasourcePools, snapRadiusM float64, maxRegions int) *NativeNavigationRepo {
	return newNativeRepo(db, pools, maxRegions)
}

func newNativeRepo(db *sqlx.DB, pools *DatasourcePools, maxRegions int) *NativeNavigationRepo {
	if maxRegions < 0 {
		maxRegions = 0
	}
	return &NativeNavigationRepo{
		db:         db,
		pools:      pools,
		maxRegions: maxRegions,
		graphs:     make(map[string]*regionGraphEntry),
		loading:    make(map[string]*graphLoad),
	}
}

// configureElevation sets the elevation cost model for the native engine. It is
// called by the engine factory (pgrouting_repo.go), which already holds
// *config.Config; the repo itself stays config-free. A zero elev / enabled=false
// reproduces the pre-elevation engine exactly (default off). An invalid weight
// set is rejected at this boundary so a misconfigured deploy gets flat routing,
// never a wrong router (mirrors RouteWithWeights' own Validate fallback).
func (r *NativeNavigationRepo) configureElevation(elev routing.CostWeights, enabled bool, minCover float64) *NativeNavigationRepo {
	r.elev = elev
	if enabled && elev.Validate() == nil {
		r.elevOn = true
	} else {
		r.elevOn = false
	}
	r.minCover = minCover
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

	nodes, known, err := r.loadNodes()
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

	r.legacyWeights = r.resolveElevation(nodes, edges, known)
	r.graph = routing.NewGraph(nodes, edges)
	r.graphAttempted = true
	return r.graph, nil
}

// resolveElevation decides the elevation cost model for a freshly loaded node
// set from its coverage, and — only when elevation is LIVE — fixes up unknown
// (NULL) vertices by propagating a known neighbour's elevation, so a NULL
// endpoint never reads as sea level beside a real altitude (which would
// fabricate a clamped cliff in the hot loop; Part 3a). It mutates nodes in
// place to carry the final EleM values and returns the weights to route with
// (the zero value = flat routing).
func (r *NativeNavigationRepo) resolveElevation(nodes []routing.Node, edges []routing.Edge, known map[int64]bool) routing.CostWeights {
	total := len(nodes)
	covered := len(known)
	frac := 0.0
	if total > 0 {
		frac = float64(covered) / float64(total)
	}

	if !r.elevOn {
		log.Printf("[elevation] disabled by config (ROUTING_ELEVATION not on); routing flat")
		return routing.CostWeights{}
	}
	if covered == 0 {
		log.Printf("[elevation] disabled: no elevation samples present; routing flat")
		return routing.CostWeights{}
	}
	if frac < r.minCover {
		log.Printf("[elevation] disabled: coverage %.4f < %.4f; routing flat", frac, r.minCover)
		return routing.CostWeights{}
	}

	fillUnknownElevation(nodes, edges, known)

	log.Printf("[elevation] elevation-aware routing on: %d/%d vertices (%.2f%%), ascent=%.2f descent=%.2f maxGrade=%.2f deadband=%.1fm",
		covered, total, 100*frac, r.elev.AscentW, r.elev.DescentW, r.elev.MaxGrade, r.elev.DeadbandM)
	return r.elev
}

// fillUnknownElevation propagates a known neighbour's elevation into every
// vertex with no sample, so an edge touching an unknown endpoint carries a
// near-zero grade instead of the (clamped) full altitude of its known endpoint.
// Vertices with no known neighbour keep EleM = 0. It is a pure, DB-free helper
// so the NULL-endpoint rule is unit-testable.
func fillUnknownElevation(nodes []routing.Node, edges []routing.Edge, known map[int64]bool) {
	ele := make(map[int64]float64, len(nodes))
	for _, n := range nodes {
		ele[n.ID] = n.EleM
	}
	adj := make(map[int64][]int64, len(edges)*2)
	for _, e := range edges {
		adj[e.Source] = append(adj[e.Source], e.Target)
		adj[e.Target] = append(adj[e.Target], e.Source)
	}
	for i := range nodes {
		if known[nodes[i].ID] {
			continue
		}
		var sum float64
		var n int
		for _, nbID := range adj[nodes[i].ID] {
			if known[nbID] {
				sum += ele[nbID]
				n++
			}
		}
		if n > 0 {
			nodes[i].EleM = sum / float64(n)
		}
	}
}

// regionGraph is roadGraph for ONE region: the region-scoped subgraph is
// loaded once from the region's OWN pool and cached, so a second city on the
// stack neither sees the first city's vertices nor re-pays the load, and an
// import into that city is picked up the next time the region is asked for (the
// cache only ever remembers SUCCESSFUL loads).
//
// Concurrency: the first request for a region builds while the mutex is free, so
// a slow city never blocks another city's routing; a second request for the SAME
// region waits for that one build instead of duplicating it.
//
// Eviction: when ROUTING_MAX_REGIONS_IN_MEMORY is exceeded the least recently
// used region's graph is dropped (0 = never evict). Evicting only a cache entry
// is always safe — in-flight requests keep the pointer they already hold.
func (r *NativeNavigationRepo) regionGraph(regionID, datasource string) (*routing.Graph, routing.CostWeights, error) {
	r.mu.Lock()
	if entry, ok := r.graphs[regionID]; ok && entry.datasource == datasource {
		r.touchRegionLocked(regionID)
		g := entry.graph
		w := entry.weights
		r.mu.Unlock()
		return g, w, nil
	}
	if load, ok := r.loading[regionID]; ok {
		// Someone else is already building this region: wait for their result.
		r.mu.Unlock()
		<-load.done
		return load.graph, load.weights, load.err
	}
	load := &graphLoad{done: make(chan struct{})}
	if r.loading == nil {
		r.loading = make(map[string]*graphLoad)
	}
	r.loading[regionID] = load
	r.mu.Unlock()

	graph, weights, err := r.loadRegionGraph(regionID, datasource)

	r.mu.Lock()
	if err == nil {
		if r.graphs == nil {
			r.graphs = make(map[string]*regionGraphEntry)
		}
		r.graphs[regionID] = &regionGraphEntry{graph: graph, datasource: datasource, weights: weights}
		r.touchRegionLocked(regionID)
		r.evictRegionsLocked()
	}
	load.graph, load.weights, load.err = graph, weights, err
	delete(r.loading, regionID)
	r.mu.Unlock()
	close(load.done) // published last: waiters see the fields written above
	return graph, weights, err
}

// loadRegionGraph builds one region's graph from its own pool. Failures are NOT
// cached, so an import (or a datasource that comes back up) takes effect on the
// next request without a restart.
func (r *NativeNavigationRepo) loadRegionGraph(regionID, datasource string) (*routing.Graph, routing.CostWeights, error) {
	db := poolFor(r.db, r.pools, datasource)
	if db == nil {
		return nil, routing.CostWeights{}, noPoolErr(datasource)
	}

	nodes, known, err := loadRegionNodes(db, regionID)
	if err != nil {
		return nil, routing.CostWeights{}, datasourceErr(datasource, err)
	}
	if len(nodes) == 0 {
		return nil, routing.CostWeights{}, fmt.Errorf("road network not imported for region %q: run scripts/import-road-network.sh --region %s", regionID, regionID)
	}
	edges, err := loadRegionEdges(db, regionID)
	if err != nil {
		return nil, routing.CostWeights{}, datasourceErr(datasource, err)
	}

	weights := r.resolveElevation(nodes, edges, known)

	return routing.NewGraph(nodes, edges), weights, nil
}

// touchRegionLocked marks regionID as most recently used. Caller holds r.mu.
func (r *NativeNavigationRepo) touchRegionLocked(regionID string) {
	for i, id := range r.graphOrder {
		if id == regionID {
			r.graphOrder = append(r.graphOrder[:i], r.graphOrder[i+1:]...)
			break
		}
	}
	r.graphOrder = append(r.graphOrder, regionID)
}

// evictRegionsLocked drops least-recently-used graphs until the cache fits the
// ROUTING_MAX_REGIONS_IN_MEMORY budget. Caller holds r.mu.
func (r *NativeNavigationRepo) evictRegionsLocked() {
	if r.maxRegions <= 0 {
		return
	}
	for len(r.graphOrder) > r.maxRegions {
		victim := r.graphOrder[0]
		r.graphOrder = r.graphOrder[1:]
		delete(r.graphs, victim)
		log.Printf("[routing] region graph %q evicted (ROUTING_MAX_REGIONS_IN_MEMORY=%d)", victim, r.maxRegions)
	}
}

// CachedRegionIDs returns the region ids whose graph is currently in memory,
// least recently used first. It is introspection: eviction tests and operational
// debugging ("which cities does this pod hold?") read it, the request path does
// not.
func (r *NativeNavigationRepo) CachedRegionIDs() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.graphOrder...)
}

func (r *NativeNavigationRepo) loadNodes() ([]routing.Node, map[int64]bool, error) {
	query := `
		SELECT
			id,
			ST_Y(the_geom) AS lat,
			ST_X(the_geom) AS lng,
			elevation_m
		FROM road_network_vertices_pgr
	`
	var rows []roadNode
	if err := r.db.Select(&rows, query); err != nil {
		return nil, nil, wrapDB("load road network vertices", err)
	}
	nodes, known := toRoutingNodes(rows)
	return nodes, known, nil
}

func (r *NativeNavigationRepo) loadEdges() ([]routing.Edge, error) {
	query := `
		SELECT source, target, cost
		FROM road_network_edges_pgr
	`
	var rows []roadEdge
	if err := r.db.Select(&rows, query); err != nil {
		return nil, wrapDB("load road network edges", err)
	}
	edges := make([]routing.Edge, 0, len(rows))
	for _, row := range rows {
		edges = append(edges, routing.Edge{Source: row.Source, Target: row.Target, Cost: row.Cost})
	}
	return edges, nil
}

// loadRegionNodes/loadRegionEdges read one region's subgraph from the pool that
// owns it. region_id is a bound parameter, never interpolated.
func loadRegionNodes(db *sqlx.DB, regionID string) ([]routing.Node, map[int64]bool, error) {
	query := `
		SELECT
			id,
			ST_Y(the_geom) AS lat,
			ST_X(the_geom) AS lng,
			elevation_m
		FROM road_network_vertices_pgr
		WHERE region_id = $1
	`
	var rows []roadNode
	if err := db.Select(&rows, query, regionID); err != nil {
		return nil, nil, wrapDB("load road network vertices for region: "+regionID, err)
	}
	nodes, known := toRoutingNodes(rows)
	return nodes, known, nil
}

// toRoutingNodes converts scanned roadNode rows into routing.Node values and
// returns the set of vertex ids whose elevation_m was a real sample (non-NULL).
// A NULL sample maps to EleM 0 — routing.Node.EleM's "unknown" value — while the
// coverage gate uses `known` to tell "no sample" apart from "sea level".
func toRoutingNodes(rows []roadNode) ([]routing.Node, map[int64]bool) {
	nodes := make([]routing.Node, 0, len(rows))
	known := make(map[int64]bool, len(rows))
	for _, row := range rows {
		var ele float64
		if row.EleM != nil {
			ele = *row.EleM
			known[row.ID] = true
		}
		nodes = append(nodes, routing.Node{ID: row.ID, Lat: row.Lat, Lng: row.Lng, EleM: ele})
	}
	return nodes, known
}

func loadRegionEdges(db *sqlx.DB, regionID string) ([]routing.Edge, error) {
	query := `
		SELECT source, target, cost
		FROM road_network_edges_pgr
		WHERE region_id = $1
	`
	var rows []roadEdge
	if err := db.Select(&rows, query, regionID); err != nil {
		return nil, wrapDB("load road network edges for region: "+regionID, err)
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

// Snap finds the nearest road vertex to a pin inside one region, in the pool
// that region's datasource names. An unresolvable datasource is "not covered"
// rather than an error: the resolver then tries the next candidate, and if none
// covers the pin the request degrades to a straight-line estimate.
func (r *NativeNavigationRepo) Snap(lat, lng float64, datasource, regionID string) (model.SnapResult, bool) {
	return snapInRegion(poolFor(r.db, r.pools, datasource), lat, lng, regionID, r.snapRadiusM)
}

// GetShortestPath is the frozen pre-region contract: it routes against the
// WHOLE network, unscoped, exactly as it did before api_plans/05.
func (r *NativeNavigationRepo) GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	g, err := r.roadGraph()
	if err != nil {
		return nil, err
	}
	return routeResults(g, r.legacyWeights, fromLat, fromLng, toLat, toLng)
}

// RouteInRegion routes against one region's subgraph only, loaded from that
// region's own datasource pool. A datasource that cannot be reached returns an
// ErrDatasourceUnavailable-wrapped error, which the service degrades to an
// estimate rather than a 500.
func (r *NativeNavigationRepo) RouteInRegion(regionID, datasource string, fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	g, weights, err := r.regionGraph(regionID, datasource)
	if err != nil {
		return nil, err
	}
	return routeResults(g, weights, fromLat, fromLng, toLat, toLng)
}

// routeResults runs A* on a graph and shapes the node list the service
// consumes: NodeSeq is the path order and the LAST node carries the total
// accumulated cost — the route distance in METERS, never the weighted search
// cost (STATUS.md invariant: fare, duration and total_distance_m all derive
// from Meters). weights is the elevation model the graph was built with (zero =
// flat).
func routeResults(g *routing.Graph, weights routing.CostWeights, fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	p, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, weights)
	if err != nil {
		return nil, err
	}

	results := make([]RouteResult, 0, len(p.Nodes))
	for i, id := range p.Nodes {
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
		last := &results[len(results)-1]
		last.AggCost = p.Meters
		// Elevation totals are additive, last-row fields (like AggCost). They
		// are the RAW ascent/descent the path actually climbed, not the
		// weighted cost, so a client can show a "flat route" badge; the
		// per-response flag says whether elevation was live for THIS graph
		// (coverage is per-region, so it is not a server-wide setting). When
		// elevation is off the graph still carries Node.EleM, so Path would
		// report raw deltas — report 0 instead, because the contract is
		// "false/0 when elevation routing is off".
		last.ElevationAware = weights != (routing.CostWeights{})
		if last.ElevationAware {
			last.AscentM = p.AscentM
			last.DescentM = p.DescentM
		}
	}
	return results, nil
}
