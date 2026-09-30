package service

import (
	"errors"
	"fmt"
	"log"
	"math"
	"os"
	"sort"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/routing"
)

// avgSpeedMps is the routing engine's cost/speed constant (~40 km/h): every
// duration in this package is distance / avgSpeedMps.
const avgSpeedMps = 11

type RouteInfo struct {
	DistanceMeters int
	DurationSecs   int
	Polyline       []model.LatLng
	// IsEstimate is true when no region covered the pins and the response is a
	// straight-line estimate instead of a road-following route (api_plans/05).
	// The field is additive: existing clients keep reading the other three.
	IsEstimate bool
	// AscentM/DescentM are the RAW metres the route climbed/descended
	// (api_plans [elevation] stage 01), 0 when elevation routing is off or the
	// region has no coverage. ElevationAware is per-response: with the
	// coverage gate, elevation can be live for one region and off for another
	// in the same process, so a client needs to know whether the numbers mean
	// anything.
	AscentM        float64
	DescentM       float64
	ElevationAware bool
}

// RegionSource is the OPTIONAL region-resolution capability of a
// NavigationRepository. Repos that implement it let the service answer "which
// region owns this pin?"; repos that don't (mocks, the frozen legacy engine)
// keep the pre-region behavior verbatim.
//
// The interface is declared here, in the layer that consumes it, so
// `repository` never imports `service`: the shipped repos satisfy it
// structurally (compile-time assertions at the bottom of this file).
type RegionSource interface {
	// RegisteredRegions returns the routing-regions registry rows (bbox,
	// level, parent, default flag, datasource).
	RegisteredRegions() ([]model.RegionRef, error)
	// Snap returns the nearest road vertex to a pin INSIDE regionID, and
	// whether the pin is covered. A snap beyond ROUTING_SNAP_RADIUS_M (when
	// configured) is reported as not covered. datasource "" is the local pool.
	Snap(lat, lng float64, datasource, regionID string) (model.SnapResult, bool)
}

// RegionRouter is the optional region-scoped routing capability. A
// RegionSource that also implements it routes against exactly the region the
// resolver picked, so one city's graph can never answer for another's pins.
//
// The datasource travels with the region id because a region's rows may live in
// another city database (api_plans/06): the repo must not have to re-read the
// registry to know which pool to query. "" is the local database.
type RegionRouter interface {
	RouteInRegion(regionID, datasource string, fromLat, fromLng, toLat, toLng float64) ([]repository.RouteResult, error)
}

// The shipped repos must satisfy both optional capabilities.
var (
	_ RegionSource = (*repository.NativeNavigationRepo)(nil)
	_ RegionSource = (*repository.PGRoutingRepo)(nil)
	_ RegionRouter = (*repository.NativeNavigationRepo)(nil)
	_ RegionRouter = (*repository.PGRoutingRepo)(nil)
)

type NavigationService struct {
	navRepo repository.NavigationRepository

	// defaultRegionID is ROUTING_DEFAULT_REGION: the registry row to fall back
	// to when no candidate covers a pin. "" = use the registry's
	// default_region = TRUE row.
	defaultRegionID string
}

func NewNavigationService(navRepo repository.NavigationRepository) *NavigationService {
	return &NavigationService{
		navRepo:         navRepo,
		defaultRegionID: os.Getenv("ROUTING_DEFAULT_REGION"),
	}
}

