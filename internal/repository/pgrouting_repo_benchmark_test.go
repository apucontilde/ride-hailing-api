//go:build integration

package repository

import (
	"fmt"
	"math"
	"testing"

	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"

	"ride-hailing-api/internal/config"
)

// BenchmarkRoutePGRouting is the pgRouting side of the plan-03 decision gate.
// It loads the SAME synthetic grid workset as native BenchmarkRoute in
// internal/routing/benchmark_test.go (benchGridN=400 @ 0.0005 deg, anchored
// near San José) into TEMP road_network_* tables on a single connection, so a
// real import is never touched and the topology matches the native baseline —
// unlike the SJ import, whose different topology would make the comparison
// meaningless (api_plans/03 §Decision gate).
const (
	benchGridN     = 400
	benchOriginLat = 9.9
	benchOriginLng = -84.2
	benchStep      = 0.0005
)

func benchGridID(i, j int) int64 { return int64(i*benchGridN + j) }

func newBenchPGRDB(b *testing.B) *sqlx.DB {
	b.Helper()
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		b.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	db.SetMaxOpenConns(1) // keep the temp tables on the same connection
	b.Cleanup(func() {
		_, _ = db.Exec("DROP TABLE IF EXISTS road_network_vertices_pgr")
		_, _ = db.Exec("DROP TABLE IF EXISTS road_network_edges_pgr")
		_ = db.Close()
	})

	for _, stmt := range []string{
		"CREATE TEMP TABLE road_network_vertices_pgr (" +
			"id BIGINT PRIMARY KEY, the_geom GEOMETRY(Point,4326), " +
			"lat DOUBLE PRECISION NOT NULL, lng DOUBLE PRECISION NOT NULL)",
		"CREATE TEMP TABLE road_network_edges_pgr (" +
			"id BIGINT PRIMARY KEY, source BIGINT, target BIGINT, cost DOUBLE PRECISION)",
		"CREATE INDEX ON road_network_vertices_pgr USING GIST (the_geom)",
	} {
		if _, err := db.Exec(stmt); err != nil {
			b.Fatal(err)
		}
	}

	vtx, err := db.Beginx()
	if err != nil {
		b.Fatal(err)
	}
	vstmt, err := vtx.Prepare(pq.CopyIn("road_network_vertices_pgr", "id", "the_geom", "lat", "lng"))
	if err != nil {
		b.Fatal(err)
	}
	for i := 0; i < benchGridN; i++ {
		for j := 0; j < benchGridN; j++ {
			lat := benchOriginLat + float64(i)*benchStep
			lng := benchOriginLng + float64(j)*benchStep
			if _, err := vstmt.Exec(benchGridID(i, j), fmt.Sprintf("SRID=4326;POINT(%f %f)", lng, lat), lat, lng); err != nil {
				b.Fatal(err)
			}
		}
	}
	if err := vstmt.Close(); err != nil {
		b.Fatal(err)
	}
	if err := vtx.Commit(); err != nil {
		b.Fatal(err)
	}

	etx, err := db.Beginx()
	if err != nil {
		b.Fatal(err)
	}
	estmt, err := etx.Prepare(pq.CopyIn("road_network_edges_pgr", "id", "source", "target", "cost"))
	if err != nil {
		b.Fatal(err)
	}
	eid := int64(1)
	for i := 0; i < benchGridN; i++ {
		for j := 0; j < benchGridN; j++ {
			lat := benchOriginLat + float64(i)*benchStep
			lng := benchOriginLng + float64(j)*benchStep
			if j+1 < benchGridN {
				if _, err := estmt.Exec(eid, benchGridID(i, j), benchGridID(i, j+1),
					gridEdgeCost(lat, lng, lat, lng+benchStep)); err != nil {
					b.Fatal(err)
				}
				eid++
			}
			if i+1 < benchGridN {
				if _, err := estmt.Exec(eid, benchGridID(i, j), benchGridID(i+1, j),
					gridEdgeCost(lat, lng, lat+benchStep, lng)); err != nil {
					b.Fatal(err)
				}
				eid++
			}
		}
	}
	if err := estmt.Close(); err != nil {
		b.Fatal(err)
	}
	if err := etx.Commit(); err != nil {
		b.Fatal(err)
	}
	return db
}

// gridEdgeCost mirrors internal/routing.haversineM so the stored edge costs
// (and route lengths) match the native benchmark's workset exactly. R = 6371000.
func gridEdgeCost(lat1, lng1, lat2, lng2 float64) float64 {
	const r = 6371000.0
	const degRad = math.Pi / 180
	phi1 := lat1 * degRad
	phi2 := lat2 * degRad
	dPhi := (lat2 - lat1) * degRad
	dLambda := (lng2 - lng1) * degRad
	a := math.Sin(dPhi/2)*math.Sin(dPhi/2) +
		math.Cos(phi1)*math.Cos(phi2)*math.Sin(dLambda/2)*math.Sin(dLambda/2)
	return 2 * r * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

func BenchmarkRoutePGRouting(b *testing.B) {
	db := newBenchPGRDB(b)
	repo := NewPGRoutingRepo(db, 0)

	fromLat, fromLng := benchOriginLat, benchOriginLng
	toLat := benchOriginLat + float64(benchGridN-1)*benchStep
	toLng := benchOriginLng + float64(benchGridN-1)*benchStep

	b.ReportAllocs()
	b.SetBytes(2)

	b.Run("corner", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := repo.GetShortestPath(fromLat, fromLng, toLat, toLng); err != nil {
				b.Fatal(err)
			}
		}
	})

	b.Run("hop", func(b *testing.B) {
		hlat := benchOriginLat + float64(benchGridN/2)*benchStep
		hlng := benchOriginLng + float64(benchGridN/2)*benchStep
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := repo.GetShortestPath(hlat, hlng, hlat+benchStep, hlng); err != nil {
				b.Fatal(err)
			}
		}
	})
}
