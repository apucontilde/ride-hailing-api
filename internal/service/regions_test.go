package service

import (
	"errors"
	"fmt"
	"math"
	"testing"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/routing"
)

// ---- fakes -------------------------------------------------------------
//
// Three fakes, one per capability level, so each test states exactly which
// repository contract it is exercising:
//   - navRepoFake        GetShortestPath only            (pre-region repo)
//   - regionRepoFake     + RegisteredRegions + Snap      (RegionSource)
//   - regionRouterFake   + RouteInRegion                 (RegionSource + RegionRouter)

type pinKey [2]float64

type snapCall struct {
	Lat        float64
	Lng        float64
	Datasource string
	RegionID   string
}

// coverage says which regions cover which pin: pin -> region id -> snaps.
// A region missing from a pin's set is "not covered" for that pin, which is
// what a region-scoped KNN with no vertex in range returns.
type coverage map[pinKey]map[string]bool

// cover builds a coverage table from pin -> covered region ids.
func cover(pin [2]float64, regionIDs ...string) coverage {
	c := coverage{}
	for _, id := range regionIDs {
		if c[pinKey(pin)] == nil {
			c[pinKey(pin)] = map[string]bool{}
		}
		c[pinKey(pin)][id] = true
	}
	return c
}

// navRepoFake is a repository that knows nothing about regions, like
// tests/testutil.MockNavigationRepo.
type navRepoFake struct {
	nodes   []repository.RouteResult
	err     error
	pathIDs []string // one entry per GetShortestPath call ("unscoped")
}

func (f *navRepoFake) GetShortestPath(fromLat, fromLng, toLat, toLng float64) ([]repository.RouteResult, error) {
	f.pathIDs = append(f.pathIDs, "unscoped")
	if f.err != nil {
		return nil, f.err
	}
	return f.nodes, nil
}

// regionRepoFake resolves regions from an in-memory registry plus the coverage
// table, and records every Snap attempt.
type regionRepoFake struct {
	navRepoFake
	regions    []model.RegionRef
	regionsErr error
	covered    coverage
	snapCalls  []snapCall
}

func newRegionRepo(regions []model.RegionRef, covered coverage) *regionRepoFake {
	return &regionRepoFake{regions: regions, covered: covered}
}

func (f *regionRepoFake) RegisteredRegions() ([]model.RegionRef, error) {
	if f.regionsErr != nil {
		return nil, f.regionsErr
	}
	return f.regions, nil
}

func (f *regionRepoFake) Snap(lat, lng float64, datasource, regionID string) (model.SnapResult, bool) {
	f.snapCalls = append(f.snapCalls, snapCall{Lat: lat, Lng: lng, Datasource: datasource, RegionID: regionID})
	if !f.covered[pinKey{lat, lng}][regionID] {
		return model.SnapResult{}, false
	}
	return model.SnapResult{VertexID: 1, DistanceM: 12.5, Lat: lat, Lng: lng}, true
}

// regionRouterFake adds the region-scoped routing capability and records which
// region each call was routed in.
type regionRouterFake struct {
	regionRepoFake
	routes    map[string][]repository.RouteResult
	routesErr error
	routeIDs  []routeCall
}

// routeCall is one recorded RouteInRegion call: the region the resolver picked
// plus the datasource it named, which is how the repo knows which pool to query.
type routeCall struct {
	RegionID   string
	Datasource string
}

func newRouterRepo(regions []model.RegionRef, covered coverage) *regionRouterFake {
	return &regionRouterFake{regionRepoFake: *newRegionRepo(regions, covered)}
}

func (f *regionRouterFake) RouteInRegion(regionID, datasource string, fromLat, fromLng, toLat, toLng float64) ([]repository.RouteResult, error) {
	f.routeIDs = append(f.routeIDs, routeCall{RegionID: regionID, Datasource: datasource})
	if f.routesErr != nil {
		return nil, f.routesErr
	}
	nodes, ok := f.routes[regionID]
	if !ok {
		return nil, routing.ErrNoRoute
	}
	return nodes, nil
}

// ---- fixtures ----------------------------------------------------------

// registry is a country row plus two city rows. BBoxes are [lonMin, latMin,
// lonMax, latMax]; cr-sj is the registry default.
func registry() []model.RegionRef {
	return []model.RegionRef{
		{RegionID: "cr", Level: "country", Default: false, BBox: [4]float64{-85.95, 7.98, -82.55, 11.22}},
		{RegionID: "cr-sj", Level: "state", Parent: "cr", Default: true, BBox: [4]float64{-84.50, 9.00, -83.50, 10.20}},
		{RegionID: "cr-lc", Level: "city", Parent: "cr", Default: false, BBox: [4]float64{-84.99, 10.00, -84.95, 10.05}},
	}
}

