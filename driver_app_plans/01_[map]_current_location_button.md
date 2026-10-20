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
> **canonical owner** of the shared contract; this plan is a **consumer only**.
>
> **No API/server change, no new dependency, no app shim, no shared redefinition.** Import the shared
> symbols straight from the barrel `package:ride_hailing_shared/ride_hailing_shared.dart`.

## Goal

Give the driver's **Trip** map the same bottom-right control the rider map gets:

1. the **first** press zooms the map to fit the drawn route (the road polyline, or the dashed
   driver → next-waypoint line when the route is an estimate/unavailable);
2. **every later** press centers the map on the driver's current location at zoom 16;
3. a route change resets the cycle so the next press fits the new route.

The button and the camera-fit policy are the shared, rider-owned symbols. The driver adds only the
Trip-screen wiring and a test seam.

## Evidence map (verified in this tree)

| Claim | Evidence |
| --- | --- |
| Trip screen owns the `MapController` | `driver_app/lib/features/trip/presentation/trip_screen.dart:32` |
| Existing auto-fit: `_fitTo`, post-frame, keyed by `_fittedKey` | `trip_screen.dart:79-92` (`_fittedKey` `:33`) |
| `build` layout: map is `Expanded(flex: 3)`, controls are `Expanded(flex: 2)` below it | `trip_screen.dart:221-272` (map child `:223-233`, controls `:235-258`) |
| `_MapView` is a `ConsumerWidget` | `trip_screen.dart:279-397` |
| Drawn road points / fallback predicate / dashed straight line | `trip_screen.dart:317-322` (`_roadPoints`), `:334-335` (`useFallback`, `straight`), `:337-351` (polylines) |
| `focus` = driver fix + next waypoint; current auto-fit call and key shape | `trip_screen.dart:353-366` (key `:362-365`) |
| `FlutterMap` + shared tile layer/attribution | `trip_screen.dart:368-395` (`FlutterMap` `:370`, tiles `:377`, attribution `:393`) |
| `lastPositionProvider` is the driver's live fix | `driver_app/lib/core/location/location_service.dart:38-58` (`GeoPoint` `:38`, provider `:58`); read in Trip at `trip_screen.dart:63,154,183` |
| Shared one-shot fix helper returns `Position?`, never throws out | `shared/lib/src/utils/location_helper.dart:25-35` |
| Driver Home has **no map** — only the availability chip icon | `driver_app/lib/features/home/presentation/home_screen.dart:291` (`Icons.gps_fixed`); no `FlutterMap` in that file |
| Existing trip tests: overrides (`mapTileLayerProvider` null, `lastPositionProvider` pickup) and `pumpTrip` | `driver_app/test/features/trip/presentation/trip_screen_test.dart:104-133`, `:234-253` |
| Shared already depends on `flutter_map` 7 / `latlong2` | `shared/pubspec.yaml:20-21` |
| Existing barrel map exports (the new ones append after these) | `shared/lib/ride_hailing_shared.dart:28-30` |

**Driver scope is Trip only.** Driver Home has no map surface, so there is nothing to place.

## Contract ownership + adopted contract (reference, not a redefinition)

**The rider plan is the sole canonical definition.** This section reproduces the public surface only
so the driver implementer does not have to reinterpret it. Do not add, rename, or diverge from these
symbols; do not create a driver shim for them.

From `rider_app_plans/[map]_current_location_button.md` §"CROSS-DOMAIN boundary + canonical shared
contract":

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

Semantics the driver relies on (defined by the rider plan, adopted as-is):

- First press while `hasRoute` is true calls `onFitRoute`; every later press calls
  `onCurrentLocation`; there is no toggle back.
- A changed `routeKey` resets the cycle; `hasRoute: false` skips the fit and locates immediately.
- A failed fit (`false`) does not advance the cycle; a failed locate (`false`/throw) calls
  `onLocationUnavailable`. Locate calls are guarded against double taps.
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
3. **`routeKey`.** Reuse the existing auto-fit key shape:
   `'${next?.lat},${next?.lng}:${route?.fetchedAt.millisecondsSinceEpoch}'`
   (`trip_screen.dart:362-365`). Do **not** include the moving driver fix, or every GPS update would
   reset the press cycle.
4. **`onFitRoute`.** `return fitMapCamera(controller, points, padding: const EdgeInsets.all(48),
   maxZoom: 16);`. Leave the existing `_fitTo` auto-fit path (and its `_fittedKey`) unchanged.
5. **`onCurrentLocation`.** Start from `ref.read(lastPositionProvider)`. If null, await the one-shot
   seam below (which defaults to `LocationHelper.getCurrentPosition()`), map a non-null `Position` to
   `LatLng`, and use that. If still null return `false`. Otherwise
   `return centerMapCamera(controller, fix);` (shared default zoom 16). Never fabricate a point.
6. **`onLocationUnavailable`.** Show a truthful `SnackBar('Waiting for your location…')` via
   `ScaffoldMessenger.of(context)`. Return `false` / do not crash when the camera is not attached
   (`centerMapCamera` already handles that).
7. **No API change, no new dependency, no app shim, no shared edit.**

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

### 2. `_MapView` helpers

Add private helpers/getters to `_MapView` (they may take the computed `road`, `focus` and
`useFallback` as parameters, or be computed in `build`):

