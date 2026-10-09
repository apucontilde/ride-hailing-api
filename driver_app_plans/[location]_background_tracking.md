---
tag: location
depends_on: []
status: deferred
---

# [location] Background tracking — keep an online driver positioned when backgrounded

> **DEFERRED** — a future product feature, not a bug-fix prerequisite. Do **not** start until the
> manifest fix `[location]_android_location_permission.md` has landed (foreground permissions +
> `uses-feature` must exist first) **and** the product has decided screen-off dispatchability is worth
> the Play Store review and battery cost. Owner: `driver-planner`. Verify: `melos run analyze` +
> `melos run test` (Linux FVM SDK — see STATUS.md Verification); the Android behavior is
> **UNVERIFIABLE in this WSL tree** and must be closed on an Android host (see Verification).
>
> **OWNERSHIP:** this plan owns the coupled `ACCESS_BACKGROUND_LOCATION` permission and the
> `FOREGROUND_SERVICE`/`FOREGROUND_SERVICE_LOCATION` permissions. `[location]_android_location_permission.md`
> deliberately does **not** add them; a bare background-location permission is useless without the
> service described here.
>
> **Why deferred (per the skill):** the skill reserves `status: deferred` for a plan whose work is gated
> on a product decision and a landed prerequisite; this is a new feature (foreground service, persistent
> notification, Play Store declaration, battery/lifecycle design), not a fix for a broken landed
> capability. It is independent (`depends_on: []`, matching the rider deferred-plan convention) and
> unnumbered — its only prerequisite is a gate, not an open plan it must extend.

## Goal

An online driver who backgrounds the app or locks the screen currently stops streaming fixes, ages out
of dispatch's 30 s window, and is silently skipped — "online" really means "app in foreground". This
plan keeps an online/on-trip driver dispatchable while backgrounded using an Android **foreground
service** with a persistent notification, and adds the driver-side UX, permissions, and Play Store
declaration that requires.

## The bug (verified)

- `driver_app/lib/features/home/presentation/home_screen.dart:48` calls `service.start()`
  **unconditionally** on Home init (inside the `addPostFrameCallback`, `:41-53`), with no
  `WidgetsBindingObserver` / `AppLifecycleState` handling anywhere in `driver_app/lib` (grep for
  `AppLifecycleState`/`didChangeAppLifecycleState`/`WidgetsBindingObserver` returns nothing).
- `LocationService.start()` (`driver_app/lib/core/location/location_service.dart:93-102`) subscribes to
  `LocationHelper.getPositionStream()`, which is a plain `Geolocator.getPositionStream(...)`
  (`shared/lib/src/utils/location_helper.dart:37-44`) with no foreground-service config.
- `_onPosition` publishes locally every fix but early-returns unless `availabilityNotifier.online`
  (`location_service.dart:122-135`), and dispatch only considers a `driver_positions` row younger than
  **30 s** (documented in `publishLastPosition`, `location_service.dart:159-179`). The `[dispatch]`
  keep-alive fix addresses a dead socket; it does **not** address a stopped location stream.
- Therefore: background/lock → Android suspends the isolate → no fixes → row ages past 30 s → dispatch
  skips the driver. This is bug #18 in `STATUS.md`.

## Why `ACCESS_BACKGROUND_LOCATION` alone is not the fix

On Android 10+, a bare `ACCESS_BACKGROUND_LOCATION` grant does not keep the Dart isolate emitting fixes:
the app process can still be frozen/killed in the background, so no stream events arrive. The permission
is necessary but **insufficient**. The isolate must be kept alive by a foreground service with an ongoing
notification. The manifest plan's §3 records this and leaves the permission to this plan.

## Scope

### 1. Permissions (owned here — NOT in the manifest plan)

Add to `driver_app/android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/> <!-- Android 14+ -->
<uses-permission android:name="android.permission.WAKE_LOCK"/>                 <!-- only if enableWakeLock -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>        <!-- Android 13+ notification prompt -->
```

- Declare the foreground service with `android:foregroundServiceType="location"` on the service element
  the chosen package contributes (or the app's own service).
- The app's `targetSdk` is the Flutter default **36** (`driver_app/android/app/build.gradle.kts:20-23`;
  Flutter 3.47.3 `FlutterExtension.kt:34`), so Android 10+ background rules and the Android 14
  foreground-service-type requirement both apply. **No minSdk change** (still `minSdk 24`).
- `ACCESS_BACKGROUND_LOCATION` triggers a **separate** Android 10+ prompt ("Allow all the time") and, on
  Android 11+, can only be granted from system settings — the UX in §5 must handle that path.

### 2. Foreground service (the real mechanism)

- **First choice — `geolocator` `AndroidSettings.foregroundNotificationConfig`:** pass a
  `ForegroundNotificationConfig` (title/text/channel/icon/`setOngoing: true`) into
  `Geolocator.getPositionStream(locationSettings: AndroidSettings(...))`. This is the smallest change and
  the task's stated approach.
  - **Honest caveat (verified in the pinned plugin, `geolocator_android` 4.6.2
    `src/types/android_settings.dart:52-56`):** the plugin's own doc says this flag "does not run your
    service in the background, it just increases the priority of your activity … It does not prevent
    Android from killing the activity. If you want to receive background location updates even if the
    activity is destroyed you need to use a third party background service package that will start a new
    Flutter Engine that is not tied to your main activity."
  - So if the product requires fixes even after the activity is killed (screen locked for a long time,
    low-memory), the durable option is a dedicated background package (e.g. `flutter_foreground_task` /
    `flutter_background_service`) that runs a separate isolate and streams positions to the main isolate.
    **Decide at start time** (see Decisions to surface). Either way the permission set in §1 is the same.