var (
	sjPin      = [2]float64{9.93, -84.08}     // inside cr-sj
	sjDropPin  = [2]float64{9.9433, -84.0733} // also inside cr-sj
	lcPin      = [2]float64{10.02, -84.97}    // inside cr-lc (the nearest candidate)
	lcDropPin  = [2]float64{10.026, -84.966}  // also inside cr-lc
	pacificPin = [2]float64{5.00, -90.00}     // no region anywhere near
)

// multiCityRegistry is registry() with cr-lc living in ANOTHER city database
// (api_plans/06): the resolver's RegionRef now carries a datasource.
func multiCityRegistry() []model.RegionRef {
	regions := registry()
	for i := range regions {
		if regions[i].RegionID == "cr-lc" {
			regions[i].Datasource = "lc-db"
		}
	}
	return regions
}

// ---- ResolveRegion -----------------------------------------------------

func TestResolveRegionOrdersCandidatesByProximityAndSnapsFirst(t *testing.T) {
	repo := newRegionRepo(registry(), cover(sjPin, "cr-sj"))
	svc := &NavigationService{navRepo: repo}

	// cr-sj's bbox center is nearest the SJ pin even though the country row
	// has the biggest box and sorts first by region_id.
	ref, snap, ok := svc.ResolveRegion(sjPin[0], sjPin[1])
	if !ok {
		t.Fatal("SJ pin must resolve")
	}
	if ref.RegionID != "cr-sj" {
		t.Errorf("resolved %q, want cr-sj", ref.RegionID)
	}
	if snap.DistanceM != 12.5 {
		t.Errorf("snap distance = %v, want the fake's 12.5 m", snap.DistanceM)
	}
	if len(repo.snapCalls) == 0 {
		t.Fatal("Snap was never called")
	}
	// Snap-first: the nearest candidate is tried first and stops the walk.
	if got := repo.snapCalls[0].RegionID; got != "cr-sj" {
		t.Errorf("first snap candidate = %q, want cr-sj", got)
	}
}

func TestResolveRegionWalksPastUncoveredCandidates(t *testing.T) {
	// The LC pin is nearest cr-lc's center, but only the country row covers
	// it: the walk must pass the uncovered near candidate and take the farther
	// one rather than declaring "no coverage".
	repo := newRegionRepo(registry(), cover(lcPin, "cr"))
	svc := &NavigationService{navRepo: repo}

	ref, _, ok := svc.ResolveRegion(lcPin[0], lcPin[1])
	if !ok {
		t.Fatal("pin covered by cr must resolve even though cr-lc is nearer")
	}
	if ref.RegionID != "cr" {
		t.Errorf("resolved %q, want cr", ref.RegionID)
	}
	if len(repo.snapCalls) != 2 {
		t.Fatalf("snap attempts = %d, want cr-lc then cr", len(repo.snapCalls))
	}
	if repo.snapCalls[0].RegionID != "cr-lc" || repo.snapCalls[1].RegionID != "cr" {
		t.Errorf("candidates tried %q then %q, want cr-lc then cr",
			repo.snapCalls[0].RegionID, repo.snapCalls[1].RegionID)
	}
	// A region id never leaks a datasource from the registry into the query.
	for _, call := range repo.snapCalls {
		if call.Datasource != "" {
			t.Errorf("snap for %q carried datasource %q, want the local pool",
				call.RegionID, call.Datasource)
		}
	}
}

func TestResolveRegionNoCoverage(t *testing.T) {
	repo := newRegionRepo(registry(), nil) // no region covers anything
	svc := &NavigationService{navRepo: repo}

	ref, snap, ok := svc.ResolveRegion(pacificPin[0], pacificPin[1])
	if ok {
		t.Fatalf("uncovered pin must not resolve (got %+v)", ref)
	}
	if ref.RegionID != "" || snap.VertexID != 0 {
		t.Errorf("uncovered pin must return the zero values, got %+v / %+v", ref, snap)
	}
	// Every candidate is tried before giving up, so a later region can still win.
	if len(repo.snapCalls) != len(registry()) {
		t.Errorf("tried %d candidates, want all %d", len(repo.snapCalls), len(registry()))
	}
}

func TestResolveRegionRequiresRegionSource(t *testing.T) {
	// A repo without the optional capability cannot resolve anything.
	svc := NewNavigationService(&navRepoFake{})

	if _, _, ok := svc.ResolveRegion(sjPin[0], sjPin[1]); ok {
		t.Error("a repo without RegionSource must not report coverage")
	}
}

