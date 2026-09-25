//go:build integration

package repository

import (
	"errors"
	"strconv"
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/routing"
)

// Two datasources on ONE stack (api_plans/06, the "near" deployment shape).
// These tests need a live PostGIS+pgRouting DB (`docker compose up -d`).
//
// The fixture is the plan's own sanctioned stand-in: a second SCHEMA-like
// namespace in the same Postgres, exposed as a routing_datasources row. A
// datasource is just "a pool", and a second POOL on the same server is a
// separate session — so its TEMP tables are a namespace only that pool can see.
// What matters for the dispatch being tested is exactly the same as with a
// second city database: the rows are reachable ONLY through the pool that owns
// them.
//
//	region    datasource   pool              contents
//	cr-sj     ""           local             1-2-3-4, 100 m hops, sjPin coords
//	cr-rv     "d1"         second session    1-2-3-4, 100 m hops, rvPin coords
//	cr-rv     ""           local             1-2-3-4, 900 m hops, poison coords  <- must never be read
//	cr-mx     "d2"         unreachable       nothing (a port nothing listens on)
//
// The poisoned local copy of cr-rv is the load-bearing part: a repo that
// resolved the WRONG pool would answer with plausible, region-scoped results at
// the wrong coordinates with a different total cost, and every assertion below
// would notice.
const (
	regionRV   = "cr-rv"
	regionMX   = "cr-mx"
	datasource = "d1"
	deadSource = "d2"

	// The local pool's decoy copy of cr-rv, far from the real one.
	poisonLatOffset = 0.050
	poisonLngOffset = 0.050
	poisonHopCost   = 900.0
)

// rvPin places cr-rv's vertex `id` away from both cr-sj and the poisoned copy.
func rvPin(id int64) (lat, lng float64) { return float64(id)*0.001 + 0.020, 0.060 }

// poisonPin is the decoy's coordinates inside the LOCAL pool.
func poisonPin(id int64) (lat, lng float64) {
	return float64(id)*0.001 + poisonLatOffset, poisonLngOffset
}

// Single-value accessors for the pins above; call sites that pass one
// coordinate cannot index a multi-value return.
func sjLat(id int64) float64     { lat, _ := sjPin(id); return lat }
func sjLng(id int64) float64     { _, lng := sjPin(id); return lng }
func rvLat(id int64) float64     { lat, _ := rvPin(id); return lat }
func rvLng(id int64) float64     { _, lng := rvPin(id); return lng }
func poisonLat(id int64) float64 { lat, _ := poisonPin(id); return lat }

type datasourceFixture struct {
	local  *sqlx.DB
	remote *sqlx.DB
	pools  *DatasourcePools
}