// GetRoute returns the road-following route between two pins, or a
// straight-line estimate when the pins are outside every imported region.
//
// Resolution order (api_plans/05): the repo must advertise RegionSource; the
// pickup and dropoff must resolve to the SAME region; then routing runs
// region-scoped (RegionRouter) or unscoped (legacy). A repo without
// RegionSource takes the legacy path unchanged, which is what keeps mocks and
// pre-region deployments byte-for-byte compatible.
//
// With api_plans/06 the region also names a datasource (its own city database),
// and a datasource that is down degrades this ONE trip to an estimate instead of
// failing the request (see ErrDatasourceUnavailable).
//
// Every coverage answer ends in an estimate, never in an error: an uncovered pin
// is decided here, by the resolver, and a coverage decision a repository makes
// later (an unscoped path, or a pin the radius gate measures differently) is a
// DATA gap too — see routingDataGap. That is what pins the guarantee "a pin this
// method accepted through Snap can never 500".
func (s *NavigationService) GetRoute(fromLat, fromLng, toLat, toLng float64) (*RouteInfo, error) {
	if _, ok := s.navRepo.(RegionSource); !ok {
		return s.legacyRoute(fromLat, fromLng, toLat, toLng)
	}

	fromRegion, _, err := s.resolveRegion(fromLat, fromLng)
	if err != nil {
		// The registry itself is unreadable (e.g. a database whose migrations
		// predate the region schema). Falling back to the unscoped path keeps
		// routing alive; serving estimates instead would silently flatten every
		// route in the deployment, so this is logged loudly.
		log.Printf("[navigation] region registry unavailable, falling back to unscoped routing: %v", err)
		return s.legacyRoute(fromLat, fromLng, toLat, toLng)
	}
	if fromRegion == nil {
		return estimateRoute(fromLat, fromLng, toLat, toLng), nil
	}

	toRegion, _, err := s.resolveRegion(toLat, toLng)
	if err != nil {
		log.Printf("[navigation] region registry unavailable, falling back to unscoped routing: %v", err)
		return s.legacyRoute(fromLat, fromLng, toLat, toLng)
	}
	// Uncovered dropoff, or a dropoff owned by another region: the trip is not
	// a within-region hop. Cross-region planning is the deferred intercity seam
	// (plan 07), so an estimate is the honest answer.
	if toRegion == nil || toRegion.RegionID != fromRegion.RegionID {
		return estimateRoute(fromLat, fromLng, toLat, toLng), nil
	}

	var (
		nodes []repository.RouteResult
		rerr  error
	)
	if rr, ok := s.navRepo.(RegionRouter); ok {
		nodes, rerr = rr.RouteInRegion(fromRegion.RegionID, fromRegion.Datasource, fromLat, fromLng, toLat, toLng)
	} else {
		// RegionSource without RegionRouter: the repo can resolve coverage but
		// not scope the query, so route the way it always has.
		nodes, rerr = s.navRepo.GetShortestPath(fromLat, fromLng, toLat, toLng)
	}
	if rerr != nil {
		// Another city's database is down (api_plans/06). That is a data gap
		// for THAT city, not a broken request, so it degrades to the same
		// straight-line estimate an uncovered pin gets: HTTP 200, is_estimate,
		// no other region affected. Any other failure stays an error.
		if errors.Is(rerr, repository.ErrDatasourceUnavailable) {
			log.Printf("[navigation] routing datasource unavailable for region %q, serving an estimate: %v", fromRegion.RegionID, rerr)
			return estimateRoute(fromLat, fromLng, toLat, toLng), nil
		}
		// The resolver covered both pins through Snap, so a coverage error
		// from here is the ~0.5% disagreement between PostGIS geography and
		// the engine's own haversine near the radius boundary. The resolver's
		// answer stands; this one must not become a 500.
		if errors.Is(rerr, repository.ErrPinUncovered) {
			log.Printf("[navigation] pin beyond the snap radius in region %q, serving an estimate: %v", fromRegion.RegionID, rerr)
			return estimateRoute(fromLat, fromLng, toLat, toLng), nil
		}
		return nil, rerr
	}
	return routeInfo(fromLat, fromLng, toLat, toLng, nodes)
}

// routingDataGap reports whether a routing error is a DATA gap — the pins or
// the city database are simply not covered — rather than a routing failure. A
// data gap degrades to the straight-line estimate (HTTP 200 + is_estimate);
// everything else stays an error, so a covered-but-unroutable pair (no path in
// the graph, an internal engine fault) is never silently flattened into a
// straight line that the rider app would draw as a real road route.
func routingDataGap(err error) bool {
	return errors.Is(err, repository.ErrPinUncovered) || errors.Is(err, repository.ErrDatasourceUnavailable)
}

// ResolveRegion returns the single region that serves a pin plus the vertex it
// snapped to. ok=false means no registered region covers the pin, which the
// route endpoints turn into a straight-line estimate.
//
// Snap-first by design: candidates (every registry row) are tried in order of
// how close their bbox center is to the pin, and the first real snap wins — so
// a pin a few meters outside a region's admin box still routes instead of
// reading as "not covered". Only when every candidate misses does the default
// region (ROUTING_DEFAULT_REGION, else the registry's default_region row) get
// a second chance. There is deliberately NO parent-chain escalation: the
// hierarchy is the deferred intercity seam (plan 07).
func (s *NavigationService) ResolveRegion(lat, lng float64) (model.RegionRef, model.SnapResult, bool) {
	ref, snap, err := s.resolveRegion(lat, lng)
	if err != nil || ref == nil {
		return model.RegionRef{}, model.SnapResult{}, false
	}
	return *ref, snap, true
}

// resolveRegion is ResolveRegion plus the registry read error and a nil ref
// for "no coverage" — GetRoute needs the error to tell a broken registry from
// an uncovered pin.
func (s *NavigationService) resolveRegion(lat, lng float64) (*model.RegionRef, model.SnapResult, error) {
	src, ok := s.navRepo.(RegionSource)
	if !ok {
		return nil, model.SnapResult{}, nil
	}

	regions, err := src.RegisteredRegions()
	if err != nil {
		return nil, model.SnapResult{}, err
	}

	candidates := orderRegionsByProximity(regions, lat, lng)
	attempted := make(map[string]bool, len(candidates))
	for i := range candidates {
		ref := candidates[i]
		attempted[ref.RegionID] = true
		if snap, snapped := src.Snap(lat, lng, ref.Datasource, ref.RegionID); snapped {
			return &ref, snap, nil
		}
	}

	// No candidate covered the pin: give the default region its own attempt.
	fallback, ok := s.defaultRegion(candidates)
	if ok && !attempted[fallback.RegionID] {
		if snap, snapped := src.Snap(lat, lng, fallback.Datasource, fallback.RegionID); snapped {
			return &fallback, snap, nil
		}
	}
	return nil, model.SnapResult{}, nil
}