func TestResolveRegionRegistryErrorIsNotCoverage(t *testing.T) {
	repo := newRegionRepo(registry(), cover(sjPin, "cr-sj"))
	repo.regionsErr = errors.New(`relation "routing_regions" does not exist`)
	svc := &NavigationService{navRepo: repo}

	if _, _, ok := svc.ResolveRegion(sjPin[0], sjPin[1]); ok {
		t.Error("a broken registry must not read as coverage")
	}
	if len(repo.snapCalls) != 0 {
		t.Errorf("no snap may be attempted without a registry, got %+v", repo.snapCalls)
	}
}

// The default-region row comes from the registry flag; an explicit
// ROUTING_DEFAULT_REGION wins over it.
func TestDefaultRegionSelection(t *testing.T) {
	all := registry()

	t.Run("registry_flag", func(t *testing.T) {
		ref, ok := (&NavigationService{}).defaultRegion(all)
		if !ok || ref.RegionID != "cr-sj" {
			t.Errorf("got %+v (ok=%v), want the default_region row cr-sj", ref, ok)
		}
	})

	t.Run("env_override_wins", func(t *testing.T) {
		ref, ok := (&NavigationService{defaultRegionID: "cr"}).defaultRegion(all)
		if !ok || ref.RegionID != "cr" {
			t.Errorf("got %+v (ok=%v), want cr", ref, ok)
		}
	})

	t.Run("env_override_unknown_falls_back_to_flag", func(t *testing.T) {
		ref, ok := (&NavigationService{defaultRegionID: "does-not-exist"}).defaultRegion(all)
		if !ok || ref.RegionID != "cr-sj" {
			t.Errorf("got %+v (ok=%v), want the registry fallback cr-sj", ref, ok)
		}
	})

	t.Run("no_default_anywhere", func(t *testing.T) {
		ref, ok := (&NavigationService{}).defaultRegion([]model.RegionRef{
			{RegionID: "cr-sj", Default: false},
		})
		if ok {
			t.Errorf("no default row and no env override must yield none, got %+v", ref)
		}
	})
}

func TestOrderRegionsByProximity(t *testing.T) {
	ordered := orderRegionsByProximity(registry(), sjPin[0], sjPin[1])
	if len(ordered) != len(registry()) {
		t.Fatalf("length %d, want %d", len(ordered), len(registry()))
	}
	// Distances must be non-increasing (no two centers coincide here).
	for i := 1; i < len(ordered); i++ {
		prev := bboxCenterDistance(ordered[i-1], sjPin[0], sjPin[1])
		cur := bboxCenterDistance(ordered[i], sjPin[0], sjPin[1])
		if cur < prev {
			t.Errorf("not ordered: %s (%.0fm) before %s (%.0fm)",
				ordered[i-1].RegionID, prev, ordered[i].RegionID, cur)
		}
	}
	// The input slice must not be reordered in place (the registry is shared).
	if registry()[0].RegionID != "cr" {
		t.Error("orderRegionsByProximity mutated its input")
	}
}

// ---- GetRoute ----------------------------------------------------------

// The legacy path: a repo without RegionSource behaves exactly as before.
func TestGetRouteLegacyRepoUnchanged(t *testing.T) {
	repo := &navRepoFake{nodes: []repository.RouteResult{
		{NodeID: 1, NodeSeq: 0, Lat: 9.9400, Lng: -84.0800},
		{NodeID: 2, NodeSeq: 1, Lat: 9.9433, Lng: -84.0733, AggCost: 5000},
	}}
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("a routed legacy response must not be flagged as an estimate")
	}
	if got.DistanceMeters != 5000 || got.DurationSecs != 5000/11 {
		t.Errorf("got %d m / %d s, want 5000 m / %d s", got.DistanceMeters, got.DurationSecs, 5000/11)
	}
	if got.RegionID != "" {
		t.Errorf("the legacy unscoped path must carry no region, got %q", got.RegionID)
	}
	want := []model.LatLng{
		{Lat: sjPin[0], Lng: sjPin[1]}, // pinned origin
		{Lat: 9.9400, Lng: -84.0800},
		{Lat: sjDropPin[0], Lng: sjDropPin[1]}, // snapped node doubles as the pinned end
	}
	if len(got.Polyline) != len(want) {
		t.Fatalf("polyline %+v, want %d points", got.Polyline, len(want))
	}
	for i := range want {
		if got.Polyline[i] != want[i] {
			t.Errorf("polyline[%d] = %+v, want %+v", i, got.Polyline[i], want[i])
		}
	}
	if len(repo.pathIDs) != 1 {
		t.Errorf("expected exactly one GetShortestPath call, got %v", repo.pathIDs)
	}
}