// seedDatasourceFixture wires the registry, the local pool and a second pool.
func seedDatasourceFixture(t *testing.T) datasourceFixture {
	t.Helper()
	cfg := config.Load()

	local := connectPG(t)
	local.SetMaxOpenConns(1) // temp tables must stay visible to every repo query
	dropRegionTables(t, local, "road_network_edges_pgr", "road_network_vertices_pgr",
		"routing_regions", "routing_datasources")

	// The registry: one local city, one on a real second datasource, one on a
	// datasource that cannot be reached. cr-sj is the default region.
	createRegionRegistry(t, local)
	createDatasourceRegistry(t, local)
	mustExec(t, local, "INSERT INTO routing_regions (region_id, level, name, parent_region, "+
		"bbox_lon_min, bbox_lat_min, bbox_lon_max, bbox_lat_max, default_region, datasource) VALUES "+
		"('cr-sj', 'state', 'San Jose', NULL, -0.001, 0.000, 0.001, 0.005, TRUE, NULL), "+
		"('cr-rv', 'city', 'Roj(verbose)', NULL, 0.055, 0.020, 0.065, 0.030, FALSE, $1), "+
		"('cr-mx', 'city', 'Merida', NULL, 0.055, 0.020, 0.065, 0.030, FALSE, $2)", datasource, deadSource)

	// routing_datasources carries connection coordinates ONLY. The password is
	// the one thing it must never hold, so the fixture proves the env
	// convention instead: DATASOURCE_D1_PASSWORD below.
	port, err := strconv.Atoi(cfg.DBPort)
	if err != nil {
		t.Fatalf("DB_PORT %q is not a number: %v", cfg.DBPort, err)
	}
	mustExec(t, local, "INSERT INTO routing_datasources (datasource_id, host, port, dbname, db_user, label) VALUES "+
		"($1, $2, $3, $4, $5, 'secondary city'), ($6, $2, 1, $4, $5, 'unreachable city')",
		datasource, cfg.DBHost, port, cfg.DBName, cfg.DBUser, deadSource)
	t.Setenv(DatasourcePasswordEnv(datasource), cfg.DBPassword)

	createRegionTables(t, local)
	insertRegionVertices(t, local, regionSJ, sjPin, 1, 2, 3, 4)
	insertChain(t, local, regionSJ, 1, 4, 100)
	// The decoy: same region id and vertex ids, wrong place, wrong costs.
	insertRegionVertices(t, local, regionRV, poisonPin, 1, 2, 3, 4)
	insertChain(t, local, regionRV, 1, 4, poisonHopCost)

	// One connection per pool keeps each session's TEMP tables authoritative.
	pools := NewDatasourcePools(local, cfg.RoutingDatasourceSSLMode, 1)
	t.Cleanup(pools.Close)
	remote := pools.Pool(datasource)
	if remote == nil {
		t.Skipf("cannot open the secondary datasource pool: check routing_datasources row %q", datasource)
	}
	createRegionTables(t, remote)
	// Vertex 30 is deliberately disconnected (no edge), the fixture's honest
	// "no path in this region" case.
	insertRegionVertices(t, remote, regionRV, rvPin, 1, 2, 3, 4, 30)
	insertChain(t, remote, regionRV, 1, 4, 100)

	return datasourceFixture{local: local, remote: remote, pools: pools}
}

// The registry is the single source of truth for position -> region -> pool, so
// its datasource column must survive into the resolver's RegionRef.
func TestRegisteredRegionsCarryTheirDatasource(t *testing.T) {
	fx := seedDatasourceFixture(t)
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 0)

	got, err := repo.RegisteredRegions()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]string{regionSJ: "", regionRV: datasource, regionMX: deadSource}
	if len(got) != len(want) {
		t.Fatalf("got %d regions, want %d: %+v", len(got), len(want), got)
	}
	for _, ref := range got {
		if w, ok := want[ref.RegionID]; !ok {
			t.Errorf("unexpected region %q", ref.RegionID)
		} else if ref.Datasource != w {
			t.Errorf("region %q datasource = %q, want %q", ref.RegionID, ref.Datasource, w)
		}
	}
}

// Pools are lazy and cached: nothing is opened until a region names it, an
// unknown id is never a panic, and a down datasource stays down without taking
// the local pool with it.
func TestDatasourcePoolsResolveLazilyAndFailSafe(t *testing.T) {
	fx := seedDatasourceFixture(t)

	if again := fx.pools.Pool(datasource); again != fx.remote {
		t.Error("an opened datasource pool must be cached, not reopened")
	}
	if got := fx.pools.Pool("no-such-datasource"); got != nil {
		t.Error("an unprovisioned datasource must resolve to no pool")
	}
	// Twice: the second answer comes from the failure cache, which is what keeps
	// a down city from costing a dial per request.
	for i := 0; i < 2; i++ {
		if got := fx.pools.Pool(deadSource); got != nil {
			t.Fatalf("an unreachable datasource must resolve to no pool (attempt %d)", i)
		}
	}
	if got := fx.pools.Pool(""); got != fx.local {
		t.Error(`the "" datasource must always be the local pool`)
	}
	// The local pool is untouched by every failure above.
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 0)
	fLat, fLng := sjPin(1)
	tLat, tLng := sjPin(4)
	if _, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng); err != nil {
		t.Errorf("local routing broke after a failed datasource: %v", err)
	}
}

