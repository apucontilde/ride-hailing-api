package repository

import (
	"log"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/routing"
)

// edgesSQL is the edges_sql handed to pgr_dijkstra. It is a static, constant
// string — never interpolate any input into it. Binding it as a text parameter
// ($1) keeps it safe: pgRouting re-executes the constant text.
const edgesSQL = "SELECT id, source, target, cost FROM road_network_edges_pgr"

// snapSQL finds the road vertex nearest a pin. The ORDER BY <-> term is
// index-assisted ordering ONLY — on a 4326 geometry column <-> returns
// Cartesian degrees, not meters — so the true distance is computed geodesically
// with ST_Distance on ::geography for the single returned row. Param order is
// lng FIRST in ST_MakePoint(lng, lat), matching the column's lon/lat layout.
const snapSQL = `
SELECT id,
       lat AS lat,
       lng AS lng,
       ST_Distance(
         the_geom::geography,
         ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography
       ) AS distance_m
FROM road_network_vertices_pgr
ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint($2, $1), 4326)
LIMIT 1`

// routeSQL runs the real pgRouting dijkstra and joins every path node back to
// its stored coordinates. The final row's agg_cost is the route total;
// endpoints are the pinned snap coords, matching the native engine's contract.
const routeSQL = `
SELECT p.node AS node_id, p.cost AS cost, p.agg_cost AS agg_cost,
       v.lat AS lat, v.lng AS lng
FROM pgr_dijkstra($1, $2::bigint, $3::bigint, false) AS p
JOIN road_network_vertices_pgr AS v ON v.id = p.node
ORDER BY p.seq`

type snapRow struct {
	ID        int64   `db:"id"`
	Lat       float64 `db:"lat"`
	Lng       float64 `db:"lng"`
	DistanceM float64 `db:"distance_m"`
}

// PGRoutingRepo implements NavigationRepository over the real pgRouting
// pgr_dijkstra function. It issues fresh queries per call — no in-process
// graph and no cache (plan 04 adds region scoping).
type PGRoutingRepo struct {
	db          *sqlx.DB
	snapRadiusM float64
}

var _ NavigationRepository = (*PGRoutingRepo)(nil)

// NewPGRoutingRepo builds the pgRouting-backed repo. snapRadiusM <= 0 disables
// the covered-pin check (always snap).
func NewPGRoutingRepo(db *sqlx.DB, snapRadiusM float64) *PGRoutingRepo {
	return &PGRoutingRepo{db: db, snapRadiusM: snapRadiusM}
}

// NewRoutingRepository is the engine factory: ROUTING_ENGINE=pgrouting returns
// the pgRouting repo when the extension is actually installed, otherwise it
// logs the degraded fallback and never crashes boot.
func NewRoutingRepository(db *sqlx.DB, cfg *config.Config) NavigationRepository {
	if cfg != nil && cfg.RoutingEngine == "pgrouting" {
		var present bool
		if err := db.Get(&present, "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pgrouting')"); err == nil && present {
			return NewPGRoutingRepo(db, cfg.RoutingSnapRadiusM)
		}
		log.Println("ROUTING_ENGINE=pgrouting but pgRouting is unavailable; falling back to native A* engine")
	}
	return NewNavigationRepo(db)
}

func (r *PGRoutingRepo) GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	start, err := r.snap(fromLat, fromLng)
	if err != nil {
		return nil, err
	}
	goal, err := r.snap(toLat, toLng)
	if err != nil {
		return nil, err
	}

	if start.ID == goal.ID {
		return []RouteResult{{
			NodeID:  int(start.ID),
			NodeSeq: 0,
			Lat:     start.Lat,
			Lng:     start.Lng,
		}}, nil
	}

	var rows []RouteResult
	if err := r.db.Select(&rows, routeSQL, edgesSQL, start.ID, goal.ID); err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, routing.ErrNoRoute
	}
	for i := range rows {
		rows[i].NodeSeq = i
	}
	return rows, nil
}

// snap returns the nearest road vertex and its geodesic distance in meters.
// A snap farther than snapRadiusM (when configured) is "not covered".
func (r *PGRoutingRepo) snap(lat, lng float64) (snapRow, error) {
	var row snapRow
	if err := r.db.Get(&row, snapSQL, lat, lng); err != nil {
		return snapRow{}, routing.ErrNoRoute
	}
	if r.snapRadiusM > 0 && row.DistanceM > r.snapRadiusM {
		return snapRow{}, routing.ErrNoRoute
	}
	return row, nil
}