func TestGetRouteLegacyRepoError(t *testing.T) {
	repo := &navRepoFake{err: routing.ErrNoRoute}
	svc := NewNavigationService(repo)

	if _, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1]); !errors.Is(err, routing.ErrNoRoute) {
		t.Fatalf("got %v, want %v", err, routing.ErrNoRoute)
	}
}

// A broken registry must not turn every route into an estimate.
func TestGetRouteFallsBackToLegacyWhenRegistryUnreadable(t *testing.T) {
	repo := newRegionRepo(registry(), cover(sjPin, "cr-sj"))
	repo.nodes = []repository.RouteResult{
		{NodeID: 1, Lat: 9.9400, Lng: -84.0800},
		{NodeID: 2, Lat: 9.9433, Lng: -84.0733, AggCost: 1200},
	}
	repo.regionsErr = errors.New("registry unavailable")
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("a registry failure must degrade to the legacy path, not to an estimate")
	}
	if got.DistanceMeters != 1200 {
		t.Errorf("got %d m, want the legacy 1200 m", got.DistanceMeters)
	}
	if len(repo.pathIDs) != 1 {
		t.Errorf("expected the legacy GetShortestPath fallback, got %v", repo.pathIDs)
	}
}

// No coverage: straight-line estimate, HTTP-200 semantics, pinned endpoints.
func TestGetRouteNoCoverageIsEstimate(t *testing.T) {
	toLat, toLng := pacificPin[0]+1, pacificPin[1]+1
	repo := newRegionRepo(registry(), nil)
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(pacificPin[0], pacificPin[1], toLat, toLng)
	if err != nil {
		t.Fatalf("no coverage must not be an error: %v", err)
	}
	if !got.IsEstimate {
		t.Error("IsEstimate must be true when no region covers the pins")
	}
	if got.RegionID != "" {
		t.Errorf("an estimate must never invent a region, got %q", got.RegionID)
	}

	straight := routing.HaversineMeters(pacificPin[0], pacificPin[1], toLat, toLng)
	wantDist := int(math.Round(straight))
	if got.DistanceMeters != wantDist {
		t.Errorf("distance = %d, want the straight line %d", got.DistanceMeters, wantDist)
	}
	if wantDur := wantDist / 11; got.DurationSecs != wantDur {
		t.Errorf("duration = %d s, want %d s (distance / 11)", got.DurationSecs, wantDur)
	}
	if len(got.Polyline) != 2 {
		t.Fatalf("estimate polyline = %+v, want exactly the 2 pinned points", got.Polyline)
	}
	if got.Polyline[0] != (model.LatLng{Lat: pacificPin[0], Lng: pacificPin[1]}) ||
		got.Polyline[1] != (model.LatLng{Lat: toLat, Lng: toLng}) {
		t.Errorf("estimate polyline must be the two pins, got %+v", got.Polyline)
	}
	if len(repo.pathIDs) != 0 {
		t.Errorf("an uncovered pin must never reach the router, got %v", repo.pathIDs)
	}
}

// Both pins in one region: routing runs in THAT region (RegionRouter).
func TestGetRouteRoutesInResolvedRegion(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {
			{NodeID: 1, NodeSeq: 0, Lat: 9.9350, Lng: -84.0800},
			{NodeID: 2, NodeSeq: 1, Lat: 9.9433, Lng: -84.0733, AggCost: 2094},
		},
	}
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("a covered, in-region trip must not be an estimate")
	}
	if len(repo.routeIDs) != 1 || repo.routeIDs[0].RegionID != "cr-sj" {
		t.Fatalf("RouteInRegion calls = %+v, want one call in cr-sj", repo.routeIDs)
	}
	if got.RegionID != "cr-sj" {
		t.Errorf("RouteInfo.RegionID = %q, want the resolved cr-sj so the fare layer prices the right card", got.RegionID)
	}
	if got.DistanceMeters != 2094 || got.DurationSecs != 2094/11 {
		t.Errorf("got %d m / %d s, want 2094 m / %d s", got.DistanceMeters, got.DurationSecs, 2094/11)
	}
	// Pinned origin, the first routed node, then the pinned dropoff — the last
	// routed node sits on the pin and is deduped by appendPoint.
	want := []model.LatLng{
		{Lat: sjPin[0], Lng: sjPin[1]},
		{Lat: 9.9350, Lng: -84.0800},
		{Lat: sjDropPin[0], Lng: sjDropPin[1]},
	}
	if len(got.Polyline) != len(want) {
		t.Fatalf("polyline = %+v, want %d points", got.Polyline, len(want))
	}
	for i := range want {
		if got.Polyline[i] != want[i] {
			t.Errorf("polyline[%d] = %+v, want %+v", i, got.Polyline[i], want[i])
		}
	}
	if len(repo.pathIDs) != 0 {
		t.Errorf("a region router must be preferred over the unscoped path, got %v", repo.pathIDs)
	}
}