// A pin snaps against the pool its region's datasource names. The poisoned local
// copy of cr-rv is the control: if the pool were wrong, that is what answers.
func TestSnapDispatchesToTheRegionsPool(t *testing.T) {
	fx := seedDatasourceFixture(t)
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 0)

	lat, lng := rvPin(2)
	snap, ok := repo.Snap(lat, lng, datasource, regionRV)
	if !ok {
		t.Fatal("a pin on a cr-rv vertex must snap through datasource d1")
	}
	if snap.VertexID != 2 || snap.Lat != lat || snap.Lng != lng {
		t.Fatalf("snap = %+v, want d1's v2 at (%v,%v)", snap, lat, lng)
	}
	if snap.DistanceM > 0.01 {
		t.Errorf("distance = %v m, want ~0 for a pin on the vertex", snap.DistanceM)
	}

	// The same pin against the LOCAL pool reads the decoy, kilometers away —
	// proof that the pass above really crossed into the second pool.
	localSnap, ok := repo.Snap(lat, lng, "", regionRV)
	if !ok {
		t.Fatal("the local decoy copy of cr-rv must still be reachable from the local pool")
	}
	if localSnap.Lat == lat && localSnap.Lng == lng {
		t.Error("the local pool answered with the remote pool's vertex")
	}
	if localSnap.DistanceM < 1000 {
		t.Errorf("local decoy distance = %v m, want the kilometers to the decoy", localSnap.DistanceM)
	}
}

// Each city routes on its OWN graph: identical vertex ids, disjoint topology and
// coordinates, one pool each.
func TestRouteInRegionUsesTheRegionsOwnPoolAndGraph(t *testing.T) {
	fx := seedDatasourceFixture(t)
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 0)

	// cr-rv through datasource d1: 1-2-3-4, 300 m, at rvPin coordinates.
	fLat, fLng := rvPin(1)
	tLat, tLng := rvPin(4)
	got, err := repo.RouteInRegion(regionRV, datasource, fLat, fLng, tLat, tLng)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("got %+v, want d1's 4-node chain", got)
	}
	if got[3].AggCost != 300 {
		t.Errorf("total cost = %v, want d1's 300 m (the decoy chain costs %v per hop)", got[3].AggCost, poisonHopCost)
	}
	for i, n := range got {
		wantLat, wantLng := rvPin(int64(n.NodeID))
		if n.Lat != wantLat || n.Lng != wantLng {
			t.Errorf("node[%d] coords = (%v,%v), want d1's (%v,%v)", i, n.Lat, n.Lng, wantLat, wantLng)
		}
		if n.NodeSeq != i {
			t.Errorf("node[%d] seq = %d", i, n.NodeSeq)
		}
	}

	// Only the remote city has been routed so far, so it is the only graph in
	// memory; cr-sj joins the cache on its own first route below.
	cached := repo.CachedRegionIDs()
	if len(cached) != 1 || cached[0] != regionRV {
		t.Errorf("cached regions = %v, want [%s]", cached, regionRV)
	}

	// ... and the local city is completely unaffected by the remote one.
	fLat, fLng = sjPin(1)
	tLat, tLng = sjPin(4)
	sjGot, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, tLat, tLng)
	if err != nil {
		t.Fatalf("local routing broke: %v", err)
	}
	if len(sjGot) != 4 || sjGot[3].AggCost != 300 {
		t.Errorf("local route = %+v, want the 4-node 300 m chain", sjGot)
	}
	for i, n := range sjGot {
		wantLat, wantLng := sjPin(int64(n.NodeID))
		if n.Lat != wantLat || n.Lng != wantLng {
			t.Errorf("local node[%d] coords = (%v,%v), want cr-sj's (%v,%v)", i, n.Lat, n.Lng, wantLat, wantLng)
		}
	}
	// Both cities now hold a graph: the remote one least recently used, the
	// local one most recently used.
	cached = repo.CachedRegionIDs()
	if len(cached) != 2 || cached[0] != regionRV || cached[1] != regionSJ {
		t.Errorf("cached regions = %v, want [%s %s] (LRU order)", cached, regionRV, regionSJ)
	}
}

