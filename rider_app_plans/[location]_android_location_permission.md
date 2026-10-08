---
tag: location
depends_on: []
status: open
---

# [location] Android location permission missing from the main manifest

> Independent plan. Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test`
> (Linux FVM SDK — see STATUS.md Verification); the Android manifest/device symptom is
> **UNVERIFIABLE** in this WSL tree and must be closed on an Android host (see Verification).
>
> **LOCKED (product owner, 2026-10-06):** add `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` to the
> **main** manifest; add `<uses-feature android:name="android.hardware.location.gps"
> android:required="true"/>`; **no** `ACCESS_BACKGROUND_LOCATION`; **no** minSdk change. The
> `deniedForever` settings deep-link UI was **handed off** to the `[location]` fallback, which has
> since landed (`rider_app_plans/STATUS.md` → Landed `[location]`); this plan ships manifests only.

## Goal

On Android, any use of `geolocator` fails at runtime with
`"No location permissions are defined in the manifest. Make sure at least ACCESS_FINE_LOCATION or ACCESS_COARSE_LOCATION are defined in the manifest."`
because the app's **main** manifest declares neither permission. This breaks the device fix on Home,
the rider-location ping, and the live-trip position stream. Add the permissions correctly and settle the
optional manifest entries; the permission-denied UX is handed off, not built here.

## Current state (verified)

### The manifest gap

`rider_app/android/app/src/main/AndroidManifest.xml:1-45` contains the `<application>` block and a
`<queries>` block only — **no `uses-permission` and no `uses-feature`**. The debug and profile
manifests declare only `INTERNET`
(`src/debug/AndroidManifest.xml:6`, `src/profile/AndroidManifest.xml:6`). `geolocator_android` reads
the **merged** manifest, so a release/debug run of the rider app declares no location permission and
throws the quoted error the moment `checkPermission`/`requestPermission` is called.

### All the code that triggers it

`shared/lib/src/utils/location_helper.dart`:
- `requestPermissionDetailed()` `:4-18` — `Geolocator.isLocationServiceEnabled()` `:5` then
  `checkPermission()`/`requestPermission()` `:10-13`, mapping `deniedForever` at `:16`.
- `requestPermission()` `:20-23` (bool-only wrapper), `getCurrentPosition()` `:25-35`,
  `getPositionStream()` `:37-44`.

Callers (rider):
- `rider_app/lib/features/home/presentation/home_screen.dart:147-172` (`_initLocation`) calls
  `requestPermission()` at `:148` and `getCurrentPosition()` at `:161`.
- `rider_app/lib/features/home/presentation/active_ride_screen.dart:99` subscribes to
  `LocationHelper.getPositionStream()`.
- `rider_app/lib/features/home/data/location_ping_service.dart:15` and
  `rider_app/lib/features/home/data/security_provider.dart:28` take injectable position
  functions that default to `LocationHelper`.
- The rider shim re-exports the class: `rider_app/lib/core/utils/location_helper.dart:1`.

### Android/Gradle compatibility is already satisfied

- `rider_app/pubspec.yaml:43` → `geolocator: ^13.0.2`; resolved `geolocator` 13.0.4 and
  `geolocator_android` 4.6.2 (`pubspec.lock:484,492`).
- `rider_app/android/app/build.gradle.kts` uses the Flutter defaults: `compileSdk = flutter.compileSdkVersion`
  (`:9`), `minSdk = flutter.minSdkVersion` (`:19`), `targetSdk = flutter.targetSdkVersion` (`:20`).
  The pinned Flutter SDK (`~/fvm/default`, Flutter 3.47.3) supplies `compileSdkVersion = 36`,
  `minSdkVersion = 24`, `targetSdkVersion = 36`
  (`~/fvm/default/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:23,26,34`).
- `geolocator_android` 4.6.2 inherits those (`.../geolocator_android-4.6.2/android/build.gradle:29,32`)
  and depends on `com.google.android.gms:play-services-location:21.2.0` + `androidx.core:core:1.13.0`,
  whose floors (minSdk 21 / compileSdk 34) are below the configured values. **No Gradle change is
  required**; the only missing piece is the manifest declarations.

### Permission UX today

- On denial `home_screen.dart:147-159` only shows a transient SnackBar
  `'Location permission is required to request rides'` and returns; it shows nothing different for
  `deniedForever`, and there is no route to system settings. Grep confirms no
  `openAppSettings`/`openLocationSettings` anywhere in the rider app.
- `LocationHelper.requestPermissionDetailed()` already computes `deniedPermanently`
  (`location_helper.dart:16`) but `HomeScreen` calls the bool-only `requestPermission()` (`:148`) and
  discards the distinction. `Geolocator.openAppSettings()` / `openLocationSettings()` are available
  (`geolocator` 13.0.4 `lib/geolocator.dart:233-241`); `url_launcher` ^6.3.1 is also a rider dep
  (`pubspec.yaml:44`).
- The `deniedForever` deep-link UI is owned by the since-landed `[location]` fallback
  (`rider_app_plans/STATUS.md` → Landed `[location]`; see Handoff below). This plan does **not** build it.

## Scope

### 1. Add the required permissions (LOCKED, required)

In `rider_app/android/app/src/main/AndroidManifest.xml`, directly under the opening `<manifest>` tag
and before `<application>`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

Both are needed: `ACCESS_COARSE_LOCATION` is the Android 12+ "approximate" grant, `ACCESS_FINE_LOCATION`
the precise one; `geolocator` accepts either (`denied`/`whileInUse`/`always`/`deniedForever`). Ensure
the `android` namespace is already declared on the `<manifest>` tag (it is, `:1`).

### 2. GPS `uses-feature` (LOCKED: `required="true"`)

Add under `<manifest>`:

```xml
<uses-feature android:name="android.hardware.location.gps" android:required="true"/>
```

**Record the tradeoff:** the owner chose `required="true"` (overriding the earlier
`required="false"` recommendation). This declares the app as requiring GPS hardware, so **Google Play
may hide the app from devices it deems non-GPS** (some tablets, TV/Chromebook form factors, emulators).
That is accepted: the app's core flow (device fix, rider-location ping, live-trip stream) needs a GPS
fix. If distribution to non-GPS devices becomes a goal, revisit this to `required="false"`.

### 3. `ACCESS_BACKGROUND_LOCATION` — LOCKED: do not add

- The app only reads location while the UI is foregrounded: `LocationPingService` is stopped on
  `AppLifecycleState.paused/inactive` (`home_screen.dart:67-74`) and the active-trip stream is bound to
  the screen lifecycle. On Android 10+ background location triggers extra Play Store review and a
  separate prompt. Do **not** add it.
- The driver's screen-off dispatchability is a **driver-domain** feature (foreground service +
  notification), not this manifest plan; the rider plan does not add background location for it.

### 4. No minSdk change (LOCKED)

- None proposed — the Flutter default `minSdk 24` / `compileSdk 36` already satisfies
  `geolocator_android` 4.6.2. Do not pin a lower/broken minSdk.

### 5. `deniedForever` UX — DEFERRED (handoff)

- This plan adds **manifests only**; it does not add the settings deep-link or change `HomeScreen`'s
  denial handling.
- The UI is owned by the now-landed `[location]` fallback (`rider_app_plans/STATUS.md` → Landed
  `[location]`), which shipped: a `LocationService`/`LocationAvailability` seam, a persistent notice,
  and `Geolocator.openAppSettings()` (permanently denied) / `openLocationSettings()` (services off).
  `LocationHelper.requestPermissionDetailed()` already exposes `deniedPermanently`
  (`location_helper.dart:16`), so no shared-core change is needed.
- On landing this plan, update the Known-bugs row / Open-plans note so the manual-pickup plan is the
  single owner of the deep-link affordance (no competing implementation).

## Locked decisions (product owner, 2026-10-06)

1. Add `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` to the **main** manifest.
2. Add `<uses-feature android:name="android.hardware.location.gps" android:required="true"/>`; accept
   that Play may hide the app from non-GPS devices.
3. **No** `ACCESS_BACKGROUND_LOCATION`.
4. **No** minSdk change.
5. Hand the `deniedForever` settings deep-link UI to the `[location]` fallback (since landed —
   STATUS.md → Landed `[location]`); this plan is manifests-only and records the handoff.

## Handoff

- The `[location]` fallback (landed; `rider_app_plans/STATUS.md` → Landed `[location]`) owns the
  `deniedForever` settings deep-link. Neither plan depended on the other's *open* status; they met
  only at the deferred affordance. This plan must not implement it.
- Cross-app: `driver_app_plans/[location]_android_location_permission.md` (owner: `driver-planner`) has
  the same manifest gap and additionally owns the driver-specific background-location question. The
  shared `LocationHelper` is common: any change to it (e.g. a `foregroundNotificationConfig`) is a
  shared change that must coordinate both plans and is **not** made here.

## Cross-domain findings (report only — do NOT create driver plans)

- `driver_app/android/app/src/main/AndroidManifest.xml:1-45` also declares **no location
  permissions**, yet the driver app uses `LocationHelper` via
  `driver_app/lib/core/location/location_service.dart` (see `driver_app_plans/STATUS.md` Landed
  `[online]`). The same geolocator crash will occur on Android in the driver app.
- **Drift to reconcile (report only):** the driver plan currently recommends
  `android.hardware.location.gps` with `required="false"`; the owner's locked decision here is
  `required="true"`. Whether the driver adopts `required="true"` is `driver-planner`'s call (the
  `uses-feature` value is per-app manifest, not a shared code symbol); flag the inconsistency rather
  than silently diverging.
- The driver main manifest likewise lacks `INTERNET` (see `[map]_android_tile_access.md`).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` / `melos run test` must stay green (Linux FVM SDK). Widget tests cannot exercise
  the Android manifest, so a Dart-level test only covers any new denial-state mapping, not the fix.
- **UNVERIFIABLE in this WSL tree:** the Android manifest itself. On an Android host, close with:
  - `flutter build apk --release` and inspect the **merged** manifest for
    `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` and
    `uses-feature android:hardware.location.gps android:required="true"`
    (`./gradlew :app:processReleaseMainManifest` → `app/build/intermediates/merged_manifests/release/AndroidManifest.xml`);
  - install on a device/emulator, open Home, and confirm the OS permission dialog appears and a fix is
    obtained (no `"No location permissions are defined in the manifest"` exception);
  - decline and confirm the app degrades without crashing (the deep-link UX is out of scope here);
  - confirm no `ACCESS_BACKGROUND_LOCATION` appears in the merged manifest.
