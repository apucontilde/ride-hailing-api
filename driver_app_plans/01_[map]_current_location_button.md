---
tag: map
depends_on: ["rider_app_plans/[map]_current_location_button.md"]
status: open
---

# [map] Current-location + route-fit button (driver Trip; dependent consumer)

> **Owner:** `driver-planner`. **Plan only** — no production code, test, manifest or `melos` run in
> this authoring pass. Verify with `melos run analyze` + `melos run test` (Linux FVM SDK, below).
>
> **Dependent cross-domain chain stage, numbered `01_`.** `depends_on` names the **open** rider plan
> `rider_app_plans/[map]_current_location_button.md`, so the filename is
> `01_[map]_current_location_button.md` per the plan-management skill. That rider plan is the
> **canonical owner** of the shared contract; this plan is a **consumer only** and adopts its
> signatures plus the resolved cycle/auto-fit/key semantics **verbatim**.
>
> **Not landed.** The implementation waits for the rider-owned shared symbols (`fitMapCamera`,
> `centerMapCamera`, `AppMapLocateButton` and their barrel exports) to merge. This plan must not claim
> the driver work is done.
>
> **No API/server change, no new dependency, no app shim, no shared redefinition.** Import the shared
> symbols straight from the barrel `package:ride_hailing_shared/ride_hailing_shared.dart`.

## Goal

Give the driver's **Trip** map the same bottom-right control and shared state machine the rider map
gets:

1. when the drawn route first appears (initial mount) or **materially** changes, the shared
   `AppMapLocateButton` auto-fits the route (the road polyline, or the dashed
   driver → next-waypoint line when the route is an estimate/unavailable);
2. a successful auto-fit counts as the **fit** half of the cycle, so the next press centers on the
   driver's current location at zoom 16;
3. presses then alternate **fit route → current location → fit route → …**; a successful action
   advances, a failed action stays on that action and retries it.

The button, the auto-fit scheduler and the camera-fit policy are the shared, rider-owned symbols. The
driver adds only the Trip-screen wiring, the material key, and a test seam.

## Evidence map (verified in this tree)

| Claim | Evidence |
| --- | --- |
| Trip screen owns the `MapController` | `driver_app/lib/features/trip/presentation/trip_screen.dart:32` |
| Legacy screen-owned auto-fit to **remove**: `_fitTo`, post-frame, keyed by `_fittedKey` (its key includes `fetchedAt`) | `trip_screen.dart:82-95` (`_fittedKey` `:33`); `_MapView.onFit` field/param `:305,312`; parent argument `:249`; invocation `:373-376` |
| `build` layout: map is `Expanded(flex: 3)`, controls are `Expanded(flex: 2)` below it | `trip_screen.dart:238-290` (map child `:240-251`, controls `:252-275`) |
| `_MapView` is a `ConsumerWidget` | `trip_screen.dart:296-405` |
| Drawn road points / fallback predicate / dashed straight line | `trip_screen.dart:333-340` (`_roadPoints`), `:352-353` (`useFallback`, `straight`), `:355-365` (polylines) |
| `focus` = driver fix + next waypoint; removed auto-fit call/key shape | `trip_screen.dart:367-377` (key `:375`) |
| `FlutterMap` + shared tile layer/attribution | `trip_screen.dart:379-402` (`FlutterMap` `:381`, tiles `:380,385`, attribution `:401`) |
| `lastPositionProvider` is the driver's live fix | `driver_app/lib/core/location/location_service.dart:38-58` (`GeoPoint` `:38`, provider `:58`); read in Trip at `trip_screen.dart:63,157,187` |
| `RouteCache` carries `isEstimate` and `fetchedAt`; a 200 m driver refetch (threshold) is not a material route change | `driver_app/lib/features/trip/providers/trip_notifier.dart:42-66` (`isEstimate` `:49`, `fetchedAt` `:55`), `:174` (`refetchThresholdM = 200`), `:540` (`fetchedAt: DateTime.now()`) |
| Shared one-shot fix helper returns `Position?`, never throws out | `shared/lib/src/utils/location_helper.dart:25-35` |
| Driver Home has **no map** — only the availability chip icon | `driver_app/lib/features/home/presentation/home_screen.dart:291` (`Icons.gps_fixed`); no `FlutterMap` in that file |
| Existing trip tests: overrides (`mapTileLayerProvider` null, `lastPositionProvider` pickup) and `pumpTrip` | `driver_app/test/features/trip/presentation/trip_screen_test.dart:118-134`, `:247-266` |
| Shared already depends on `flutter_map` 7 / `latlong2` | `shared/pubspec.yaml:20-21` |
| Existing barrel map exports (the new ones append after these) | `shared/lib/ride_hailing_shared.dart:28-30` |