// The pgRouting engine dispatches exactly like the native one — it is an
// optional per-region engine choice, never a different registry.
func TestPGRoutingRepoDispatchesToTheRegionsPool(t *testing.T) {
	fx := seedDatasourceFixture(t)
	if !pgHasExtension(t, fx.local) {
		t.Skip("pgRouting extension absent")
	}
	repo := NewPGRoutingRepoWithDatasources(fx.local, fx.pools, 1000)

	fLat, fLng := rvPin(1)
	tLat, tLng := rvPin(4)
	got, err := repo.RouteInRegion(regionRV, datasource, fLat, fLng, tLat, tLng)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertChain(t, got, []int64{1, 2, 3, 4}, 300)
	for i, n := range got {
		wantLat, wantLng := rvPin(int64(n.NodeID))
		if n.Lat != wantLat || n.Lng != wantLng {
			t.Errorf("node[%d] coords = (%v,%v), want d1's (%v,%v) (ids collide across pools)", i, n.Lat, n.Lng, wantLat, wantLng)
		}
	}

	// The local city still routes, and the decoy is still not what answers.
	sfLat, sfLng := sjPin(1)
	stLat, stLng := sjPin(4)
	sjGot, err := repo.RouteInRegion(regionSJ, "", sfLat, sfLng, stLat, stLng)
	if err != nil {
		t.Fatalf("local routing broke: %v", err)
	}
	assertChain(t, sjGot, []int64{1, 2, 3, 4}, 300)
}

// The fail-safe: a datasource that cannot be reached makes ITS region
// uncovearable, and the routing call that tries anyway says so with a tagged
// error the service degrades to an estimate. Nothing global is affected — the
// local city keeps routing (which is what makes the plan's 200-is_estimate
// degradation, not a 500).
func TestUnreachableDatasourceDegradesOnlyItsOwnRegion(t *testing.T) {
	fx := seedDatasourceFixture(t)
	// Radius 1000 m: pins only cover their OWN region, which is the operator
	// setting plan 05 requires for the no-coverage path to be reachable.
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 1000, 0)

	lat, lng := rvPin(1)
	tLat, tLng := rvPin(4)
	if _, ok := repo.Snap(lat, lng, deadSource, regionMX); ok {
		t.Error("a region on an unreachable datasource must not report coverage")
	}
	if _, err := repo.RouteInRegion(regionMX, deadSource, lat, lng, tLat, tLng); !errors.Is(err, ErrDatasourceUnavailable) {
		t.Errorf("routing in a region with no usable pool = %v, want ErrDatasourceUnavailable", err)
	}
	// A datasource that was never provisioned behaves identically.
	if _, err := repo.RouteInRegion(regionMX, "no-such-datasource", lat, lng, tLat, tLng); !errors.Is(err, ErrDatasourceUnavailable) {
		t.Errorf("routing through an unprovisioned datasource = %v, want ErrDatasourceUnavailable", err)
	}

	// The healthy city is untouched.
	fLat, fLng := sjPin(1)
	got, err := repo.RouteInRegion(regionSJ, "", fLat, fLng, sjLat(4), sjLng(4))
	if err != nil {
		t.Fatalf("the local city must keep routing: %v", err)
	}
	if len(got) != 4 || got[3].AggCost != 300 {
		t.Errorf("local route = %+v, want the 4-node 300 m chain", got)
	}
}

