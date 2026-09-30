---
tag: online
depends_on: []
status: open
---

# Driver location-permission state (banner) + app-init tidy

Fixes bugs **#1** and **#7** of `driver_app_plans/STATUS.md` (both owned by `[online]`).

`appPermissionProvider` is declared but **never written**, so `AppPermissionState` stays at its
`granted: false, deniedPermanently: false` default forever and the "Location access denied" banner
can never render. Alongside, `app.dart` has two authenticated branches that do the same thing.

**Read first:**

- `driver_app/lib/core/location/location_service.dart:10-31` — `AppPermissionState` +
  `appPermissionProvider` (never written).
- `driver_app/lib/core/location/location_service.dart:106-108` — `requestPermission()` returns the
  bool from `LocationHelper` and drops it; `LocationService` has no `Ref`.
- `driver_app/lib/features/home/presentation/home_screen.dart:44-58` — the initState post-frame
  block reads the (always-default) provider, then calls `requestPermission()` without storing it.
- `driver_app/lib/features/home/presentation/home_screen.dart:89,200-218` — the banner read.
- `driver_app/lib/app.dart:12-27` — the two identical authenticated branches (bug #7).
- `shared/lib/src/utils/location_helper.dart:4-14` — `requestPermission()` returns only a `bool`;
  it cannot distinguish `deniedForever` today.

## Gap (verified)

- `requestPermission()` at `location_service.dart:106` returns `LocationHelper.requestPermission()`
  and nothing writes `appPermissionProvider`, so `permission.deniedPermanently` is always `false`
  and `home_screen.dart:200` never shows the banner. `home_screen.dart:51-56` branches on
  `permission.granted`, which is likewise always `false`, so both arms are equivalent.
- `app.dart:18-27`: the `isOnline == true` branch and the plain-authenticated branch both call
  `service.start()` — the only distinct branch is `else → stop()`.

## Work

1. **Additive shared helper (do not break the rider).** `shared/lib/src/utils/location_helper.dart`
   gains a detailed resolver returning a Dart record, e.g.
   `static Future<({bool granted, bool deniedPermanently})> requestPermissionDetailed()`, mapping
   `always`/`whileInUse` → `granted` and `deniedForever` → `deniedPermanently`. Keep the existing
   `requestPermission()` delegating to it so `rider_app/lib/features/home/presentation/home_screen.dart:43`
   is unchanged. Only ADD; do not edit the rider call site.
2. **Publish permission from the service.** Give `LocationService` an `onPermission` callback
   (mirror the existing `onPosition` callback), called from `requestPermission()` with the mapped
   result. Wire it in `locationServiceProvider` (`location_service.dart:212-220`) to write
   `ref.read(appPermissionProvider.notifier).state` — the provider already owns the `Ref`.
3. **`home_screen.dart:44-58`:** always `service.start()`, then call `requestPermission()` when the
   current state is neither `granted` nor `deniedPermanently` (so a permanent denial is not
   re-prompted on every build). The banner at `:200` then reflects real state.
4. **Bug #7 — tidy `app.dart:18-27`:** collapse to `if (authState.isAuthenticated) service.start();
   else service.stop();`, keeping the crash-recovery comment on the `start` arm. No behaviour
   change; both old authenticated branches already did the same work.
5. Tests:
   - `driver_app/test/core/location/location_service_test.dart`: `requestPermission()` writes
     `granted: true` when the OS grants; `deniedPermanently: true` on `deniedForever` (fake the
     helper/geolocator seam). Confirm the existing suite still passes unchanged where it does not
     touch permission.
   - `driver_app/test/features/home/presentation/home_screen_test.dart`: with
     `appPermissionProvider` overridden to `deniedPermanently`, the denial banner renders.

## Tests

- Provider/service test for permission persistence; widget test for the banner; existing
  `app.dart` start/stop coverage stays green after the tidy.

## Accept

- A permanently-denied driver sees the banner on `/home`; a granted driver does not.
- `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