**Driver scope is Trip only.** Driver Home has no map surface, so there is nothing to place.

## Contract ownership + adopted contract (reference, not a redefinition)

**The rider plan is the sole canonical definition.** This section reproduces the public surface only
so the driver implementer does not have to reinterpret it. Do not add, rename, or diverge from these
symbols; do not create a driver shim for them.

From `rider_app_plans/[map]_current_location_button.md` §"CROSS-DOMAIN boundary + canonical shared
contract" (public signatures unchanged by the resolved semantics):

`shared/lib/src/map/map_camera_fit.dart`

```dart
bool fitMapCamera(
  MapController controller,
  List<LatLng> points, {
  EdgeInsets padding = const EdgeInsets.all(48),
  double maxZoom = 16,
});

bool centerMapCamera(
  MapController controller,
  LatLng point, {
  double zoom = 16,
});
```

`shared/lib/src/map/app_map_locate_button.dart`

```dart
class AppMapLocateButton extends StatefulWidget {
  const AppMapLocateButton({
    super.key,
    required this.routeKey,
    required this.hasRoute,
    required this.onFitRoute,
    required this.onCurrentLocation,
    this.onLocationUnavailable,
  });

  final Object? routeKey;
  final bool hasRoute;
  final bool Function() onFitRoute;
  final Future<bool> Function() onCurrentLocation;
  final VoidCallback? onLocationUnavailable;
}
```

Adopted semantics (defined by the rider plan, verbatim):

- **Full press cycle:** presses alternate **fit route → current location → fit route → …**. A
  successful action advances; a failed action stays on that action and retries it (a failed fit
  retries fit; a failed locate retries locate).
- **Auto-fit on material route change:** on initial mount and whenever `routeKey` changes, if
  `hasRoute` is true the shared widget schedules a post-frame `onFitRoute()`. A **successful**
  auto-fit counts as the fit phase, so the next press locates; a **failed** auto-fit leaves the next
  press on fit.
- `hasRoute: false` never auto-fits; every press locates.
- A failed locate (`false`/throw) calls `onLocationUnavailable`; locate calls are guarded against
  double taps.
- Tooltip: `Current location` when the next press will locate (including right after a successful
  auto-fit, or when `hasRoute` is false), else `Fit route`.
- The widget root carries `Key('map-locate-button')`.

**Import:** both symbols plus `LocationHelper` already come from
`package:ride_hailing_shared/ride_hailing_shared.dart` (`trip_screen.dart:5`). No new import line and
no `driver_app/lib/core/map/` shim.

## Locked driver behavior

1. **Placement.** Inside `_MapView`, wrap the existing `FlutterMap` in a `Stack` with
   `Positioned.fill(child: FlutterMap(...))` and add
   `Positioned(right: 16, bottom: 16, child: AppMapLocateButton(...))`. The button overlays the map
   region only; it must not sit over `_StageControls` (the `Expanded(flex: 2)` sibling).
2. **Fit points.** `(!useFallback && road.length >= 2) ? road : focus` — fit the road polyline when it
   is actually drawn; otherwise fit `focus` (driver fix + next waypoint), which is the dashed line
   actually drawn. `hasRoute`: `road.length >= 2 || focus.length >= 2`. A lone driver fix is **not** a
   route.