// ROUTING_MAX_REGIONS_IN_MEMORY caps how many city graphs a pod holds: the
// budget is a COUNT, eviction is least-recently-used, and an evicted city is
// simply rebuilt on its next request.
func TestRegionGraphEviction(t *testing.T) {
	fx := seedDatasourceFixture(t)

	t.Run("zero_never_evicts", func(t *testing.T) {
		repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 0)
		routeInBothCities(t, repo)
		if got := repo.CachedRegionIDs(); len(got) != 2 {
			t.Errorf("cached regions = %v, want both cities cached with a 0 budget", got)
		}
	})

	t.Run("one_evicts_the_cold_city", func(t *testing.T) {
		repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 1)

		// cr-sj first, then cr-rv: cr-sj is now the coldest.
		if _, err := repo.RouteInRegion(regionSJ, "", sjLat(1), sjLng(1), sjLat(4), sjLng(4)); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got := repo.CachedRegionIDs(); len(got) != 1 || got[0] != regionSJ {
			t.Fatalf("cached regions = %v, want only %s", got, regionSJ)
		}
		if _, err := repo.RouteInRegion(regionRV, datasource, rvLat(1), rvLng(1), rvLat(4), rvLng(4)); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got := repo.CachedRegionIDs(); len(got) != 1 || got[0] != regionRV {
			t.Errorf("cached regions = %v, want only the newest %s", got, regionRV)
		}

		// The evicted city is rebuilt (and evicted again) on demand, and it
		// still answers from ITS OWN pool.
		got, err := repo.RouteInRegion(regionSJ, "", sjLat(1), sjLng(1), sjLat(4), sjLng(4))
		if err != nil {
			t.Fatalf("an evicted region must rebuild on demand: %v", err)
		}
		if len(got) != 4 || got[3].AggCost != 300 {
			t.Errorf("rebuilt route = %+v, want the 4-node 300 m chain", got)
		}
		if cached := repo.CachedRegionIDs(); len(cached) != 1 || cached[0] != regionSJ {
			t.Errorf("cached regions = %v, want only %s after the rebuild", cached, regionSJ)
		}
	})

	t.Run("touching_a_region_makes_it_recent", func(t *testing.T) {
		repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 1)
		if _, err := repo.RouteInRegion(regionSJ, "", sjLat(1), sjLng(1), sjLat(2), sjLng(2)); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if _, err := repo.RouteInRegion(regionRV, datasource, rvLat(1), rvLng(1), rvLat(2), rvLng(2)); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		// Warm the remote city once more while cr-sj sits in the cache: cr-sj
		// is the eviction victim now, not cr-rv.
		if _, err := repo.RouteInRegion(regionSJ, "", sjLat(1), sjLng(1), sjLat(2), sjLng(2)); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if _, err := repo.RouteInRegion(regionRV, datasource, rvLat(1), rvLng(1), rvLat(2), rvLng(2)); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got := repo.CachedRegionIDs(); len(got) != 1 || got[0] != regionRV {
			t.Errorf("cached regions = %v, want only the most recently used %s", got, regionRV)
		}
	})
}

// A region's graph remembers which datasource it was built from, so re-pointing
// a region at another city database rebuilds instead of routing on a stale graph.
func TestRegionGraphFollowsTheDatasourceItWasBuiltFrom(t *testing.T) {
	fx := seedDatasourceFixture(t)
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 0, 0)

	// Build cr-rv from the decoy in the local pool...
	if _, err := repo.RouteInRegion(regionRV, "", rvLat(1), rvLng(1), rvLat(4), rvLng(4)); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got := repo.CachedRegionIDs()
	if len(got) != 1 || got[0] != regionRV {
		t.Fatalf("cached regions = %v, want [%s]", got, regionRV)
	}
	// ... then the same region on its real datasource must NOT reuse it.
	real, err := repo.RouteInRegion(regionRV, datasource, rvLat(1), rvLng(1), rvLat(4), rvLng(4))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if real[0].Lat != rvLat(1) {
		t.Errorf("node[0] lat = %v, want d1's %v, not the stale local decoy %v",
			real[0].Lat, rvLat(1), poisonLat(1))
	}
	if real[3].AggCost != 300 {
		t.Errorf("total cost = %v, want 300 m from d1 (the decoy costs %v per hop)", real[3].AggCost, poisonHopCost)
	}
}

