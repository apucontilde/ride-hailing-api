---
tag: ontrip
depends_on: []
status: open
---

# [ontrip] Active-trip itinerary: stop markers + change-destination confirmation

> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> Verification). **Independent** — every prerequisite is landed capability named in
> `rider_app_plans/STATUS.md`, not an open plan, so this file is **unnumbered**.
>
> **Scope:** two related rider requests, combined because they share one new data source and the
> same screen/state file (`trip_route_provider.dart` + `active_ride_screen.dart`):
> - **R-1 — change-destination confirmation with a fresh estimate.** After the rider picks a new
>   destination mid-trip, show the NEW fare/time estimate in a confirmation dialog; only `PUT` the
>   change after the rider confirms. A cancelled/unconfirmed dialog must leave the ride untouched.
> - **R-3 — mark the itinerary stops before the destination.** The active-ride map draws only the
>   rider and the driver; it should mark the ordered intermediate stops (and the destination) the
>   way the Home map already does.
>
> **Tag call: `ontrip`, not `multi`/`map`.** Both deliverables are *active-trip itinerary surfaces*,
> and `[ontrip]` already owns the active trip’s live route and ETA honesty in the same file
> (`active_ride_screen.dart`, `trip_route_provider.dart`). The landing change-destination mutation
> stays under `[multi]`; the Home stop markers stay under `[map]`. `[ontrip]_driver_arrival_eta.md`
> is a **sibling** plan (same tag, no chain, `depends_on: []`) — this plan does not touch status
> labels or the ETA row.
>
> **Combined-plan justification:** splitting R-1 and R-3 would force an artificial cross-tag
> `depends_on` chain over a ~10-line shared foundation (exposing the ordered itinerary from the
> existing `GET /rides/:id` read). One plan, two clearly separated workstreams.

## What already exists

- **The change-destination mutation is landed.** `_changeDestination` reads the picked `Place` and
  immediately `PUT`s it — `rider_app/lib/features/home/presentation/active_ride_screen.dart:208-240`
  (`_changeDestination`), gated by `isDestinationChangeable` `:738-741`, button `:759-769`;
  provider `rider_app/lib/features/home/data/change_destination_provider.dart:15-22,50-80,96-100`;
  endpoint `rider_app/lib/core/api/endpoints.dart:17-18`. There is **no** confirmation and **no**
  estimate before the `PUT`.
- **The estimate path is landed and waypoint-aware.** `priceEstimatesProvider` `POST`s
  `/estimates/price` with an ordered `stops` body — `rider_app/lib/features/home/data/home_provider.dart:97-118`;
  `PriceEstimateArgs`/`EstimateStop` `:29-90`; model `rider_app/lib/features/home/model/ride_estimate.dart`
  (`total`, `currency`, `isEstimate`, `legs`); presentation `rider_app/lib/features/home/presentation/ride_estimate_sheet.dart`.
- **The active trip already reads the ordered itinerary and discards the pins.**
  `TripRouteNotifier.load` reads `GET /rides/:id`, parses the sibling `stops` (ordered by
  `sequence`, intermediate stops only, destination mirrored by `dropoff_lat/lng`) —
  `rider_app/lib/features/home/data/trip_route_provider.dart:127-166`; `RideStop` model
  `rider_app/lib/features/home/model/ride_stop.dart:11-37`. It keeps only the concatenated
  `polyline` (`TripRouteState` `:23-49`).
- **The API already fans the change out to the driver.** `PUT /rides/:id/destination` mutates and
  pushes `ride.updated` to rider **and** driver — `internal/service/ride.go:584-603`. The driver’s
  consumption is a separate `driver_app_plans/` line; **no rider work required**.
- **Home already marks stops + destination.** `home_screen.dart:442-489` (stop marker
  `Icons.trip_origin` warning `:466-476`; destination `Icons.location_on` danger `:477-487`), and
  every pin joins the camera fit `:154-190`. The active map has only rider + driver markers —
  `active_ride_screen.dart:537-554`.

## Workstream A — expose the active ride’s ordered itinerary (shared foundation)

Additive fields on `TripRouteState` (`trip_route_provider.dart`), populated from the same
`GET /rides/:id` read `load` already performs (no extra request):

- `LatLng? pickup` and `LatLng? dropoff` (from `pickup_lat/lng`, `dropoff_lat/lng`).
- `List<LatLng> stopPoints` — the ordered **intermediate** stops (never the destination row).
- `String? vehicleType` — from `ride.vehicle_type` (`RideDetail.vehicleType` already parses this
  field but is not stored — `rider_app/lib/features/home/model/ride_detail.dart:16,46`), so the
  change-destination estimate can pick the booked type.

