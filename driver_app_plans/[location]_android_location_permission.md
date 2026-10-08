---
tag: location
depends_on: []
status: open
---

# [location] Android location permission missing from the main manifest (driver)

> Independent plan. Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test`
> (Linux FVM SDK — see STATUS.md Verification); the Android manifest/device symptom is
> **UNVERIFIABLE** in this WSL tree and must be closed on an Android host (see Verification).
>
> **CROSS-DOMAIN:** mirrors `rider_app_plans/[location]_android_location_permission.md`; the manifest
> fix and the shared `LocationHelper` are the same in both apps.
>
> **LOCKED (product owner, 2026-10-06):** add `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` to the
> **main** manifest; add `<uses-feature android:name="android.hardware.location.gps"
> android:required="true"/>` (driver parity with the rider — see §2 for the justification and the
> accepted tradeoff); **no** `ACCESS_BACKGROUND_LOCATION` in this plan; **no** minSdk change. The
> `deniedForever` settings-deep-link UX is **deferred** (see §5). Background screen-off tracking —
> including the coupled `ACCESS_BACKGROUND_LOCATION` permission — is owned by
> `[location]_background_tracking.md`, **not** this manifest plan.

## Goal

On Android, any use of `geolocator` fails at runtime with
`"No location permissions are defined in the manifest. Make sure at least ACCESS_FINE_LOCATION or ACCESS_COARSE_LOCATION are defined in the manifest."`
because the app's **main** manifest declares neither permission. For the driver this breaks the entire
online loop: `LocationService.start()` never gets a fix, so `lastPositionProvider` stays `null`, the
online push never happens, and dispatch never sees the driver positioned. Add the permissions correctly
and settle the optional manifest entries; the permission-denied UX and the background-tracking feature
are handed off, not built here.

## Current state (verified)

### The manifest gap

`driver_app/android/app/src/main/AndroidManifest.xml:1-45` contains the `<application>` block and a
`<queries>` block only — **no `uses-permission` and no `uses-feature`**. The debug and profile manifests
declare only `INTERNET` (`src/debug/AndroidManifest.xml:6`, `src/profile/AndroidManifest.xml:6`).
`geolocator_android` reads the **merged** manifest, so a release/debug run of the driver app declares no
location permission and throws the quoted error the moment `checkPermission`/`requestPermission` is
called.

### All the driver code that triggers it

- `driver_app/lib/core/location/location_service.dart:89` — the default
  `positionStreamProvider ?? LocationHelper.getPositionStream`, i.e. `LocationService` streams through
  `geolocator` by default.
- `driver_app/lib/core/location/location_service.dart:114` — `requestPermission()` calls
  `LocationHelper.requestPermissionDetailed()` (the manifest-dependent call).
- `driver_app/lib/features/home/presentation/home_screen.dart:48-51` — on Home init the driver calls
  `service.start()` unconditionally, then `service.requestPermission()` when the permission is neither
  granted nor permanently denied.
- Shared: `shared/lib/src/utils/location_helper.dart` — `requestPermissionDetailed()` `:4-18`,
  `requestPermission()` `:20-23`, `getCurrentPosition()` `:25-35`, `getPositionStream()` `:37-44`. The
  driver imports it from the barrel (`location_service.dart:3`), not a shim.

### Android/Gradle compatibility is already satisfied

- `driver_app/pubspec.yaml:23` → `geolocator: ^13.0.2`; resolved `geolocator` 13.0.4 and
  `geolocator_android` 4.6.2 (`pubspec.lock:484,492`).
- `driver_app/android/app/build.gradle.kts` uses the Flutter defaults: `compileSdk = flutter.compileSdkVersion`
  (`:9`), `minSdk = flutter.minSdkVersion` (`:22`), `targetSdk = flutter.targetSdkVersion` (`:23`). The
  pinned Flutter SDK (`~/fvm/default`, Flutter 3.47.3) supplies `compileSdkVersion = 36`,
  `minSdkVersion = 24`, `targetSdkVersion = 36`
  (`~/fvm/default/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:23,26,34`).
- `geolocator_android` 4.6.2 inherits those and depends on
  `com.google.android.gms:play-services-location:21.2.0` + `androidx.core:core:1.13.0`, whose floors
  (minSdk 21 / compileSdk 34) are below the configured values. **No Gradle change is required**; the only
  missing piece is the manifest declarations.

### Permission UX today (driver)

- The `[online]` work already landed the denial state: `LocationService.onPermission` →
  `appPermissionProvider` (`location_service.dart:115-118,230-235`), and `home_screen.dart:200-218` renders
  a banner (`'Location access denied. Turn it on in settings to receive ride offers.'`). `deniedPermanently`
  is distinguished from granted; there is **no** `openAppSettings`/`openLocationSettings` call anywhere
  in the driver (grep) — the banner tells the user to go to settings but offers no button.
- `LocationHelper.requestPermissionDetailed()` already computes `deniedPermanently`
  (`location_helper.dart:16`), so the manifest gap is the only missing prerequisite for the banner to be
  reachable on Android. (Bug #1 in driver `STATUS.md` is marked resolved for the **state wiring**; it is
  still unreachable on Android until the manifest declares the permissions.)

## Scope

### 1. Add the required permissions (LOCKED, required)

In `driver_app/android/app/src/main/AndroidManifest.xml`, directly under the opening `<manifest>` tag
(`:1`) and before `<application>` (`:2`):

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

Both are needed: `ACCESS_COARSE_LOCATION` is the Android 12+ "approximate" grant, `ACCESS_FINE_LOCATION`
the precise one; `geolocator` accepts either. The `android` namespace is already declared on the
`<manifest>` tag (`:1`).

### 2. GPS `uses-feature` — LOCKED: `required="true"` (driver parity)

Add under `<manifest>`:

```xml
<uses-feature android:name="android.hardware.location.gps" android:required="true"/>
```

**Parity decision (explicit):** the rider locked `required="true"`
(`rider_app_plans/[location]_android_location_permission.md` §2). The driver adopts `required="true"`
as well. The justification is *stronger* for the driver than for the rider: the entire online loop is
GPS-driven (`LocationService.start()` streams `geolocator`), so a device without GPS cannot be
positioned for dispatch at all. Matching `required="true"` keeps the two manifests consistent; no
driver-specific reason to diverge was found. **Record the tradeoff:** declaring GPS required means
**Google Play may hide the app from devices it deems non-GPS** (some tablets, TV/Chromebook form
factors, emulators). Accepted. If distribution to non-GPS devices ever becomes a goal, both apps must
revisit to `required="false"` together.

### 3. `ACCESS_BACKGROUND_LOCATION` — LOCKED: not in this plan

- This **manifest** plan ships foreground-only. `ACCESS_BACKGROUND_LOCATION` alone is insufficient and
  is **not** added here. The coupled permission belongs to the separate screen-off tracking feature,
  `[location]_background_tracking.md` (`status: deferred`), which also owns the foreground-service +
  notification the permission actually requires. Adding the bare permission here would be dishonest
  (it grants nothing useful without the service) and would trigger extra Play review for no behavior.
- Note the driver's real gap that this plan does **not** fix: an online driver who backgrounds the app
  or locks the screen stops emitting fixes and ages out of dispatch's 30 s window (bug #18). That is the
  background-tracking plan's scope.

### 4. No minSdk change (LOCKED)

- None proposed — the Flutter default `minSdk 24` / `compileSdk 36` already satisfies
  `geolocator_android` 4.6.2. Do not pin a lower/broken minSdk.

### 5. `deniedForever` UX — DEFERRED (handoff)

- This plan adds **manifests only**; it does not add a settings deep-link or change `HomeScreen`'s
  denial handling. The driver already distinguishes `deniedPermanently` and renders a banner; the
  missing affordance is an "Open settings" action calling `Geolocator.openAppSettings()` /
  `openLocationSettings()` (`geolocator` 13.0.4 exposes both).
- **Owner:** deferred alongside the rider's manual-pickup handoff. The rider hands its `deniedForever`
  deep-link to `rider_app_plans/[location]_manual_pickup_fallback.md`; the driver has no separate
  manual-pickup plan, so the driver's own denied-forever affordance stays unowned until either (a) the
  background-tracking plan picks it up as part of its notification/permission UX, or (b) a small
  follow-up plan is opened. Record the handoff explicitly rather than silently shipping a message-only
  banner. The rider plan's shared `LocationHelper.requestPermissionDetailed()` already exposes
  `deniedPermanently`, so no shared-core change is needed either way.
- Do **not** build the deep-link here: this plan is the prerequisite (permissions reachable), not the
  affordance.

## Locked decisions (product owner, 2026-10-06 — shared with the rider)

1. Add `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` to the **main** manifest.
2. Add `<uses-feature android:name="android.hardware.location.gps" android:required="true"/>` (driver
   parity with the rider); accept that Play may hide the app from non-GPS devices.
3. **No** `ACCESS_BACKGROUND_LOCATION` in this plan — owned by `[location]_background_tracking.md`.
4. **No** minSdk change.
5. Defer the `deniedForever` settings deep-link (see §5); this plan is manifests-only.

## Coordination

- Cross-app: `rider_app_plans/[location]_android_location_permission.md` fixes the identical manifest
  gap in the rider app; the shared `LocationHelper` is common. Any change to `LocationHelper` (e.g. a
  `foregroundNotificationConfig` for background tracking) is a **shared** change that must coordinate
  the rider plan, `[location]_background_tracking.md`, and this plan — do not make it here.
- The driver `[online]` permission-state wiring is already landed (driver `STATUS.md` §Landed `[online]`,
  bug #1); this plan only makes it reachable on Android.
- Bug #18 (online driver goes dark when backgrounded) is owned by `[location]_background_tracking.md`.

## Cross-domain findings (report only)

- `rider_app/android/app/src/main/AndroidManifest.xml` has the same gap (owner: rider plan).
- Both apps' main manifests also lack `INTERNET` — see the sibling
  `[map]_android_tile_access.md` (driver) and the rider `[map]` plan.
- The rider plan recommends `uses-feature gps required="true"`; this driver plan matches it (no
  divergence).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` / `melos run test` must stay green (Linux FVM SDK). Widget tests cannot exercise
  the Android manifest, so a Dart-level test only covers any new denial-state affordance, not the fix.
- **UNVERIFIABLE in this WSL tree:** the Android manifest itself. On an Android host, close with:
  - `flutter build apk --release` and inspect the **merged** manifest for `ACCESS_FINE_LOCATION` +
    `ACCESS_COARSE_LOCATION` and
    `uses-feature android.hardware.location.gps android:required="true"`
    (`./gradlew :app:processReleaseMainManifest` → `app/build/intermediates/merged_manifests/release/AndroidManifest.xml`);
  - install on a device/emulator, go online, and confirm the OS permission dialog appears and fixes
    reach `PUT /driver/me/location` (no `"No location permissions are defined in the manifest"`
    exception);
  - decline and confirm the denial banner renders and the app degrades without crashing; deny-forever
    and confirm the chosen UX state;
  - confirm **no** `ACCESS_BACKGROUND_LOCATION` appears in the merged manifest (it belongs to
    `[location]_background_tracking.md`);
  - with the app **foregrounded** the driver must appear dispatchable; note that backgrounding it stops
    the fixes (expected under the foreground-only decision; the fix is the background-tracking plan).