3. **`routeKey` = material changes only (Option B, driver-specific).**
   `driverTripRouteKey(next, route)` = **next-waypoint coordinates + route status**, where status is
   the 3-value discriminator `none` (`route == null`), `ready` (`!isEstimate`) or `estimate`
   (`isEstimate`). **Exclude** `fetchedAt`, the moving driver fix, and same-endpoint geometry changes.
   `none → ready` (the road route arriving) is a **material** change and auto-fits once; `ready →
   ready` refreshes and same-endpoint reroutes do not auto-fit or reset the cycle. Therefore a 200 m
   driver refetch — and, by the rider contract's same rule, a silent 30 s route refresh — with the
   same next waypoint/status must not move the camera.
4. **`onFitRoute`.** `return fitMapCamera(controller, points, padding: const EdgeInsets.all(48),
   maxZoom: 16);`. The shared button owns auto-fit; the driver does **not** schedule its own.
5. **`onCurrentLocation`.** Start from `ref.read(lastPositionProvider)`. If null, await the one-shot
   seam below (which defaults to `LocationHelper.getCurrentPosition()`), map a non-null `Position` to
   `LatLng`, and use that. If still null return `false`. Otherwise
   `return centerMapCamera(controller, fix);` (shared default zoom 16, confirmed). Never fabricate a
   point.
6. **`onLocationUnavailable`.** Show a truthful `SnackBar('Waiting for your location…')` via
   `ScaffoldMessenger.of(context)`. Return `false` / do not crash when the camera is not attached
   (`centerMapCamera` already handles that).
7. **Remove the old screen-owned auto-fit.** The shared button is the single auto-fit source; the old
   `_fitTo` key includes `fetchedAt`, which violates the material key in #3.
8. **No API change, no new dependency, no app shim, no shared edit.**

## Implementation steps (ordered; Trip screen only)

### 1. App-local, test-overridable one-shot fix seam

Add next to the existing imports/providers in
`driver_app/lib/features/trip/presentation/trip_screen.dart`:

```dart
/// One-shot device fix for the locate button's fallback. Widget tests override
/// it so they never touch the geolocator platform channel.
final driverCurrentPositionProvider =
    Provider<Future<LatLng?> Function()>((ref) => () async {
  final position = await LocationHelper.getCurrentPosition();
  return position == null
      ? null
      : LatLng(position.latitude, position.longitude);
});
```

This is a provider, not a shim, and it keeps the shared-only rule intact. `lastPositionProvider`
remains the primary source; this seam is only touched when that provider is null.

### 2. Pure material-key helper

Add a top-level, testable function in `trip_screen.dart`. Add
`import 'package:flutter/foundation.dart';` for the annotation (SDK import, not a new dependency):

```dart
@visibleForTesting
String driverTripRouteKey(TripWaypoint? next, RouteCache? route) {
  final status = route == null
      ? 'none'
      : route.isEstimate
          ? 'estimate'
          : 'ready';
  return '${next?.lat},${next?.lng}:$status';
}
```

It must not read `fetchedAt`, the driver fix, polyline geometry, totals or duplicate endpoints.

### 3. `_MapView` helpers

Add private helpers/getters to `_MapView`:

- `List<LatLng> _routeFitPoints(...)` → `(!useFallback && road.length >= 2) ? road : focus`.
- `bool _canFitRoute(...)` → `road.length >= 2 || focus.length >= 2`.
- `Future<bool> _locate(WidgetRef ref)`:

  ```dart
  final cached = ref.read(lastPositionProvider);
  if (cached != null) {
    return centerMapCamera(controller, LatLng(cached.lat, cached.lng));
  }
  LatLng? fix;
  try {
    fix = await ref.read(driverCurrentPositionProvider)();
  } catch (_) {
    fix = null;
  }
  if (fix == null) return false;
  return centerMapCamera(controller, fix);
  ```

- `void _showLocationUnavailable(BuildContext context)` → the truthful snackbar. Use
  `ScaffoldMessenger.maybeOf(context)?.showSnackBar(...)` so a detached context cannot throw.

### 4. Wrap the map and place the button

In `_MapView.build`, keep the current polyline/marker/tile computation, then return:

```dart
return Stack(
  children: [
    Positioned.fill(
      child: FlutterMap(
        mapController: controller,
        options: MapOptions(
          initialCenter: initialCenter,
          initialZoom: 13,
        ),
        children: [/* unchanged tile/polyline/marker/attribution children */],
      ),
    ),
    Positioned(
      right: 16,
      bottom: 16,
      child: AppMapLocateButton(
        routeKey: driverTripRouteKey(next, route),
        hasRoute: _canFitRoute,
        onFitRoute: () => fitMapCamera(
          controller,
          _routeFitPoints,
          padding: const EdgeInsets.all(48),
          maxZoom: 16,
        ),
        onCurrentLocation: () => _locate(ref),
        onLocationUnavailable: () => _showLocationUnavailable(context),
      ),
    ),
  ],
);
```

`Positioned.fill` keeps `FlutterMap` sized to the whole `Expanded` map region; the button is inset
16 px from the map's right/bottom edges, so it never covers the controls below. The shared widget
schedules the initial-mount and `routeKey`-change auto-fit; `_MapView` must not.

### 5. Remove the legacy screen-owned auto-fit

- Delete `_fittedKey` (`trip_screen.dart:33`) and `_fitTo` (`:82-95`).
- Remove the `onFit` field/parameter from `_MapView` (`:305,312`) and the `onFit: _fitTo` argument at
  the parent call site (`:249`).
- Delete the `onFit(...)` invocation inside `_MapView.build` (`:373-376`, including the old key).
- Keep the polyline/marker/tile computation and the existing `_syncRoute`/`ref.listen` behavior
  unchanged. The shared `AppMapLocateButton` is the single auto-fit source.

## Tests to add/update

File: `driver_app/test/features/trip/presentation/trip_screen_test.dart`.

The existing container (`:118-134`) must gain a `driverCurrentPositionProvider` override so no test
hits the geolocator platform channel. Extract the container construction into a helper, e.g.
`ProviderContainer buildContainer({required GeoPoint? position, Future<LatLng?> Function()? fix})`,
with the current defaults (`position: GeoPoint(pickupLat, pickupLng)`, `fix: () async => null`), and
reuse it from `setUp`. `pumpTrip` (`:247-266`) stays as-is.

Add:

1. **Button exists bottom-right of the map region, above the controls.**
   `broadcast(status: 'accepted'); await pumpTrip(tester);`
   `final button = find.byKey(const Key('map-locate-button'));`
   `final mapRect = tester.getRect(find.byType(FlutterMap)); final buttonRect = tester.getRect(button);`
   Assert `findsOneWidget`, `buttonRect.right ≈ mapRect.right - 16` (±1), and
   `buttonRect.bottom <= mapRect.bottom` while `buttonRect.top >= mapRect.top` — i.e. the button is
   inside the map rect (the map rect ends where `_StageControls` begins), not in the controls column.

2. **Auto-fit on route load.** Use the route the mock actually stubbed **for that stage**: in
   `accepted`/`enrouteToPickup` the next waypoint is the pickup, so stub the route response as
   `driver fix → pickup` (a ≥2-point polyline) — do **not** reuse a pickup→dropoff fixture, which the
   screen would never have requested for this stage. Override `lastPositionProvider` with a fix away
   from the pickup (e.g. `GeoPoint(pickupLat - 0.002, pickupLng - 0.002)`) so the endpoints are
   distinguishable. After `pumpTrip` with an accepted trip and that stub, pump past the route load:
   assert the camera is fitted to the drawn leg — `controller.camera.visibleBounds.contains(driverFix)`
   and `...contains(const LatLng(pickupLat, pickupLng))` — and the tooltip is `Current location`
   (`find.byTooltip('Current location')`). **Do not assert the dropoff** on the enroute leg.

3. **Full cycle.** From the auto-fitted state (a successful auto-fit counts as fit), tap once and
   assert `controller.camera.center` ≈ the `lastPositionProvider` fix at zoom ≈ 16; tap again and
   assert the drawn leg is fitted again (`visibleBounds` contains the driver fix + pickup); tap a
   third time and assert the driver fix at zoom 16 again.

4. **Material-key unit test** (plain `test`, same file, using the top-level
   `driverTripRouteKey`):
   - equal for two `RouteCache`s differing only in `fetchedAt` (same `next`, same `isEstimate`);
   - different for `none → ready` (`null` vs a non-estimate `RouteCache`);
   - different for `ready → estimate` (same `next`, `isEstimate` false vs true);
   - different when `next` changes.

