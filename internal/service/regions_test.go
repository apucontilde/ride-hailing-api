package service

import (
	"errors"
	"math"
	"testing"

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
	routeIDs  []string
}

func newRouterRepo(regions []model.RegionRef, covered coverage) *regionRouterFake {
	return &regionRouterFake{regionRepoFake: *newRegionRepo(regions, covered)}
}

func (f *regionRouterFake) RouteInRegion(regionID string, fromLat, fromLng, toLat, toLng float64) ([]repository.RouteResult, error) {
	f.routeIDs = append(f.routeIDs, regionID)
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
	pacificPin = [2]float64{5.00, -90.00}     // no region anywhere near
)

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
	if len(repo.routeIDs) != 1 || repo.routeIDs[0] != "cr-sj" {
		t.Fatalf("RouteInRegion calls = %v, want one call in cr-sj", repo.routeIDs)
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
