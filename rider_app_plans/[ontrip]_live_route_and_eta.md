---
tag: ontrip
depends_on: ["[tracking]_ride_detail_receipt_rating.md"]
status: open
---

# Rider live road route + ETA

Adds the two missing pieces for the active-trip screen: a **road-following route** from rider to
driver (today it draws a straight line) and **ETA display**.

> **Do NOT steal LC-4.** The driver-marker item (typed `RideState.driver` / `driverLocation`
> replacing invented `driver_lat`/`driver_lng`/`driver_name` keys, plus the polling fallback)
> belongs to `[tracking]` LC-4 (`:43-50`). This plan **depends_on** that work and only adds the
> two pieces LC-4 does not cover.

**Read first:**

- `rider_app/lib/features/home/presentation/active_ride_screen.dart` (rider→driver straight line
  at `:135-144`; rider marker at `:145-153`)
- `rider_app/lib/features/home/data/ride_status_provider.dart` (typed `driverLocation`,
  `etaSeconds` at `:13-15,98-108`)
- `rider_app/lib/features/home/data/home_provider.dart` (`navigationRouteProvider` already
  exists, `:77-135`)
- `driver_app/lib/features/trip/providers/trip_notifier.dart:234-241` (proves the generic
  `/api/v1/navigation/route` endpoint is already reused for a live route)

## Gap (verified)

1. **Note 8 — live road route.** `active_ride_screen.dart:135-144` draws a straight
   rider→driver `Polyline`; there is no road route. The `/api/v1/navigation/route` endpoint is
   generic and already consumed by the driver trip screen, so the rider can reuse
   `navigationRouteProvider` (or a trip-scoped variant) to render the on-road path between the
   rider's position and the driver's position.
2. **Note 9 — ETA (this plan's slice).** `ride_status_provider.dart:13-15,98-108` already has
   typed `driverLocation` and `etaSeconds`; there is **no ETA display**. Add ETA rendering on the
   active-trip screen. (The driver-marker swap is LC-4's job, not here.)

## Work

1. Fetch and render the road route from rider → driver using `navigationRouteProvider` (or a
   trip-scoped provider keyed on rider/driver coords), replacing the straight
   `_riderPosition → driverPosition` polyline with the road-following polyline.
2. Handle the estimator/no-coverage case gracefully (the route endpoint may return
   `is_estimate: true` with a straight line) — render an explicit "estimated route" state rather
   than a silent straight line.
3. Drive ETA from `RideState.etaSeconds` (treat the backend `300` fallback as "unknown" as
   `[tracking]` already documents); display it on the trip screen and update it as state changes.

## Tests

- `active_ride_screen_test.dart`: when rider+driver coords are non-null, the road polyline is
  rendered from `navigationRouteProvider` output (not a straight synthesized line); estimated
  route shows a distinct state; ETA text reflects `etaSeconds`.

## Accept

- Active trip renders an actual road route (or an explicit "estimated" state), not a confident
  straight line.
- ETA is visible and driven by typed `etaSeconds`.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```