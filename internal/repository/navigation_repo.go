package repository

import (
	"fmt"

	"github.com/jmoiron/sqlx"
)

type RouteResult struct {
	NodeID   int     `db:"node_id"`
	NodeSeq  int     `db:"node_seq"`
	Cost     float64 `db:"cost"`
	AggCost  float64 `db:"agg_cost"`
	Lat      float64 `db:"lat"`
	Lng      float64 `db:"lng"`
}

type NavigationRepository interface {
	GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error)
}

var _ NavigationRepository = (*NavigationRepo)(nil)

type NavigationRepo struct {
	db *sqlx.DB
}

func NewNavigationRepo(db *sqlx.DB) *NavigationRepo {
	return &NavigationRepo{db: db}
}

func (r *NavigationRepo) GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]RouteResult, error) {
	query := `
		WITH start_node AS (
			SELECT id FROM road_network_vertices_pgr 
			ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint($1, $2), 4326) LIMIT 1
		),
		end_node AS (
			SELECT id FROM road_network_vertices_pgr 
			ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint($3, $4), 4326) LIMIT 1
		)
		SELECT 
			n.id AS node_id, 
			p.seq AS node_seq, 
			p.cost, 
			p.agg_cost, 
			n.lat, 
			n.lng
		FROM pgr_dijkstra(
			'SELECT id, source, target, cost FROM road_network_edges_pgr',
			(SELECT id FROM start_node),
			(SELECT id FROM end_node),
			false
		) AS p
		JOIN road_network_vertices_pgr n ON p.node = n.id
		ORDER BY p.seq;
	`
	var results []RouteResult
	err := r.db.Select(&results, query, fromLng, fromLat, toLng, toLat)
	if err != nil {
		return nil, fmt.Errorf("failed to get shortest path: %w", err)
	}
	return results, nil
}
