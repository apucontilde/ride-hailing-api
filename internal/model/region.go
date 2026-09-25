package model

// RegionRef is one row of the routing regions registry (plan 04): a named,
// bounded slice of the world whose road network this API can route on. It is
// the position -> region key the resolver loads (api_plans/05).
//
// The type lives in `model` (not in `service`) so `repository` can return it
// without importing `service` — the Go interfaces that consume it
// (service.RegionSource / service.RegionRouter) are matched structurally, so
// the import graph stays acyclic: model <- repository <- service.
type RegionRef struct {
	// RegionID is the registry id, e.g. "cr-sj". Also the routing tables'
	// region_id value, and the parameter a region-scoped query binds.
	RegionID string
	// Level is the registry granularity: country, state or city.
	Level string
	// Parent is the parent region id ("" for a root region). Retained as the
	// deferred intercity seam (plan 07); unused by the resolver, which
	// deliberately returns exactly one region.
	Parent string
	// Default marks the registry's fallback row (default_region = TRUE), used
	// when no candidate region covers a pin.
	Default bool
	// BBox is [lonMin, latMin, lonMax, latMax] — the region's admin box, used
	// to order candidates by nearness. It is NOT a coverage test: resolution
	// is snap-first, so a pin slightly outside the box still routes.
	BBox [4]float64
	// Datasource is "" for the local database, else a routing_datasources id
	// whose pool owns this region's rows (plan 06). The local pool is the only
	// one this plan resolves against.
	Datasource string
}

// SnapResult is the outcome of snapping a pin to the nearest road vertex
// inside one region. ok=false means "not covered": no vertex, or the nearest
// one is farther than the configured snap radius.
type SnapResult struct {
	// VertexID is the road vertex the pin snapped to.
	VertexID int64
	// DistanceM is the geodesic distance from pin to vertex, in meters.
	DistanceM float64
	// Lat/Lng are the snapped vertex coordinates.
	Lat float64
	Lng float64
}