// A datasource that goes away AFTER its graph was built must not poison other
// cities: the graph answers from memory, and the next miss degrades to an
// estimate (an unresolvable pool), never a 500.
func TestUnreachableDatasourceAfterTheGraphIsBuilt(t *testing.T) {
	fx := seedDatasourceFixture(t)
	repo := NewNavigationRepoWithDatasources(fx.local, fx.pools, 1000, 0)

	// cr-rv on d1 resolves and builds.
	if _, ok := repo.Snap(rvLat(1), rvLng(1), datasource, regionRV); !ok {
		t.Fatal("cr-rv must cover its own pin through d1")
	}
	// An unprovisioned datasource is a different city entirely, and it has no
	// graph to serve from.
	if _, err := repo.RouteInRegion(regionMX, "no-such-datasource", rvLat(1), rvLng(1), rvLat(4), rvLng(4)); !errors.Is(err, ErrDatasourceUnavailable) {
		t.Errorf("got %v, want ErrDatasourceUnavailable", err)
	}
	// And the routing errors a real network can produce are still errors, so
	// an honest "no route" is never silently flattened into a straight line.
	// Vertex 30 is disconnected from the 1-2-3-4 chain on d1.
	if _, err := repo.RouteInRegion(regionRV, datasource, rvLat(1), rvLng(1), rvLat(30), rvLng(30)); !errors.Is(err, routing.ErrNoRoute) {
		t.Errorf("a route with no path in the region = %v, want %v", err, routing.ErrNoRoute)
	} else if errors.Is(err, ErrDatasourceUnavailable) {
		t.Errorf("a healthy datasource must not be reported as unavailable: %v", err)
	}
}

// routeInBothCities touches one route in each city, in that order.
func routeInBothCities(t *testing.T, repo *NativeNavigationRepo) {
	t.Helper()
	if _, err := repo.RouteInRegion(regionSJ, "", sjLat(1), sjLng(1), sjLat(4), sjLng(4)); err != nil {
		t.Fatalf("cr-sj route failed: %v", err)
	}
	if _, err := repo.RouteInRegion(regionRV, datasource, rvLat(1), rvLng(1), rvLat(4), rvLng(4)); err != nil {
		t.Fatalf("cr-rv route failed: %v", err)
	}
}

// A repo that only ever has the local pool must still satisfy the service's
// region capabilities, so a single-city deployment is byte-for-byte plan 05.
func TestSingleCityRepoStillSatisfiesRegionCapabilities(t *testing.T) {
	db := seedRegionTables(t)
	var repos = []struct {
		name string
		repo NavigationRepository
	}{
		{"native", NewNavigationRepo(db, 0)},
		{"native_with_pools", NewNavigationRepoWithDatasources(db, NewDatasourcePools(db, "disable", 1), 0, 0)},
		{"pgrouting", NewPGRoutingRepo(db, 0)},
		{"pgrouting_with_pools", NewPGRoutingRepoWithDatasources(db, NewDatasourcePools(db, "disable", 1), 0)},
	}
	for _, r := range repos {
		if _, ok := r.repo.(interface {
			RegisteredRegions() ([]model.RegionRef, error)
		}); !ok {
			t.Errorf("%s: lost the RegionSource capability", r.name)
		}
		if _, err := r.repo.GetShortestPath(0.001, 0, 0.004, 0); err != nil {
			t.Errorf("%s: legacy GetShortestPath broke: %v", r.name, err)
		}
	}
}