// api_plans/06: the datasource the resolver picked travels with the region into
// the routing call, so the repo can query that city's own pool — and the
// registry's datasource never leaks onto another region's call.
func TestGetRouteRoutesInTheResolvedRegionsDatasource(t *testing.T) {
	repo := newRouterRepo(multiCityRegistry(), cover(lcPin, "cr-lc"))
	repo.covered[pinKey(lcDropPin)] = map[string]bool{"cr-lc": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-lc": {
			{NodeID: 1, NodeSeq: 0, Lat: 10.0150, Lng: -84.9800},
			{NodeID: 2, NodeSeq: 1, Lat: 10.0260, Lng: -84.9660, AggCost: 900},
		},
	}
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(lcPin[0], lcPin[1], lcDropPin[0], lcDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("a covered, in-region trip must not be an estimate")
	}
	if got.DistanceMeters != 900 {
		t.Errorf("distance = %d m, want the routed 900 m", got.DistanceMeters)
	}
	if len(repo.routeIDs) != 1 {
		t.Fatalf("RouteInRegion calls = %+v, want exactly one", repo.routeIDs)
	}
	if repo.routeIDs[0] != (routeCall{RegionID: "cr-lc", Datasource: "lc-db"}) {
		t.Errorf("routed in %+v, want cr-lc on datasource lc-db", repo.routeIDs[0])
	}
	// The same datasource must have been handed to every snap of that region.
	for _, call := range repo.snapCalls {
		if call.RegionID == "cr-lc" && call.Datasource != "lc-db" {
			t.Errorf("snap for cr-lc carried datasource %q, want lc-db", call.Datasource)
		}
	}
}

// A RegionSource that is not a RegionRouter still routes: region resolution
// gates coverage, the unscoped query does the work.
func TestGetRouteRegionSourceWithoutRouterUsesLegacyPath(t *testing.T) {
	repo := newRegionRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.nodes = []repository.RouteResult{
		{NodeID: 1, Lat: 9.9350, Lng: -84.0800},
		{NodeID: 2, Lat: 9.9433, Lng: -84.0733, AggCost: 1500},
	}
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.DistanceMeters != 1500 || got.IsEstimate {
		t.Errorf("got %+v, want a non-estimate 1500 m route", got)
	}
	// It resolved a region even though it routed unscoped, so the region is
	// still exposed to the fare layer.
	if got.RegionID != "cr-sj" {
		t.Errorf("RouteInfo.RegionID = %q, want cr-sj", got.RegionID)
	}
	if len(repo.pathIDs) != 1 {
		t.Errorf("expected the unscoped GetShortestPath fallback, got %v", repo.pathIDs)
	}
}

// Routing failures stay errors (HTTP 500) — only "no coverage" is an estimate.
func TestGetRouteRoutingErrorIsNotAnEstimate(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.routesErr = routing.ErrNoRoute
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if !errors.Is(err, routing.ErrNoRoute) {
		t.Fatalf("got %+v / %v, want ErrNoRoute", got, err)
	}
	if got != nil {
		t.Error("a failed route must return no RouteInfo")
	}
}

// A city database that is down is a DATA gap for that city, not a broken
// request: it degrades to the same straight-line estimate an uncovered pin gets
// (HTTP 200, is_estimate) and leaves every other region alone.
func TestGetRouteDatasourceUnavailableIsEstimate(t *testing.T) {
	repo := newRouterRepo(multiCityRegistry(), cover(lcPin, "cr-lc"))
	repo.covered[pinKey(lcDropPin)] = map[string]bool{"cr-lc": true}
	repo.routesErr = fmt.Errorf("dialing lc-db: %w", repository.ErrDatasourceUnavailable)
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(lcPin[0], lcPin[1], lcDropPin[0], lcDropPin[1])
	if err != nil {
		t.Fatalf("an unavailable datasource must not fail the request: %v", err)
	}
	if !got.IsEstimate {
		t.Error("a datasource that cannot be reached must read as an estimate")
	}
	wantDist := int(math.Round(routing.HaversineMeters(lcPin[0], lcPin[1], lcDropPin[0], lcDropPin[1])))
	if got.DistanceMeters != wantDist {
		t.Errorf("distance = %d m, want the straight line %d m", got.DistanceMeters, wantDist)
	}
	if wantDur := wantDist / 11; got.DurationSecs != wantDur {
		t.Errorf("duration = %d s, want %d s", got.DurationSecs, wantDur)
	}

	// The same repository still routes the OTHER city, whose datasource is "".
	repo.covered[pinKey(sjPin)] = map[string]bool{"cr-sj": true}
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-sj": true}
	repo.routesErr = nil
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {
			{NodeID: 1, Lat: 9.9350, Lng: -84.0800},
			{NodeID: 2, AggCost: 2094, Lat: 9.9433, Lng: -84.0733},
		},
	}
	other, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("the local city must keep routing: %v", err)
	}
	if other.IsEstimate || other.DistanceMeters != 2094 {
		t.Errorf("got %+v, want a real 2094 m route for the unaffected city", other)
	}
}

