---
tag: map
depends_on: []
status: open
---

# [map] Android trip map is non-compliant on OSM + release build has no network (driver)

> Independent plan. Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test`
> (Linux FVM SDK — see STATUS.md Verification); the Android manifest/device symptoms are
> **UNVERIFIABLE** in this WSL tree and must be closed on an Android host (see Verification).
>
> **CROSS-DOMAIN, co-owned.** The canonical shared contract is defined in
> `rider_app_plans/[map]_android_tile_access.md` §3 and is adopted here **verbatim**; this plan does
> not re-specify it and does not keep a driver-only tile factory. The four product-owner locks
> (2026-10-06) apply to both apps: OSM-compliance now, truthful UA, fully shared tile factory
> (`shared/` gains `flutter_map`), shared attribution widget now. Tile source beyond OSM is the two
> rider deferred plans (self-host, runtime-remote) referenced below — not re-authored here.

## Goal

On Android the driver's trip map (`TripScreen`) points at
`https://tile.openstreetmap.org/...` with `userAgentPackageName: 'com.driver.app'`, which does **not**
match the real Android `applicationId` `com.example.driver_app`. Separately, an Android **release**
build has no network at all because `android.permission.INTERNET` is declared only in the
debug/profile manifests. This plan fixes both and routes the trip map through the **canonical shared
tile factory** the rider app uses, so the two apps cannot drift.

## Current state (verified)

### The single tile block (there is exactly one in the driver)

`driver_app/lib/features/trip/presentation/trip_screen.dart:16-21`:

```dart
final tripMapTileProvider = Provider<TileLayer?>((ref) {
  return TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.driver.app',
  );
});
```

`grep -rn "TileLayer|tileProvider|tile.openstreetmap|userAgentPackageName|NetworkTileProvider" driver_app/lib driver_app/test`
returns only this block (plus its consumption at `trip_screen.dart:366` and the test overrides at
`trip_screen_test.dart:97`, `home_screen_test.dart:79,294`). The driver has **no** booking map and
**no** second map — this is the whole surface. `shared/lib/src/map/` and
`driver_app/lib/core/map/` are both **absent** today (verified), so the shared symbols do not exist
yet: whichever of the two co-owned plans lands first creates them.

### Root cause 1 — `userAgentPackageName` does not match the real application id

The value is `'com.driver.app'` but the Android identity is `com.example.driver_app`
(`driver_app/android/app/build.gradle.kts:8` `namespace`, `:19` `applicationId`). `flutter_map` 7
builds its identifying header as `flutter_map ($userAgentPackageName)`
(`~/.pub-cache/hosted/pub.dev/flutter_map-7.0.2/lib/src/layer/tile_layer/tile_layer.dart:299-300`),
so OSM receives `flutter_map (com.driver.app)` — an app that does not exist. A truthful package name is
part of OSM policy compliance.

