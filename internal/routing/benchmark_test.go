package routing

import (
	"math"
	"testing"
)

// benchGridN is the grid dimension for the synthetic benchmark network:
// benchGridN^2 = 160k nodes at ~0.0005 degree spacing, mimicking the density
// of a mid-size city. NOTE: interior grid nodes have degree 4, not the ~2.4
// average of the San José OSM import — this is a stable synthetic baseline,
// not a faithful topology.
const benchGridN = 400

// benchOrigin anchors the grid around San José. Lat increases south-to-north
// on the y axis, lng east on the x axis.
const (
	benchOriginLat = 9.9
	benchOriginLng = -84.2
	benchStep      = 0.0005
)

func benchmarkGrid(n int) ([]Node, []Edge) {
	nodes := make([]Node, 0, n*n)
	edges := make([]Edge, 0, 2*(n*(n-1))*2)
	id := func(i, j int) int64 { return int64(i*n + j) }
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			nodes = append(nodes, Node{
				ID:  id(i, j),
				Lat: benchOriginLat + float64(i)*benchStep,
				Lng: benchOriginLng + float64(j)*benchStep,
			})
		}
	}
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			if j+1 < n {
				u, v := id(i, j), id(i, j+1)
				edges = append(edges, Edge{
					Source: u,
					Target: v,
					Cost:   HaversineMeters(nodes[v].Lat, nodes[v].Lng, nodes[u].Lat, nodes[u].Lng),
				})
			}
			if i+1 < n {
				u, v := id(i, j), id(i+1, j)
				edges = append(edges, Edge{
					Source: u,
					Target: v,
					Cost:   HaversineMeters(nodes[v].Lat, nodes[v].Lng, nodes[u].Lat, nodes[u].Lng),
				})
			}
		}
	}
	return nodes, edges
}

func benchmarkGridGraph(n int) *Graph {
	nodes, edges := benchmarkGrid(n)
	return NewGraph(nodes, edges)
}

// benchQuery is a lattice interior point near the grid center, so every
// NearestNode variant has equally dense surroundings.
func benchQuery() (lat, lng float64) {
	return benchOriginLat + float64(benchGridN/2)*benchStep,
		benchOriginLng + float64(benchGridN/2)*benchStep
}

func BenchmarkNearestNodeLinear(b *testing.B) {
	g := benchmarkGridGraph(benchGridN)
	lat, lng := benchQuery()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, ok := g.scanNearest(lat, lng); !ok {
			b.Fatal("no nearest node")
		}
	}
}

func BenchmarkNearestNodeGrid(b *testing.B) {
	g := benchmarkGridGraph(benchGridN)
	lat, lng := benchQuery()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, ok := g.gridNearest(lat, lng); !ok {
			b.Fatal("no nearest node")
		}
	}
}

func BenchmarkRoute(b *testing.B) {
	g := benchmarkGridGraph(benchGridN)
	b.ReportAllocs()
	b.SetBytes(2)

	b.Run("corner", func(b *testing.B) {
		// Corner to corner is the long-path A* case.
		fromLat, fromLng := benchOriginLat, benchOriginLng
		toLat := benchOriginLat + float64(benchGridN-1)*benchStep
		toLng := benchOriginLng + float64(benchGridN-1)*benchStep
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, _, err := g.Route(fromLat, fromLng, toLat, toLng); err != nil {
				b.Fatal(err)
			}
		}
	})

	b.Run("hop", func(b *testing.B) {
		// One lattice step apart exercises the snap + trivial A* path.
		fromLat, fromLng := benchQuery()
		toLat, toLng := fromLat+benchStep, fromLng
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, _, err := g.Route(fromLat, fromLng, toLat, toLng); err != nil {
				b.Fatal(err)
			}
		}
	})
}

func BenchmarkNewGraph(b *testing.B) {
	nodes, edges := benchmarkGrid(benchGridN)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = NewGraph(nodes, edges)
	}
}

// benchmarkGridElevated is the same lattice as benchmarkGrid but with a
// deterministic synthetic elevation field, so every edge carries a non-zero,
// non-degenerate climb/descent: EleM = 120·sin(i·step) + 60·cos(j·step).
func benchmarkGridElevated(n int) ([]Node, []Edge) {
	nodes := make([]Node, 0, n*n)
	edges := make([]Edge, 0, 2*(n*(n-1))*2)
	id := func(i, j int) int64 { return int64(i*n + j) }
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			nodes = append(nodes, Node{
				ID:   id(i, j),
				Lat:  benchOriginLat + float64(i)*benchStep,
				Lng:  benchOriginLng + float64(j)*benchStep,
				EleM: 120*math.Sin(float64(i)*benchStep) + 60*math.Cos(float64(j)*benchStep),
			})
		}
	}
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			if j+1 < n {
				u, v := id(i, j), id(i, j+1)
				edges = append(edges, Edge{
					Source: u,
					Target: v,
					Cost:   HaversineMeters(nodes[v].Lat, nodes[v].Lng, nodes[u].Lat, nodes[u].Lng),
				})
			}
			if i+1 < n {
				u, v := id(i, j), id(i+1, j)
				edges = append(edges, Edge{
					Source: u,
					Target: v,
					Cost:   HaversineMeters(nodes[v].Lat, nodes[v].Lng, nodes[u].Lat, nodes[u].Lng),
				})
			}
		}
	}
	return nodes, edges
}

// benchmarkElevatedWeights is the documented non-zero weight set used by
// BenchmarkRouteElevated (AscentW 1.5, DescentW 0.3, MaxGrade 0.15, DeadbandM 3).
var benchmarkElevatedWeights = CostWeights{AscentW: 1.5, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3}

func BenchmarkRouteElevated(b *testing.B) {
	nodes, edges := benchmarkGridElevated(benchGridN)
	g := NewGraph(nodes, edges)
	b.ReportAllocs()
	b.SetBytes(2)

	b.Run("corner", func(b *testing.B) {
		fromLat, fromLng := benchOriginLat, benchOriginLng
		toLat := benchOriginLat + float64(benchGridN-1)*benchStep
		toLng := benchOriginLng + float64(benchGridN-1)*benchStep
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, benchmarkElevatedWeights); err != nil {
				b.Fatal(err)
			}
		}
	})

	b.Run("hop", func(b *testing.B) {
		fromLat, fromLng := benchQuery()
		toLat, toLng := fromLat+benchStep, fromLng
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, benchmarkElevatedWeights); err != nil {
				b.Fatal(err)
			}
		}
	})
}