5. **No-fix path shows the truthful snackbar.** Rebuild the container with `lastPosition: null` and
   `fix: () async => null`; pump an accepted trip. With no driver fix, `_syncRoute` cannot fetch a
   route and `focus` has only the next waypoint, so `hasRoute` is false (the next waypoint alone is
   not a route). The first tap therefore locates immediately; pump and assert
   `find.text('Waiting for your location…')` and that no exception is thrown. This exercises the
   seam, not `LocationHelper`/the platform channel.

6. **Route-change auto-fit.** After the initial pickup-leg auto-fit, a destination-only
   `ride.updated` / next-waypoint change (e.g. `in_progress` with a moved `dropoffLat`/`dropoffLng`)
   must auto-fit the new leg after the frame and the next tap must locate. Stub the new
   driver→dropoff leg for that stage, assert the post-frame camera contains the new dropoff, and
   assert the next tap centers on the driver fix at zoom 16. The old "optional" reset note is
   replaced by this case.

Remove any assertion that expected the pre-auto-fit "first press fits" behavior or a `fetchedAt`-driven
reset.

## Out of scope

- **Rider edits** — `rider_app/` screens and `rider_app_plans/` are the rider owner's.
- **Shared edits** — `shared/lib/src/map/map_camera_fit.dart`,
  `shared/lib/src/map/app_map_locate_button.dart`, and the barrel exports are authored by the rider
  plan. The driver only imports them.
- **API/server edits** — none.
- **Driver Home** — no map, so no button.
- Real-device GPS/permission/map rendering; Android behavior is UNVERIFIABLE in this WSL harness.
- New dependencies, app shims, or moving files into `shared/`.

## Open decisions

**None.** All driver-relevant decisions are resolved and closed.

1. **Full cycle — resolved.** Presses alternate **fit route → current location → fit route → …**; a
   successful action advances, a failed action stays on that action and retries.
2. **Auto-fit on material route change — resolved.** The shared `AppMapLocateButton` auto-fits on
   initial mount and whenever `routeKey` changes when `hasRoute` is true. A successful auto-fit makes
   the next press locate; a failed auto-fit leaves the next press on fit. This is the single
   cross-app implementation; the driver screen must not duplicate it.
3. **Locate zoom — resolved. `16`**, the shared `centerMapCamera` default.
4. **Material-change key only (Option B, driver-specific) — resolved.** `routeKey` = next-waypoint
   coordinates + a 3-value route status: `none` (`route == null`), `ready` (`!isEstimate`), `estimate`
   (`isEstimate`). `fetchedAt`, the moving driver fix and same-endpoint geometry changes are
   explicitly excluded. `none → ready` (the road route arriving) is a material change and auto-fits
   once; `ready → ready` refreshes (the 200 m driver refetch and any silent 30 s refresh) and
   same-endpoint reroutes are not.
5. **No-fix behavior — resolved.** `lastPositionProvider` → app-local `driverCurrentPositionProvider`
   → `centerMapCamera` at zoom 16; return `false` and show `Waiting for your location…` when no fix
   exists. Never fabricate a point.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- **Run one Flutter/Melos agent at a time.** Melos shares the workspace `/.dart_tool`; concurrent
  agents can corrupt or cross-contaminate build/test state.
- Landing requires the rider-owned shared suites plus the updated `trip_screen_test.dart` to be
  green and the full `melos run test` to pass. The implementation is blocked until the rider-owned
  shared symbols merge; this plan does not claim the driver work is landed.
- **UNVERIFIABLE in this WSL harness:** real Android/iOS device behavior — an actual GPS fix, the OS
  permission dialog, real `FlutterMap` camera animation, and touch placement on physical hardware.
  Close those on a device/host before claiming device-level behavior.
- **Dangling-`depends_on` check:** `rider_app_plans/[map]_current_location_button.md` exists in this
  tree (verified), so the `01_` numbering and the dependency resolve. The shared signatures are
  adopted verbatim from that file; if the rider plan changes them, this plan is updated to match —
  never the reverse.