// defaultRegion picks the fallback row: the ROUTING_DEFAULT_REGION id when it
// is registered, else the registry's default_region = TRUE row. An env id that
// the registry does not know falls through to the flag rather than disabling
// coverage altogether.
func (s *NavigationService) defaultRegion(candidates []model.RegionRef) (model.RegionRef, bool) {
	if s.defaultRegionID != "" {
		for _, ref := range candidates {
			if ref.RegionID == s.defaultRegionID {
				return ref, true
			}
		}
	}
	for _, ref := range candidates {
		if ref.Default {
			return ref, true
		}
	}
	return model.RegionRef{}, false
}

// orderRegionsByProximity sorts the registry rows by the distance from the
// pin to each region's bbox center, nearest first. The sort is stable, so
// equidistant regions keep the registry's own (region_id) order.
func orderRegionsByProximity(regions []model.RegionRef, lat, lng float64) []model.RegionRef {
	ordered := make([]model.RegionRef, len(regions))
	copy(ordered, regions)
	sort.SliceStable(ordered, func(i, j int) bool {
		return bboxCenterDistance(ordered[i], lat, lng) < bboxCenterDistance(ordered[j], lat, lng)
	})
	return ordered
}

func bboxCenterDistance(ref model.RegionRef, lat, lng float64) float64 {
	centerLat := (ref.BBox[1] + ref.BBox[3]) / 2
	centerLng := (ref.BBox[0] + ref.BBox[2]) / 2
	return routing.HaversineMeters(centerLat, centerLng, lat, lng)
}

// legacyRoute is the pre-region path: a repo that cannot resolve regions routes
// the way it did before api_plans/05, which is what keeps mocks and pre-region
// deployments byte-for-byte compatible. It has no resolver to decide coverage,
// so the repository's own snap-radius gate is the authority here — and its
// answer is a data gap, not a failure, so an uncovered pin is an estimate
// rather than the 500 that made the rider app draw a road-less route.
func (s *NavigationService) legacyRoute(fromLat, fromLng, toLat, toLng float64) (*RouteInfo, error) {
	nodes, err := s.navRepo.GetShortestPath(fromLat, fromLng, toLat, toLng)
	if err != nil {
		if routingDataGap(err) {
			log.Printf("[navigation] unscoped routing data gap, serving an estimate: %v", err)
			return estimateRoute(fromLat, fromLng, toLat, toLng), nil
		}
		return nil, err
	}
	return routeInfo(fromLat, fromLng, toLat, toLng, nodes)
}

// routeInfo turns routed nodes into the wire shape: the polyline is anchored
// to the exact pins (not just the snapped nodes) and the distance is the last
// node's accumulated edge cost, which is the route length in meters.
func routeInfo(fromLat, fromLng, toLat, toLng float64, nodes []repository.RouteResult) (*RouteInfo, error) {
	if len(nodes) == 0 {
		return nil, fmt.Errorf("no route found")
	}

	var polyline []model.LatLng
	// Anchor the drawn line to the exact pins, not just the snapped nodes.
	polyline = appendPoint(polyline, model.LatLng{Lat: fromLat, Lng: fromLng})
	for _, n := range nodes {
		polyline = appendPoint(polyline, model.LatLng{Lat: n.Lat, Lng: n.Lng})
	}
	polyline = appendPoint(polyline, model.LatLng{Lat: toLat, Lng: toLng})

	totalDistance := int(nodes[len(nodes)-1].AggCost)
	last := nodes[len(nodes)-1]

	return &RouteInfo{
		DistanceMeters: totalDistance,
		DurationSecs:   totalDistance / avgSpeedMps,
		Polyline:       polyline,
		AscentM:        last.AscentM,
		DescentM:       last.DescentM,
		ElevationAware: last.ElevationAware,
	}, nil
}

// estimateRoute is the no-coverage answer (api_plans/05): a 200 with a
// straight line between the pins and is_estimate=true. A pin outside every
// imported region is a DATA gap, not a malformed request, so it must never
// become a 422.
func estimateRoute(fromLat, fromLng, toLat, toLng float64) *RouteInfo {
	distance := int(math.Round(routing.HaversineMeters(fromLat, fromLng, toLat, toLng)))

	polyline := appendPoint(nil, model.LatLng{Lat: fromLat, Lng: fromLng})
	polyline = appendPoint(polyline, model.LatLng{Lat: toLat, Lng: toLng})

	return &RouteInfo{
		DistanceMeters: distance,
		DurationSecs:   distance / avgSpeedMps,
		Polyline:       polyline,
		IsEstimate:     true,
	}
}

func appendPoint(points []model.LatLng, p model.LatLng) []model.LatLng {
	if len(points) > 0 {
		last := points[len(points)-1]
		if last.Lat == p.Lat && last.Lng == p.Lng {
			return points
		}
	}
	return append(points, p)
}