- `List<LatLng> _routeFitPoints(...)` → `(!useFallback && road.length >= 2) ? road : focus`.
- `bool _canFitRoute(...)` → `road.length >= 2 || focus.length >= 2`.
- `String _routeKey(...)` → the exact key shape in locked decision 3.
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

### 3. Wrap the map and place the button

In `_MapView.build`, keep the current polyline/marker/tile computation and the existing `onFit(...)`
call exactly as they are, then return:

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
        routeKey: _routeKey,
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
16 px from the map's right/bottom edges, so it never covers the controls below.

### 4. Parent call site

`TripScreen.build` already passes `controller`, `next`, `driverPosition`, `route` and `onFit` to
`_MapView` (`trip_screen.dart:227-233`). **No parent change is needed**, and `_fitTo` stays
byte-for-byte behaviorally unchanged.

## Tests to add/update

File: `driver_app/test/features/trip/presentation/trip_screen_test.dart`.

The existing container (`:113-128`) must gain a `driverCurrentPositionProvider` override so no test
hits the geolocator platform channel. Extract the container construction into a helper, e.g.
`ProviderContainer buildContainer({required GeoPoint? position, Future<LatLng?> Function()? fix})`,
with the current defaults (`position: GeoPoint(pickupLat, pickupLng)`, `fix: () async => null`), and
reuse it from `setUp`. `pumpTrip` (`:234-253`) stays as-is.

Add:

1. **Button exists bottom-right of the map region, above the controls.**
   `broadcast(status: 'accepted'); await pumpTrip(tester);`
   `final button = find.byKey(const Key('map-locate-button'));`
   `final mapRect = tester.getRect(find.byType(FlutterMap)); final buttonRect = tester.getRect(button);`
   Assert `findsOneWidget`, `buttonRect.right ≈ mapRect.right - 16` (±1), and
   `buttonRect.bottom <= mapRect.bottom` while `buttonRect.top >= mapRect.top` — i.e. the button is
   inside the map rect (the map rect ends where `_StageControls` begins), not in the controls column.

2. **First press fits the drawn leg; second press centers on the fix at zoom 16.**
   Use the route the mock actually stubbed **for that stage**: in `accepted`/`enrouteToPickup` the
   next waypoint is the pickup, so stub the route response as `driver fix → pickup` (a ≥2-point
   polyline) — do **not** reuse a pickup→dropoff fixture, which the screen would never have requested
   for this stage. Override `lastPositionProvider` with a fix away from the pickup (e.g.
   `GeoPoint(pickupLat - 0.002, pickupLng - 0.002)`) so the two endpoints are distinguishable.
   `broadcast(status: 'accepted'); stubDriverToPickupRoute(); await pumpTrip(tester); await tester.pumpAndSettle();`
   Read `final controller = tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!;`
   Move the camera away (`controller.move(const LatLng(9.0, -84.0), 5); await tester.pump();`), tap
   `map-locate-button`, pump, then assert the fitted leg's endpoints are in view:
   `controller.camera.visibleBounds.contains(driverFix)` and
   `controller.camera.visibleBounds.contains(const LatLng(pickupLat, pickupLng))`. **Do not assert
   the dropoff here** — it is not part of the `enrouteToPickup` leg. (To assert the dropoff, add a
   separate `in_progress`/`driving` case where it *is* the next waypoint, stub that
   driver→dropoff leg, and assert the dropoff there.) Tap again and assert
   `controller.camera.center` ≈ the `lastPositionProvider` fix and `controller.camera.zoom` ≈ 16.
   (The driver fix is a constant in this test; the shared widget suite covers the routeKey-reset
   cycle.)

3. **No-fix path shows the truthful snackbar.**
   Rebuild the container with `lastPosition: null` and `fix: () async => null`; pump an accepted
   trip; tap `map-locate-button` (no route ⇒ `hasRoute: false` ⇒ straight to locate); pump; assert
   `find.text('Waiting for your location…')` and that no exception is thrown. This exercises the
   seam, not `LocationHelper`/the platform channel.

Optional (shared suite already covers it): a destination-only `ride.updated` resets the cycle.

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

Only confirmations remain; the contract itself is not re-litigated.

1. **Confirm the one-way press cycle** (first = fit route, all later = current location). Adopted
   verbatim from the rider contract; surfaced only for human confirmation.
2. **Confirm the locate zoom (16).** It is the shared `centerMapCamera` default; changing it is a
   one-line change in the shared owner, not in this plan.
3. **Confirm the `routeKey` cadence.** Reusing `next + fetchedAt` means a silent route refresh (new
   `fetchedAt`) resets the cycle, so a driver who has located may see the next press fit again. This
   is the same rule as the current auto-fit; confirm that is acceptable or narrow the key in both
   plans together.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- **Run one Flutter/Melos agent at a time.** Melos shares the workspace `/.dart_tool`; concurrent
  agents can corrupt or cross-contaminate build/test state.
- Landing requires the rider-owned shared suites plus the updated `trip_screen_test.dart` to be
  green and the full `melos run test` to pass.
- **UNVERIFIABLE in this WSL harness:** real Android/iOS device behavior — an actual GPS fix, the OS
  permission dialog, real `FlutterMap` camera animation, and touch placement on physical hardware.
  Close those on a device/host before claiming device-level behavior.
- **Dangling-`depends_on` check:** `rider_app_plans/[map]_current_location_button.md` exists in this
  tree (verified), so the `01_` numbering and the dependency resolve. If the rider plan changes its
  symbols, this plan is updated to match — never the reverse.
