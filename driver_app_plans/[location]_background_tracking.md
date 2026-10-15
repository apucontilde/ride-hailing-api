---
tag: location
depends_on: ["landed [location] Android foreground permissions (driver_app_plans/STATUS.md)"]
status: open
---

# [location] Background tracking — keep an online driver positioned when backgrounded

> **OPEN** — this is the fix for driver bug **#18** (an online driver goes dark when the app is
> backgrounded or the screen locked). Its prerequisite has landed: the foreground permission work
> (`ACCESS_FINE_LOCATION`/`COARSE` + `uses-feature`) is now in the driver main manifest
> (`driver_app_plans/STATUS.md` → Landed `[location]`). Owner: `driver-planner`. Verify:
> `melos run analyze` + `melos run test` (Linux FVM SDK — see STATUS.md Verification); the Android
> behavior is **UNVERIFIABLE in this WSL tree** and must be closed on an Android host (see
> Verification).
>
> **OWNERSHIP:** this plan owns the coupled `ACCESS_BACKGROUND_LOCATION` permission and the
> `FOREGROUND_SERVICE`/`FOREGROUND_SERVICE_LOCATION` permissions. The landed foreground `[location]`
> capability deliberately does **not** add them; a bare background-location permission is useless without
> the service described here.
>
> **Why open now (per the skill):** the work was deferred pending a product decision; that decision is
> now to fix bug #18, so the plan flips to `status: open`. It is unnumbered — its `depends_on` names
> landed capability, not an open plan it must extend. The scope below (foreground service, persistent
> notification, Play Store declaration, battery/lifecycle design) is unchanged; the "Decisions to
> surface" section still records the mechanism choices to settle at implementation time.
>
> **IMPLEMENTATION STATUS (2026-10-15, WIP — NOT LANDED).** The driver-side mechanics are implemented
> in-tree against decision #2's **first choice** (the `geolocator` `foregroundNotificationConfig`):
> the driver-local stream factory `driver_app/lib/core/location/driver_location_stream.dart`, the
> availability-driven `LocationService.setForegroundTracking` + `onResumed` hook, the app-level
> `WidgetsBindingObserver` (`driver_app/lib/core/location/app_lifecycle_notifier.dart`,
> `driver_app/lib/app.dart`), the coupled permissions in the main manifest, and the first-run notice
> with an `openAppSettings()` deep-link. `melos run analyze` is clean and `melos run test` is green
> (driver 408, shared 205 +1 skipped, rider 452). **This does NOT close bug #18:** every Android
> on-device behavior below is UNVERIFIABLE in this WSL harness, so the row stays OPEN/WIP pending the
> closing commands in §Verification and `antagonistic-reviewer`. The durable background-isolate
> fallback (decision #2) and the Play Store declaration (decision #1) remain open. Also open:
> `POST_NOTIFICATIONS` is **declared but not requested at runtime** (no permission plugin was added —
> `geolocator` only requests location), so the notice's "Open settings" deep-link is the grant path; the
> service still runs without it, but the notification is hidden. A programmatic prompt is a follow-up.

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
notification. The landed foreground `[location]` work records this and leaves the permission to this plan.

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
  can also absorb the deferred `deniedForever` affordance from the landed `[location]` capability
  (`driver_app_plans/STATUS.md` → Landed `[location]`), since it owns the richer permission UX.

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

- The foreground permission prerequisite itself (`ACCESS_FINE_LOCATION`/`COARSE`, `uses-feature`) —
  landed; see `driver_app_plans/STATUS.md` → Landed `[location]`.
- The tile/OSM work (landed; `driver_app_plans/STATUS.md` → Landed `[map]`) and any API/Go change.
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

**On-host (this WSL harness — run and report):**
```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze     # driver/shared/rider clean
melos run test        # driver 408, shared 205 (+1 skipped), rider 452 — all passed
```
Manifest correctness is verifiable by inspection only (no emulator/Gradle in WSL).

**UNVERIFIABLE in this WSL tree — the exact on-host closing commands (run on an Android host).**
These are the commands the human runs to finish verification; nothing here is claimed as verified
until they pass:

```bash
# 1. Build a debug APK (works without a device) and confirm the merged manifest.
flutter build apk --debug
# The merged manifest is under build/app/intermediates/merged_manifests/debug/AndroidManifest.xml:
#   - ACCESS_BACKGROUND_LOCATION, FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION, POST_NOTIFICATIONS
#   - <service android:name="com.baseflow.geolocator.GeolocatorLocationService"
#              android:foregroundServiceType="location"/> (contributed by geolocator_android)
# Inspect the merged (text) manifest directly:
#   cat build/app/intermediates/merged_manifests/debug/AndroidManifest.xml

# 2. Install + observe the live behavior on a connected device/emulator.
flutter devices
flutter run -d <device-id>
# In-app manual steps:
#   a. Log in, tap the online switch. The first-run notice appears -> "Open settings",
#      set Location to "Allow all the time" (and allow notifications on Android 13+).
#   b. Confirm the ongoing "You're online / Sharing your location with dispatch" notification.
#   c. Background the app / lock the screen for >60 s.
#   d. On the server, confirm PUT /api/v1/driver/location keeps arriving (row younger than 30 s).
#   e. Confirm a ride offer is still delivered while backgrounded.
#   f. Toggle offline in the app; confirm the notification is gone and fixes stop.

# 3. Simulate the lifecycle transitions from adb (alternative to physically locking):
adb shell input keyevent KEYCODE_HOME        # background
adb shell dumpsys activity services com.example.driver_app   # service + notification live
adb shell input keyevent KEYCODE_WAKEUP      # resume; the app re-publishes a fix on resume
adb shell dumpsys notification --noredact | grep -A2 "You're online"
```

- Only after the above pass may bug #18 be marked resolved. Play Console: record the
  background-location **declaration + justification** and the review-approval step before release.
- The Android foreground service itself is not Dart-testable; the pure-Dart seam
  (`shouldUseForegroundService`, `AppLifecycleNotifier`, `setForegroundTracking`) is unit-tested on-host.