**Driver-specific note (do not copy the rider's spoofing root cause):** the rider bug is compounded by a
hardcoded spoofed desktop-Chrome `User-Agent` passed through `NetworkTileProvider(headers:)`, which
defeats `flutter_map`'s `putIfAbsent` and gets the "Access Blocked" image. The driver has **no**
`NetworkTileProvider` and **no** custom header map, so it does **not** spoof a browser — it is less
likely to be blocked today, but it is still non-compliant and will eventually be misidentified/blocked.
The fix is nevertheless the same single shared config; keeping the driver's UA truthful is required.

### Root cause 2 — Android release has no `INTERNET` permission

`driver_app/android/app/src/main/AndroidManifest.xml:1-45` declares **no** `uses-permission`. Only the
build-variant manifests add it: `src/debug/AndroidManifest.xml:6` and `src/profile/AndroidManifest.xml:6`
(`<uses-permission android:name="android.permission.INTERNET"/>`). A `flutter build apk --release`
therefore ships no network at all — no tiles, no API, no websocket. This is stock Flutter template
behaviour (INTERNET is provided by debug/profile for the tooling) but a shipping bug for an app that is
entirely network-driven. Required regardless of the tile-source choice.

### What is already available

- `flutter_map` ^7.0.2 (`driver_app/pubspec.yaml:21`), `latlong2` ^0.9.1 (`:22`).
- `ApiConfig` already reads compile-time config through `String.fromEnvironment` —
  `driver_app/lib/config.dart:2-5` (`API_BASE_URL`), so the tile key/URL follows the same precedent.
- The driver already has the nullable-provider test seam the shared factory keeps
  (`tripMapTileProvider` is a `Provider<TileLayer?>` overridden with `null` in tests so no test touches
  the network — overrides at `trip_screen_test.dart:97`, `home_screen_test.dart:79,294`).

## Canonical shared contract (adopted verbatim from `rider_app_plans/[map]_android_tile_access.md` §3)

Co-owned by the two `[map]` plans; whichever lands first creates these symbols, the other adopts them.
If any path/name/signature changes, both domains change together. **Do not re-specify or fork these.**

- **`shared/lib/src/map/map_tile_config.dart`** — pure value object, **no `flutter_map` import**:
  `class MapTileConfig`, const ctor `urlTemplate`, `userAgentPackageName`, `userAgent`,
  `attribution?`, `subdomains`, `apiKey?`; `Map<String, String> get headers;`; and
  `factory MapTileConfig.openStreetMap({required String userAgentPackageName, String urlTemplate =
  'https://tile.openstreetmap.org/{z}/{x}/{y}.png', String contact = MapTileConfig.defaultContact})`.
- **`shared/lib/src/map/map_tile_layer.dart`** — **FULLY SHARED** (imports `flutter_map`):
  `TileLayer buildMapTileLayer(MapTileConfig config);` and
  `final mapTileLayerProvider = Provider.family<TileLayer?, MapTileConfig>((ref, config) => buildMapTileLayer(config));`
  (nullable test seam).
- **`shared/lib/src/map/map_tile_attribution.dart`** — `class MapTileAttribution extends StatelessWidget`
  (`config`, `alignment = Alignment.bottomRight`).
- **Barrel** `shared/lib/ride_hailing_shared.dart` — three `export` lines, one per new file, no shims:
  ```dart
  export 'src/map/map_tile_config.dart';
  export 'src/map/map_tile_layer.dart';
  export 'src/map/map_tile_attribution.dart';
  ```
- **`shared/pubspec.yaml`** — add `flutter_map: ^7.0.2` to `dependencies`. `shared/` is **no longer
  `flutter_map`-free** (owner decision). This is an explicit exception to "shared is dependency-light";
  it does **not** relax the re-export rule (import these symbols from the barrel directly, never a shim).

### Driver-local mirror (config only — no `TileLayer` construction)

- **New** `driver_app/lib/core/map/driver_map_tile.dart`:

  ```dart
  final driverMapTileConfigProvider = Provider<MapTileConfig>((ref) {
    return MapTileConfig.openStreetMap(
      userAgentPackageName: 'com.example.driver_app', // real applicationId
      urlTemplate: ApiConfig.mapTileUrl,
      // contact: <real contact>   // owner input (defaultContact empty)
    );
  });
  ```

  This is the **only** driver-local map symbol. `MapTileConfig.apiKey` stays `null` on the OSM path; the
  two deferred plans supply it later. Do **not** re-introduce `buildDriverMapTileLayer` or
  `driverMapTileProvider` — the construction and the test seam are the shared
  `buildMapTileLayer`/`mapTileLayerProvider`.

- **Config plumbing** in `driver_app/lib/config.dart`, mirroring the rider exactly (precedent
  `API_BASE_URL` at `:2-5`):

  ```dart
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const String mapTileApiKey = String.fromEnvironment('MAP_TILE_API_KEY');
  ```

  The key is supplied at build time (CI secret / `--dart-define`), never committed and never hardcoded in
  `trip_screen.dart`; it is unused in the OSM path and is only the seam for the deferred plans.

## Scope

### 1. Release `INTERNET` permission (required, no decision)

- Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `driver_app/android/app/src/main/AndroidManifest.xml`, directly under the opening `<manifest>` tag
  (`:1`) and before `<application>` (`:2`), so it merges into every variant. Leave the debug/profile
  copies as-is (harmless duplicate; they keep the tooling contract explicit).
- This is a prerequisite for any tile source; also fixes all API/WS calls in release.

### 2. Tile source — LOCKED: OSM-compliance now (one decision across both apps)

Reuse the rider's locked decision; the driver gets no separate vote. From
`rider_app_plans/[map]_android_tile_access.md` §2:

- **Keep** `https://tile.openstreetmap.org/{z}/{x}/{y}.png` for now. **No API key.**
- **Sent UA must be truthful and contact-bearing:** `flutter_map` renders `flutter_map (com.example.driver_app)`
  from the shared config (the shared factory is the single construction path). Never a browser string.
- **Respect OSM usage limits:** no bulk/offline downloading, honour rate limiting / `Retry-After`, keep
  the default (non-aggressive) `TileLayer` concurrency, do not proxy/prefetch tiles.
- OSM attribution is mandatory — see §4.
- The two alternatives are **deferred** rider-authored plans, referenced not re-authored:
  - `rider_app_plans/[map]_self_hosted_tile_host.md` (`status: deferred`)
  - `rider_app_plans/[map]_runtime_remote_tile_config.md` (`status: deferred`)

  When either is chosen, only `MapTileConfig` values change (URL/attribution/key); the driver mirror
  and screens do not. Both must be applied **identically in both apps through the one shared config**.

### 3. Adopt the shared factory + driver-local config (ADD-only)

- **Shared (co-owned):** create/adopt `shared/lib/src/map/map_tile_config.dart`,
  `map_tile_layer.dart`, `map_tile_attribution.dart`, the three barrel `export` lines, and the
  `shared/pubspec.yaml` `flutter_map` dependency, exactly as specified in the rider plan §3.
- **Driver-local:** new `driver_app/lib/core/map/driver_map_tile.dart` with only
  `driverMapTileConfigProvider`, parameterised by the driver's real `applicationId` (`com.example.driver_app`).
- **Rewire** `trip_screen.dart:16-21` to delete the inline `TileLayer` literal and `:366` to render
  `ref.watch(mapTileLayerProvider(ref.watch(driverMapTileConfigProvider)))`; the screen no longer names a
  tile host, `userAgentPackageName`, or UA.
- **Seam rename (explicit):** the old driver-local `tripMapTileProvider` is **removed** rather than
  aliased; the seam becomes the shared `mapTileLayerProvider`. Update the three override sites
  (`trip_screen_test.dart:97`, `home_screen_test.dart:79,294`) to
  `mapTileLayerProvider.overrideWith((ref, config) => null)`. One vocabulary across both apps.

### 4. Shared attribution widget (LOCKED: add now)

- Render the shared `MapTileAttribution(config: ...)` on the driver trip map (it already renders on
  both rider maps). Fed by `MapTileConfig.attribution`; the OSM factory populates `© OpenStreetMap
  contributors`. `attribution` is nullable so a future provider with no attribution renders nothing.

### 5. Tests

- Shared `shared/test/map/map_tile_config_test.dart` and `shared/test/map/map_tile_layer_test.dart`
  (co-owned with the rider plan): assert the OSM factory never emits a browser-spoofed UA, always emits
  the truthful `userAgent` (real package id + contact) with `headers == {'User-Agent': userAgent}`, and
  that `buildMapTileLayer` takes url/package/subdomains from the config.
- Driver: update the three overrides to the shared `mapTileLayerProvider` seam and keep overriding with
  `null`, so no test attempts a tile fetch.
  `driver_app/test/features/trip/presentation/trip_screen_test.dart` and
  `driver_app/test/features/home/presentation/home_screen_test.dart` must stay green.

## Locked decisions (product owner, 2026-10-06 — shared with the rider)

1. **Tile source now:** OSM-compliance — keep `tile.openstreetmap.org`, no key.
2. **Identity:** truthful, contact-bearing UA; real `userAgentPackageName` `com.example.driver_app`.
3. **Attribution:** shared `MapTileAttribution` added now.
4. **Tile factory:** **fully shared** in `shared/lib/**`; `shared/` gains `flutter_map`; the nullable
   `mapTileLayerProvider` test seam lives in shared. No driver-only `buildDriverMapTileLayer`.
5. **Config:** compile-time `MAP_TILE_URL`/`MAP_TILE_API_KEY` via `String.fromEnvironment` in
   `driver_app/lib/config.dart`; only `driverMapTileConfigProvider` is driver-local.
6. **API key:** deferred until a hosted provider is chosen; only the `MapTileConfig.apiKey` seam lands.
7. **Deferred follow-ups:** `rider_app_plans/[map]_self_hosted_tile_host.md` and
   `rider_app_plans/[map]_runtime_remote_tile_config.md` (rider-authored, driver consumes).

## Residual questions (not blockers)

- **Real contact for the UA** (`MapTileConfig.defaultContact` is empty): the owner must supply the ops
  contact string before landing. Until then the UA is truthful but contact-less.
- **Is `applicationId` final?** `com.example.driver_app` is the stock template value. If renamed before
  release, the driver `driverMapTileConfigProvider` value and the rider's equivalent must change in the
  same shared-config commit.
- **Exact UA format** is a landing detail; the invariant is "truthful, identifying, contact-bearing,
  never a browser string".

## Out of scope

- The rider tile fix itself (`rider_app/**`), rider plans, and Go code.
- Creating or editing `shared/lib/**` and the Android manifest in this task — those are **proposed
  steps**, not edits performed here.
- Standing up tile infrastructure or fetching tile config at runtime — the two deferred rider plans.
- A caching/offline tile layer, vector tiles, or a routing-style tile proxy through the API.
- Any driver map beyond `TripScreen` — there is no other `TileLayer` in the driver.

## Cross-domain

- Canonical contract and tile-source decision: `rider_app_plans/[map]_android_tile_access.md` §2–§4.
  Driver drift to reconcile (this rewrite): the old plan (a) said `shared/` must **not** gain
  `flutter_map`, (b) kept the `TileLayer` construction app-local
  (`buildDriverMapTileLayer`/`driverMapTileProvider`), and (c) had no shared attribution widget — all
  three are now replaced by the canonical contract.
- The two deferred plans are authored once in the rider domain and consumed by reference.
- `driver_app/android/app/src/main/AndroidManifest.xml` also lacks location permissions — see the
  sibling `[location]_android_location_permission.md`.
- Background tracking is its own driver plan: `[location]_background_tracking.md`.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` / `melos run test` over `shared/` + `driver_app/` must be green (Linux FVM SDK).
- **UNVERIFIABLE in this WSL tree:** the Android symptoms themselves. The Flutter/Dart CLI is usable but
  no Android emulator/device or Gradle build is available here. On an Android host, close with:
  - `flutter build apk --release` then inspect the **merged** release manifest for
    `android.permission.INTERNET` (e.g. `./gradlew :app:processReleaseMainManifest` and read
    `app/build/intermediates/merged_manifests/release/AndroidManifest.xml`);
  - install the release APK and confirm the trip map renders (not "Access Blocked"), attribution is
    visible, and a driver can go online / receive an offer;
  - temporarily point the tile URL at a local capture endpoint or a mock to assert the outbound
    `User-Agent` is the truthful one (and carries `com.example.driver_app`), **not** a browser string and
    not `com.driver.app`.

## Open questions

- Is the driver `applicationId` final (`com.example.driver_app` is the stock template value)? If it will
  be renamed before release, the driver `userAgentPackageName`/UA strings should use the final id — and
  the rider's should use its own final id, in the one shared config.
