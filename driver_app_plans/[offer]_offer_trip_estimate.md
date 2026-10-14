---
tag: offer
depends_on: ["landed [offer] offer sheet + [fare] money formatting (driver_app_plans/STATUS.md)"]
status: open
---

# [offer] Offer popup shows destination, distance and time estimates

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification).

## Goal

The ride-offer popup must show the trip destination (address/pin) plus the distance and estimated
time of the trip, so the driver can decide whether to accept before the 30 s window closes.

## Current state (verified)

- `OfferSheet._loadRide` fetches the ride via `ridesRepository.fetchRide`
  (`driver_app/lib/features/rides/presentation/offer_sheet.dart:51-71`), i.e.
  `GET /api/v1/driver/rides/:id` → `{ride, stops}` (`rides_repository.dart:91-98`; handler
  `internal/handler/ride.go:303-313`).
- The sheet renders Pickup / Dropoff / Fare (`offer_sheet.dart:167-180`). The **destination is already
  shown**; distance and time are not.
- The shared `Ride` model carries no distance/duration estimate
  (`shared/lib/src/models/ride.dart`). The API ride has `actual_distance_m` / `actual_duration_s`, but
  those are **actuals** — null until completion (`internal/model/ride.go:49-55`) — so they cannot
  populate an offer.
- The honest source already exists and is driver-usable: `GET /api/v1/navigation/route` returns
  `total_distance_m`, `total_duration_s` and `is_estimate`
  (`driver_app/lib/core/api/endpoints.dart:43`; used by `trip_notifier.dart:239-269`).

## Design (app-only)

- After the ride loads, request `GET /navigation/route` from **pickup → dropoff** (the booked trip) and
  render two rows:
  - `Distance` → `x.x km`
  - `Est. time` → `about n min`
- Reuse the trip layer's formatting (`driver_app/lib/features/trip/presentation/trip_screen.dart:667-672`
  `_legSummary`) by extracting a small shared helper, or duplicate the two-line formatter locally.
- Honesty rule (matches the domain invariant): prefix **"Estimated"** when `is_estimate: true`; on
  failure render a placeholder (`—` / "Unavailable") and **never fabricate** a number.
- Add a repository method (e.g. `RidesRepository.routeEstimate({fromLat, fromLng, toLat, toLng})`
  returning a small `RouteEstimate {distanceM, durationS, isEstimate}`) instead of calling Dio from
  the widget. Keep the existing `fetchRide`.
- No API change: the endpoint exists and is Bearer-authenticated for drivers.
- Multi-stop note: pickup→dropoff understates a waypoint trip. Once
  `[ontrip]_itinerary_next_stop.md` lands its `RideStop` parsing, this can route the full itinerary
  (`pickup → stops → dropoff`). Not required for this plan; see Open inputs.

## Tests to add/change

- `driver_app/test/features/rides/presentation/offer_sheet_test.dart`: stub
  `GET /driver/rides/:id` + `GET /navigation/route`; assert `Distance` / `Est. time` render (e.g.
  `4.2 km`, `about 7 min`); assert an `is_estimate` route prefixes "Estimated"; assert a failed route
  shows the placeholder and never a number.
- `driver_app/test/features/rides/data/rides_repository_test.dart`: `routeEstimate` pins the query
  params and parses `total_distance_m` / `total_duration_s` / `is_estimate`.

## Cross-domain

- None. `GET /navigation/route` already exists. **If product wants a server-side booked estimate on
  the ride payload, report it to the cross-app-planner — do not edit `api_plans/`.**

## Open inputs

- Should the estimate be the trip (pickup→dropoff) only, or also the driver→pickup leg? Recommended:
  the trip leg (it is what the fare and duration describe); the driver→pickup leg is an optional
  extra row. Resolve with product.
- Whether to route the full itinerary for waypoint rides — recommended once D-5's stops land.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```