Keep the existing route-honesty contract untouched: these are itinerary pins, not route geometry;
`polyline`/`status`/`message` semantics are unchanged. If the ride has no readable stops, the lists
are empty (degrade to a single pickup→dropoff, matching `trip_route_provider.dart:147-152`).

## Workstream B — stop + destination markers on the active-ride map (R-3)

In `active_ride_screen.dart` build the `MarkerLayer` from `tripRoute` as well as the rider/driver
markers (`:537-554`):

- marker an ordered intermediate stop for each `stopPoints` entry, **before** the destination;
- mark the destination (`dropoff`) distinctly;
- keep the rider (`Icons.my_location`) and driver (`Icons.directions_car`) markers exactly as they
  are, and keep the existing `ValueKey`s / finder behaviour of `tester.widget<MarkerLayer>`.

**Recommendation for the stop visual:** mirror Home’s vocabulary so the two maps agree —
intermediate stops `Icons.trip_origin` (`AppColors.warning`), destination `Icons.location_on`
(`AppColors.danger`). A numbered `A/B/C` overlay is a listed alternative if the human wants
itinerary order called out; either way the stop marker must be visually distinct from the
destination and from the driver. Do **not** remove the Home markers or the camera fit.

## Workstream C — change-destination confirmation + estimate (R-1)

Replace the immediate `PUT` in `_changeDestination` (`:208-240`) with:

1. Push `/location-search`, get the picked `Place` (unchanged, incl. the `_searchBias()` fix for
   bug #21, `:212-221`).
2. Build a `PriceEstimateArgs` from `tripRoute.pickup` + `tripRoute.stopPoints` (as `EstimateStop`)
   + the picked place, and read `priceEstimatesProvider(args).future` (Workstream A supplies the
   pickup/stops; if `pickup` is unavailable, fall back to `rideData['pickup']` /
   `rideData['pickup_lat']/['pickup_lng']` — never fabricate a coordinate).
3. Show a **confirmation dialog/sheet** with the new fare (the `RideEstimate` matching
   `tripRoute.vehicleType`, falling back to the first/only estimate) and the new time (sum of
   `RideEstimateLeg.durationS`; note the price endpoint sends **no** `eta_seconds` —
   `internal/handler/responses.go:180-211`; `RideEstimate.etaSeconds` is always 0 from this call).
   Reuse the existing `ride_estimate_sheet.dart` breakdown idiom and the `is_estimate` caption
   (`Estimated fare — not fully road-routed`, `ride_estimate_sheet.dart:116-122`).
4. **Confirm** → `changeDestinationProvider.changeDestination(...)` (the existing call), then the
   existing snackbar + `ride.updated` re-route path (`:223-239`). **Cancel/back/dismiss** →
   return without calling the provider; the ride, its fare and the driver are untouched.

**Estimate-failure policy (recommended):** if the estimate call fails (500 / timeout / malformed),
do **not** block the mutation behind an advisory number. Show the dialog with an honest
`Estimate unavailable` line and still offer Confirm + Cancel; the `PUT` is the rider’s legitimate
action. (Alternative: block until the estimate loads — rejected: it lets an outage veto a core
action.)

**Honesty note (must be in the dialog copy):** the API’s `ChangeDestination` deliberately does
**not** reprice the booked ride (`internal/service/ride.go:549-560`), and completion recomputes the
final charge from the distance actually driven. So the new number is an **estimate**, not the
guaranteed final fare; label it accordingly and do not overwrite the booked fare in the UI.

## Decisions to lock

- **D1 — Where the estimate inputs come from:** `TripRouteState` itinerary (Workstream A) with the
  `rideData` fallback. (Recommended.)
- **D2 — Booked type only vs all types:** show only the booked `vehicleType` estimate in the
  confirmation (recommended — the rider already chose the vehicle); alternative, reuse the full
  type picker.
- **D3 — Failure policy:** allow Confirm on estimate failure with an `Estimate unavailable` line
  (recommended) vs block.
- **D4 — Stop marker style:** Home-mirroring `trip_origin`/`location_on` (recommended) vs numbered
  `A/B/C`.
- **D5 — Does the confirmed estimate become the booked quote?** **Out of rider scope.** The API
  does not reprice on change; if the product wants the confirmed number to replace the booked
  quote, that is an `api_plans` change (see Cross-domain). The rider plan assumes the API behavior
  is unchanged.

## Boundaries / cross-domain

- **No `shared/` change.** Marker icons/colours and the dialog are app-local; no new shared symbol,
  so no barrel/shim edit (Invariants).
- **No API change required** for either R-1 or R-3: `POST /estimates/price` already takes the
  ordered `stops` body (landed `[fare]`), `GET /rides/:id` already returns the sibling `stops`
  (`internal/handler/ride.go:304-313`), and the destination change already fans out to the driver
  (`internal/service/ride.go:584-603`).
- **Report only (not authored here):** if D5 is answered “yes”, dispatch `api-planner` —
  `ChangeDestination` (`internal/service/ride.go:561`) would need to persist the recomputed quote
  (and decide the fare-snapshot semantics). Do not fold that into this rider plan.
- **Driver line:** the WS push already exists; the driver app’s consumption is owned by
  `driver_app_plans/` — report to the coordinator, do not author.

## Tests (new / changed)

| Test | File | Asserts |
| --- | --- | --- |
| Extend `trip_route_provider` | `rider_app/test/features/home/data/trip_route_provider_test.dart` | `load` exposes `pickup`/`dropoff`/`stopPoints`/`vehicleType`; intermediate-only stops (destination row not duplicated); absent stops degrades to a single leg; the route-honesty fields are unchanged |
| Change-destination confirm | `rider_app/test/features/home/presentation/active_ride_screen_test.dart` (extend `:1158-1203`) | after picking a place, **no** `PUT` fires until Confirm; the estimate request carries the picked dropoff + the current ordered stops; Confirm fires exactly one `PUT` with `{lat,lng,address}` and shows `Destination updated`; adding `POST /estimates/price` to the fixture’s `DioAdapter` |
| Cancel leaves untouched | same file (new) | dismissing the confirmation (Cancel / back) fires **no** `PUT` and leaves `rideData`/destination unchanged |
| Estimate failure | same file (new) | a 500 from `/estimates/price` still shows Confirm + an honest `Estimate unavailable` line; Confirm then `PUT`s |
| Active-trip stop markers | same file (extend the `MarkerLayer`/`driverMarkerPoint` harness `:393-415`) | given `stops` on the `GET /rides/{id}` body (`fixture(stops: ...)` `:192,199`), the `MarkerLayer` contains one marker per ordered stop **and** the destination, distinct from the rider/driver markers; no stops ⇒ markers unchanged |
| Status-chip regression guard | same file (new) | see `[ontrip]_status_labels.md` — `driverArrived` does not render `Matching` |

Existing tests that must stay green / be updated (not deleted): `:1120-1156` (destination change
re-requests the route), `:1213-1292` (no-origin bias), `:1294-1309` (entry absent outside
changeable statuses); `rider_app/test/features/home/data/change_destination_provider_test.dart`.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` must be clean; `melos run test` green across rider / driver / shared.
- **UNVERIFIABLE in this WSL harness:** the on-device map rendering of the new markers (marker
  overlap at street zoom, order legibility) and the real mid-trip estimate round-trip against a
  live API. Close on an Android host with `flutter run`: start a ride with ≥2 stops, confirm the
  markers render in order before the destination, and change the destination mid-trip — confirm the
  new estimate appears before any mutation and that Cancel changes nothing.
- `make flutter-analyze` / `make flutter-test` are **broken from this WSL tree** — do not use them.

## Open inputs / unknowns

1. D5 (above) — does the confirmed estimate become the booked quote? Needs the product owner +
   `api-planner`; blocks only the API-side behavior, not this rider UX.
2. Exact confirmation copy (dialog title / “Estimated new fare” / the actuals-recompute caveat).
3. D2/D3/D4 confirmations.
4. Whether the destination marker should also show the destination’s address label.

## Invariants touched (from STATUS.md)

- Keep the re-export-shim structure intact and add **no** shared symbol / shim.
- The active trip never draws a confident road-less route (`active_ride_screen.dart:517-535`) —
  Workstream B adds point markers only, never a client-synthesized polyline.
- The API never answers an outage with 4xx — the estimate-failure policy (D3) relies on the API’s
  5xx/`is_estimate` contract and must not treat a 4xx as a fatal client bug.
- The `is_estimate` caption / “not fully road-routed” honesty convention
  (`ride_estimate_sheet.dart:116-122`) is preserved.
