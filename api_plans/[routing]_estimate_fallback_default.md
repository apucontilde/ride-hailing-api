---
tag: routing
depends_on: []
status: open
---

# Activate the no-coverage estimate by default (finite snap radius)

Bug #2: `ROUTING_SNAP_RADIUS_M` defaults to `0`, which means **always snap** — every pin, however
far outside an imported region, snaps to the nearest road. That makes the honest
`is_estimate` straight-line answer (`estimateRoute`) unreachable in the default configuration, so
a pin in the middle of nowhere gets a confident, road-less "route" instead of a labelled estimate.

**Read first:**

- `internal/config/config.go:119` — `RoutingSnapRadiusM: getFloat("ROUTING_SNAP_RADIUS_M", 0)`.
- `internal/repository/navigation_repo.go:146-163` — `snapInRegion`; `:154-156` is the
  `radiusM > 0 && row.DistanceM > radiusM` coverage check (0 disables it).
- `internal/service/navigation.go:104-157,181-210` — `GetRoute`/`resolveRegion`: snap-first over
  candidates ordered by bbox-centre distance, then the default region; `:118-120,130-132` turn a
  nil region into `estimateRoute`.
- `internal/service/navigation.go:289-305` — `estimateRoute` (200 + straight line + `is_estimate`).
- `scripts/import-road-network.sh:99` — the default San José region bbox `-84.50,9.00,-83.50,10.20`
  (~110 km across), the scale the default radius must be sensible against.
- `tests/navigation_test.go`, `internal/service/regions_test.go` — existing coverage seams.

## Gap (verified)

`estimateRoute` is dead by default: with radius `0`, `snapInRegion` never rejects a candidate, so
`resolveRegion` always returns a region and the estimate is only reachable when the region
registry is empty. The feature exists and is tested in isolation but cannot fire in production
config. `.env.example`/`AGENTS.md` document `0 = always snap` as if that were the shipped default.

## Work

1. **Default radius decided: `50000` m** (matches `PLACES_MAX_RADIUS_M`; a pin >50 km from any
   road answers an estimate instead of snapping to a far-away vertex). Validate against the
   default San José bbox (`scripts/import-road-network.sh:99`, ~110 km across): a pin beyond the
   radius and outside every bbox must answer `is_estimate:true`; a pin just outside a bbox but
   near boundary roads must still route (snap-first can still reach a neighbouring in-range
   region).
2. Change `getFloat("ROUTING_SNAP_RADIUS_M", 0)` to `50000`. Keep `0` = "always snap" as an
   explicit, documented opt-in so operators can override either way.
3. Reconcile `.env.example` and the routing section of `AGENTS.md` with the new default.
4. Tests:
   - a service/repo test (fake `RegionSource`, or an integration test) proving a beyond-radius pin
     → no region → `estimateRoute` (`is_estimate:true`, straight polyline, haversine distance);
   - a within-radius pin still routes;
   - explicit `ROUTING_SNAP_RADIUS_M=0` still snaps unconditionally.

## Tests

- Service/unit test for the beyond-radius → estimate path and the within-radius → route path; a
  config test pinning the new default when unset.

## Accept

- With the default config, a pin far outside every region answers 200 `is_estimate:true`, not a
  bogus snapped route; a pin inside routes as before; `0` still means always-snap.
- Bug #2 is closed with the chosen default recorded.

## Verify

```bash
go test -count=1 ./internal/service/ ./internal/config/ ./internal/repository/
make test && make lint
make test-integration   # DB-backed region/snap coverage, needs docker compose
```