- **Shared `LocationHelper` change:** `getPositionStream()` currently hardcodes a platform-agnostic
  `LocationSettings` (`shared/lib/src/utils/location_helper.dart:37-44`). Supporting a foreground service
  means either an Android-specific overload/parameter on `LocationHelper` (a **shared** change that must
  coordinate the rider plan, which does not need background tracking) or a driver-local stream factory.
  Prefer an additive, opt-in shared parameter so the rider behavior is unchanged. This is a
  `shared/lib/**` change and is **not made here**.
- **Lifecycle:** tie the service to availability. Start when the driver goes online (or on-trip) and stop
  when offline / trip terminal — do not run it unconditionally at Home init as today
  (`home_screen.dart:48`). `AvailabilityNotifier.onOnlineChanged` already exists
  (`driver_app/lib/features/home/providers/availability_notifier.dart`) and is the natural hook.
  Add a `WidgetsBindingObserver` only where foreground/background transitions need to re-check (the
  service, not the UI, should own continued streaming).

### 3. Battery & product cost

- The persistent notification is mandatory while the service runs; the driver must see it and be able to
  tell the app is streaming. `setOngoing: true` prevents dismissal; `enableWakeLock`/`enableWifiLock` are
  optional and should stay `false` unless measurement shows the fix cadence needs them (a wake lock costs
  battery and needs its own justification).
- Battery-optimization exemptions (Doze) are device/OEM-specific; document expected behavior, do not
  silently rely on an exemption.

### 4. Play Store compliance (required for `ACCESS_BACKGROUND_LOCATION`)

- A **background-location declaration + justification** in the Play Console is required; the feature must
  be prominent/disclosed in-app (a clear per-feature notice, not buried in a general privacy policy).
- Record the required disclosure copy and the review-approval step as landing prerequisites; a rejected
  declaration blocks release.
- Keep the foreground-service type and notification honest: the reason the permission is requested is the
  visible ongoing "sharing your location while online" service.

### 5. Driver-side UX

- Persistent notification: e.g. "You're online — sharing your location" with a tap target back to Home.
- A clear in-app notice the first time the driver goes online explaining the background permission and
  the ongoing notification, with a settings deep-link (`Geolocator.openAppSettings()`) for the
  "Allow all the time" path on Android 11+.
- Handle denial/degradation: if background location is not granted, fall back to foreground-only and
  surface the limitation honestly (the existing `appPermissionProvider` banner is the seam). This plan
  can also absorb the deferred `deniedForever` affordance from
  `[location]_android_location_permission.md` §5, since it owns the richer permission UX.

### 6. Tests

- Provider/service tests: the service starts on going online and stops on going offline; a backgrounded
  lifecycle state does not stop the stream while online (with the platform stream faked).
- Widget tests for the first-run notice and the notification/notification-channel copy where testable.
- `driver_app/test/core/location/location_service_test.dart` and the Home suite must stay green.
- The Android foreground service itself is not Dart-testable: mark **UNVERIFIABLE** here and close on an
  Android host (§Verification). Any `shared/LocationHelper` change needs the shared suite kept green.

## Decisions to surface

1. **Do we ship it?** Is screen-off dispatchability worth the extra Play review, the persistent
   notification, and battery use? (Deferred until the product answers.)
2. **Mechanism:** `geolocator` `foregroundNotificationConfig` (small, activity-tied) vs a dedicated
   background-service package (durable across activity death). Recommend starting with the former and
   measuring, with the latter as the fallback if OEM killing is observed.
3. **Scope of "online":** service runs while **online only**, or also across the on-trip stages after the
   app is backgrounded? (An on-trip driver arguably needs it most.)
4. **Shared `LocationHelper`:** adopt an additive, opt-in Android-settings parameter (coordinate the rider
   plan) vs a driver-local stream factory. Recommend the shared additive parameter to avoid divergence.
5. **Battery:** default `enableWakeLock: false`; revisit only with measurements.

## Out of scope

- The manifest prerequisite itself (`ACCESS_FINE_LOCATION`/`COARSE`, `uses-feature`) — owner:
  `[location]_android_location_permission.md`.
- The tile/OSM work (`[map]_android_tile_access.md`) and any API/Go change.
- iOS background modes (the rider may get its own iOS work; this plan is Android-first).
- Fleet tracking of a driver who is **offline** (privacy): the service must not run when offline.

## Cross-domain

- `ACCESS_BACKGROUND_LOCATION` and the foreground-service permissions are **owned here**, not by the
  manifest plan — do not add them twice.
- The `shared/lib/src/utils/location_helper.dart` change (if chosen) is a cross-app shared change and
  must be coordinated with the landed rider `[location]` fix
  (`rider_app_plans/STATUS.md` → Landed `[location]`); the rider does **not** need background location
  and its behavior must stay foreground-only.
- Driver bug #18 in `driver_app_plans/STATUS.md` is this plan's target.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` / `melos run test` over `shared/` + `driver_app/` must be green (Linux FVM SDK).
- **UNVERIFIABLE in this WSL tree:** the Android foreground service and background behavior. On an
  Android host, close with:
  - `flutter build apk --release` and inspect the **merged** manifest for `ACCESS_BACKGROUND_LOCATION`,
    `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, and a
    `android:foregroundServiceType="location"` service;
  - install, go online, grant "Allow all the time", background/lock the phone, and confirm
    `PUT /driver/me/location` keeps receiving fixes and the ongoing notification is visible;
  - confirm the driver is still offered a ride while backgrounded;
  - confirm the service stops (notification gone, fixes stop) when the driver goes offline;
  - confirm Play's background-location declaration prerequisites are recorded before release.