// Cross-region trips are out of scope (intercity is plan 07's seam): an
// estimate, not a bogus cross-graph path.
func TestGetRouteCrossRegionIsEstimate(t *testing.T) {
	repo := newRouterRepo(registry(), cover(sjPin, "cr-sj"))
	repo.covered[pinKey(sjDropPin)] = map[string]bool{"cr-lc": true}
	repo.routes = map[string][]repository.RouteResult{
		"cr-sj": {{NodeID: 1, Lat: 9.9350, Lng: -84.0800, AggCost: 100}},
	}
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.IsEstimate {
		t.Error("a pickup and dropoff in different regions must yield an estimate")
	}
	if len(repo.routeIDs) != 0 {
		t.Errorf("a cross-region trip must not be routed in either region, got %v", repo.routeIDs)
	}
	wantDist := int(math.Round(routing.HaversineMeters(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])))
	if got.DistanceMeters != wantDist {
		t.Errorf("distance = %d, want the straight line %d", got.DistanceMeters, wantDist)
	}
}

// An uncovered dropoff with a covered pickup is an estimate too.
func TestGetRouteUncoveredDropoffIsEstimate(t *testing.T) {
	repo := newRegionRepo(registry(), cover(sjPin, "cr-sj"))
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(sjPin[0], sjPin[1], pacificPin[0], pacificPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.IsEstimate {
		t.Error("a pickup in a region and a dropoff outside every region must be an estimate")
	}
}

// ---- finite snap radius (api_plans [routing]_estimate_fallback_default) ---
//
// radiusRepoFake is a regionRepoFake whose Snap answers with the REAL coverage
// rule (repository.WithinSnapRadius) against a per-pin snap distance, so these
// tests exercise the production predicate rather than a test-local copy of it.
// It stands in for a region whose nearest road vertex is snapDistM from the
// pin — the exact situation the finite ROUTING_SNAP_RADIUS_M default exists to
// catch.
//
// The radius is read from a *config.Config, never from a literal in the fake:
// the value under test is the one an operator's environment produces, and the
// repository-side tests (internal/repository/snap_radius_test.go) pin that the
// production constructor and engine factory store this very value on the real
// repos. Between the two, config -> ctor -> Snap is covered end to end.
type radiusRepoFake struct {
	*regionRouterFake
	radiusM   float64
	snapDistM map[pinKey]float64 // pin -> distance to that region's nearest road
}

func newRadiusRepo(regions []model.RegionRef, cfg *config.Config, snapDistM map[pinKey]float64) *radiusRepoFake {
	// The embedded coverage table is never consulted (Snap below answers from
	// snapDistM), so it stays empty: this fake's coverage IS the radius rule.
	return &radiusRepoFake{
		regionRouterFake: newRouterRepo(regions, coverage{}),
		radiusM:          cfg.RoutingSnapRadiusM,
		snapDistM:        snapDistM,
	}
}

func (f *radiusRepoFake) Snap(lat, lng float64, datasource, regionID string) (model.SnapResult, bool) {
	pin := pinKey{lat, lng}
	f.snapCalls = append(f.snapCalls, snapCall{Lat: lat, Lng: lng, Datasource: datasource, RegionID: regionID})
	dist, hasVertex := f.snapDistM[pin]
	if !hasVertex {
		// No road vertex at all in range for this pin (a region that simply
		// does not cover it).
		return model.SnapResult{}, false
	}
	if !repository.WithinSnapRadius(dist, f.radiusM) {
		// The real repo's rule: beyond the radius is "not covered".
		return model.SnapResult{}, false
	}
	return model.SnapResult{VertexID: 1, DistanceM: dist, Lat: lat, Lng: lng}, true
}

// routesInEveryRegion lets a test assert on the ROUTE without pinning which
// region the proximity-ordered resolver happens to pick first for its pin
// (that ordering is its own test above).
func routesInEveryRegion(regions []model.RegionRef, nodes []repository.RouteResult) map[string][]repository.RouteResult {
	routes := make(map[string][]repository.RouteResult, len(regions))
	for _, ref := range regions {
		routes[ref.RegionID] = nodes
	}
	return routes
}

// The bug (#2) end to end at the service layer: with the SHIPPED default radius,
// a pin tens of km from any road resolves to no region, so GetRoute degrades to
// the straight-line estimate — a 200 with is_estimate, never a bogus snapped
// route. This is the path that was dead while the default was 0.
func TestGetRouteBeyondSnapRadiusIsEstimateWithTheDefaultRadius(t *testing.T) {
	// The REAL shipped default, not a restated 50000: this test is the
	// end-to-end proof that a configuration change re-opens or closes the bug.
	t.Setenv("ROUTING_SNAP_RADIUS_M", "")
	cfg := config.Load()
	defaultRadius := cfg.RoutingSnapRadiusM
	if defaultRadius <= 0 {
		t.Fatalf("the shipped default radius is %v; the estimate path would be unreachable", defaultRadius)
	}

	repo := newRadiusRepo(registry(), cfg, map[pinKey]float64{
		pinKey(sjPin):     300,  // an urban pickup: meters from a road
		pinKey(sjDropPin): 1200, // also served
	})
	// A second trip whose pickup is in unserved country.
	remotePin := [2]float64{5.00, -90.00}
	remoteDrop := [2]float64{5.01, -90.01}
	repo.snapDistM[pinKey(remotePin)] = 60000 // 60 km from the nearest road

	// The default radius is finite, so the remote pickup has no coverage at
	// all: every candidate is tried and every one is rejected as too far.
	if ref, _, _ := (&NavigationService{navRepo: repo}).resolveRegion(remotePin[0], remotePin[1]); ref != nil {
		t.Fatalf("a 60000 m pin must be uncovered under the %v m default, got %+v", defaultRadius, ref)
	}

	svc := NewNavigationService(repo)
	got, err := svc.GetRoute(remotePin[0], remotePin[1], remoteDrop[0], remoteDrop[1])
	if err != nil {
		t.Fatalf("no coverage must not be an error: %v", err)
	}
	if !got.IsEstimate {
		t.Error("a beyond-radius pin must answer is_estimate, not a snapped route")
	}
	wantDist := int(math.Round(routing.HaversineMeters(remotePin[0], remotePin[1], remoteDrop[0], remoteDrop[1])))
	if got.DistanceMeters != wantDist {
		t.Errorf("distance = %d m, want the straight line %d m", got.DistanceMeters, wantDist)
	}
	if wantDur := wantDist / 11; got.DurationSecs != wantDur {
		t.Errorf("duration = %d s, want %d s", got.DurationSecs, wantDur)
	}
	if len(got.Polyline) != 2 ||
		got.Polyline[0] != (model.LatLng{Lat: remotePin[0], Lng: remotePin[1]}) ||
		got.Polyline[1] != (model.LatLng{Lat: remoteDrop[0], Lng: remoteDrop[1]}) {
		t.Errorf("estimate polyline = %+v, want exactly the two pinned points", got.Polyline)
	}
	if len(repo.routeIDs) != 0 {
		t.Errorf("an uncovered pin must never reach the router, got %+v", repo.routeIDs)
	}

	// The same repository keeps routing ordinary urban trips: the finite
	// default must not turn a covered pin into an estimate.
	repo.routes = routesInEveryRegion(registry(), []repository.RouteResult{
		{NodeID: 1, NodeSeq: 0, Lat: 9.9350, Lng: -84.0800},
		{NodeID: 2, NodeSeq: 1, Lat: 9.9433, Lng: -84.0733, AggCost: 2094},
	})
	urban, err := svc.GetRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if urban.IsEstimate {
		t.Error("pins well within the default radius must still route")
	}
	if urban.DistanceMeters != 2094 {
		t.Errorf("distance = %d m, want the routed 2094 m", urban.DistanceMeters)
	}
	if len(repo.routeIDs) != 1 || repo.routeIDs[0].RegionID != "cr-sj" {
		t.Errorf("RouteInRegion calls = %+v, want exactly one in cr-sj", repo.routeIDs)
	}
}

// The documented opt-in: an explicit ROUTING_SNAP_RADIUS_M=0 keeps snapping
// unconditionally, so the very same 60 km pin routes again and the honest
// estimate is NOT what an operator who asked for always-snap gets.
func TestGetRouteRadiusZeroOptInStillSnapsUnconditionally(t *testing.T) {
	remotePin := [2]float64{5.00, -90.00}
	remoteDrop := [2]float64{5.01, -90.01}

	// The opt-in is the ENVIRONMENT value, so this also fails if a "0" typo
	// ever degrades to the 50 km default (the direction bug #2 came from).
	t.Setenv("ROUTING_SNAP_RADIUS_M", "0")
	cfg := config.Load()
	if cfg.RoutingSnapRadiusM != 0 {
		t.Fatalf("ROUTING_SNAP_RADIUS_M=0 loaded as %v, want 0", cfg.RoutingSnapRadiusM)
	}

	repo := newRadiusRepo(registry(), cfg, map[pinKey]float64{
		pinKey(remotePin):  60000,
		pinKey(remoteDrop): 70000,
	})
	repo.routes = routesInEveryRegion(registry(), []repository.RouteResult{
		{NodeID: 1, NodeSeq: 0, Lat: 5.00, Lng: -90.00},
		{NodeID: 2, NodeSeq: 1, Lat: 5.01, Lng: -90.01, AggCost: 83000},
	})
	svc := NewNavigationService(repo)

	got, err := svc.GetRoute(remotePin[0], remotePin[1], remoteDrop[0], remoteDrop[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IsEstimate {
		t.Error("with radius 0 (always-snap opt-in) a far pin must still route, not degrade")
	}
	if got.DistanceMeters != 83000 {
		t.Errorf("distance = %d m, want the routed 83000 m", got.DistanceMeters)
	}
	if len(repo.routeIDs) != 1 {
		t.Errorf("RouteInRegion calls = %+v, want exactly one", repo.routeIDs)
	}
}

// A tighter operator-chosen radius turns a moderately-far pin into an estimate
// while a nearby one keeps routing: the knob is real, not just a default value.
func TestGetRouteTighterRadiusOnlyDegradesFarPins(t *testing.T) {
	farPin := [2]float64{9.00, -84.20}  // 4 km from the nearest road
	farDrop := [2]float64{9.01, -84.20} // likewise uncovered
	nearPin := [2]float64{9.93, -84.08}
	nearDrop := [2]float64{9.940, -84.070}

	t.Setenv("ROUTING_SNAP_RADIUS_M", "1000")
	repo := newRadiusRepo(registry(), config.Load(), map[pinKey]float64{
		pinKey(farPin):   4000,
		pinKey(farDrop):  4200,
		pinKey(nearPin):  120,
		pinKey(nearDrop): 180,
	})
	repo.routes = routesInEveryRegion(registry(), []repository.RouteResult{
		{NodeID: 1, NodeSeq: 0, Lat: 9.93, Lng: -84.08},
		{NodeID: 2, NodeSeq: 1, Lat: 9.940, Lng: -84.070, AggCost: 1500},
	})
	svc := NewNavigationService(repo)

	far, err := svc.GetRoute(farPin[0], farPin[1], farDrop[0], farDrop[1])
	if err != nil {
		t.Fatalf("no coverage must not be an error: %v", err)
	}
	if !far.IsEstimate {
		t.Errorf("a pin 4000 m out under a 1000 m radius must be an estimate, got %+v", far)
	}

	near, err := svc.GetRoute(nearPin[0], nearPin[1], nearDrop[0], nearDrop[1])
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if near.IsEstimate || near.DistanceMeters != 1500 {
		t.Errorf("got %+v, want a real 1500 m route for the in-radius pin", near)
	}
}

// ---- additive elevation totals (api_plans [elevation] stage 01) ----------

// routeInfo copies the last row's raw ascent/descent and the per-response
// elevation flag, exactly as it copies AggCost.
func TestRouteInfoCarriesElevationTotals(t *testing.T) {
	nodes := []repository.RouteResult{
		{NodeID: 1, NodeSeq: 0, Lat: 9.9400, Lng: -84.0800},
		{NodeID: 2, NodeSeq: 1, Lat: 9.9433, Lng: -84.0733, AggCost: 5000,
			AscentM: 412, DescentM: 388, ElevationAware: true},
	}
	got, err := routeInfo(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1], nodes)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.AscentM != 412 || got.DescentM != 388 || !got.ElevationAware {
		t.Errorf("elevation totals = %v/%v aware=%v, want 412/388 true",
			got.AscentM, got.DescentM, got.ElevationAware)
	}
}

// A straight-line estimate never claims elevation awareness: 0/false keeps the
// response shape stable when no region covered the pins.
func TestEstimateRouteElevationTotalsAreZero(t *testing.T) {
	got := estimateRoute(sjPin[0], sjPin[1], sjDropPin[0], sjDropPin[1])
	if got.AscentM != 0 || got.DescentM != 0 || got.ElevationAware {
		t.Errorf("estimate elevation totals = %v/%v aware=%v, want 0/0 false",
			got.AscentM, got.DescentM, got.ElevationAware)
	}
}
