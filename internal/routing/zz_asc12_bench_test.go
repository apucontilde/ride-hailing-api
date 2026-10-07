package routing

import "testing"

// Scratch G5 instrument (Stage 2 of the now-condensed
// deadband-calibrate-and-flip execution plan).
//
// The committed BenchmarkRouteElevated uses benchmarkElevatedWeights
// {1.5,0.3,0.15,3}, which is NOT the operating point. This mirrors it on the
// same synthetic elevated lattice but with a distinctly named constant for the
// new operating point, so the historical probes are not silently re-pointed.
// It is scratch/zz_-named: it only runs under `-bench`, never in `go test`.

// benchmarkAsc12Weights is the by-eye operating point (AscentW 12, DescentW 0.3,
// MaxGrade 0.15, DeadbandM 8). The calibrated DeadbandM (3.8) is exercised by
// the real-graph BenchmarkRouteRealSJStage2 in internal/repository.
var benchmarkAsc12Weights = CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 8}

// benchmarkShipPointWeights is the SHIPPED default after the Stage 3 flip:
// AscentW 12, DescentW 0.3, MaxGrade 0.15, the calibrated DeadbandM 3.8. It is a
// distinct constant so benchmarkAsc12Weights (the Stage-2 by-eye probe) and the
// historical benchmarkElevatedWeights stay frozen and honest.
var benchmarkShipPointWeights = CostWeights{AscentW: 12, DescentW: 0.3, MaxGrade: 0.15, DeadbandM: 3.8}

func BenchmarkRouteElevatedAsc12(b *testing.B) {
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
			if _, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, benchmarkAsc12Weights); err != nil {
				b.Fatal(err)
			}
		}
	})

	b.Run("hop", func(b *testing.B) {
		fromLat, fromLng := benchQuery()
		toLat, toLng := fromLat+benchStep, fromLng
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, benchmarkAsc12Weights); err != nil {
				b.Fatal(err)
			}
		}
	})
}

// BenchmarkRouteElevatedShipPoint mirrors BenchmarkRouteElevatedAsc12 on the same
// synthetic lattice but at the actual shipped defaults (deadband 3.8), so the
// committed `make benchmark` covers the post-flip operating point too. The real
// G5 number is the real-graph BenchmarkRouteRealSJStage2; the lattice hides the
// expansion cost.
func BenchmarkRouteElevatedShipPoint(b *testing.B) {
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
			if _, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, benchmarkShipPointWeights); err != nil {
				b.Fatal(err)
			}
		}
	})

	b.Run("hop", func(b *testing.B) {
		fromLat, fromLng := benchQuery()
		toLat, toLng := fromLat+benchStep, fromLng
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if _, err := g.RouteWithWeights(fromLat, fromLng, toLat, toLng, benchmarkShipPointWeights); err != nil {
				b.Fatal(err)
			}
		}
	})
}
