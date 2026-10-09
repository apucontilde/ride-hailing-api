---
tag: map
depends_on: ["landed [map] shared tile contract (rider_app_plans/STATUS.md)"]
status: open
---

# [map] Android trip map is non-compliant on OSM + release build has no network (driver)

> Independent plan. Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test`
> (Linux FVM SDK — see STATUS.md Verification); the Android manifest/device symptoms are
> **UNVERIFIABLE** in this WSL tree and must be closed on an Android host (see Verification).
>
> **CROSS-DOMAIN, co-owned.** The canonical shared tile contract is now **landed** as the `[map]`
> capability — canonical owner: `rider_app_plans/STATUS.md` → Landed `[map]`; code
> `shared/lib/src/map/map_tile_config.dart:21`, `shared/lib/src/map/map_tile_layer.dart:10,21`,
> `shared/lib/src/map/map_tile_attribution.dart:8`. This plan adopts it **verbatim**; it does not
> re-specify the shared symbols and does not keep a driver-only tile factory. The four product-owner
> locks (2026-10-06) apply to both apps: OSM-compliance now, truthful UA, fully shared tile factory
> (`shared/` gains `flutter_map`), shared attribution widget now. Tile source beyond OSM is the two
> deferred rider plans (self-host, runtime-remote) referenced below — not re-authored here.

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
returns only this block (plus its consumption at
`trip_screen.dart:366` and the test overrides at
`trip_screen_test.dart:99`, `home_screen_test.dart:79,294`). The driver has **no** booking map and
**no** second map — this is the whole surface. The shared contract now exists in code
(`shared/lib/src/map/map_tile_config.dart`, `map_tile_layer.dart`, `map_tile_attribution.dart`; barrel
exports `shared/lib/ride_hailing_shared.dart:27-29`; `shared/pubspec.yaml:19`), so only
`driver_app/lib/core/map/` is still absent: this plan adds the driver-local config and rewires the
trip map.

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
  the network — overrides at `trip_screen_test.dart:99`, `home_screen_test.dart:79,294`).

## Canonical shared contract (landed `[map]` capability — `rider_app_plans/STATUS.md` → Landed `[map]`)

Already landed in `shared/`; the driver **consumes** it — do not re-create or fork it. If any
path/name/signature changes, both domains change together. **Do not re-specify these symbols.**

- **`shared/lib/src/map/map_tile_config.dart`** — pure value object, **no `flutter_map` import**
  (`class MapTileConfig` `:7`): const ctor `urlTemplate`, `userAgentPackageName`, `userAgent`,
  `attribution?`, `subdomains = const <String>[]`, `apiKey?`; `Map<String, String> get headers`
  (`:61`); `static const String defaultContact = 'tiles@example.invalid'` (`:59`); and the OSM
  factory (`:21`) `MapTileConfig.openStreetMap({required String userAgentPackageName, required String
  appName, required String appVersion, String urlTemplate =
  'https://tile.openstreetmap.org/{z}/{x}/{y}.png', String contact = MapTileConfig.defaultContact,
  String? apiKey})` — composing `userAgent = '<appName>/<appVersion> (+contact: <contact>)'` and
  `attribution = '© OpenStreetMap contributors'`.
- **`shared/lib/src/map/map_tile_layer.dart`** — **FULLY SHARED** (imports `flutter_map`):
  `TileLayer buildMapTileLayer(MapTileConfig config)` (`:10`; passes
  `NetworkTileProvider(headers: config.headers)` so the config's truthful UA wins over flutter_map's
  `putIfAbsent` default) and
  `final mapTileLayerProvider = Provider.family<TileLayer?, MapTileConfig>((ref, config) => buildMapTileLayer(config));`
  (`:21`; nullable test seam).
- **`shared/lib/src/map/map_tile_attribution.dart`** — `class MapTileAttribution extends StatelessWidget`
  (`:8`; `config`, `alignment = Alignment.bottomRight`; renders nothing when `attribution == null`).
- **Barrel** `shared/lib/ride_hailing_shared.dart:27-29` — three `export` lines, one per new file, no shims:
  ```dart
  export 'src/map/map_tile_config.dart';
  export 'src/map/map_tile_layer.dart';
  export 'src/map/map_tile_attribution.dart';
  ```
- **`shared/pubspec.yaml:19`** — `flutter_map: ^7.0.2`. `shared/` is **no longer `flutter_map`-free**
  (owner decision). This is an explicit exception to "shared is dependency-light"; it does **not**
  relax the re-export rule (import these symbols from the barrel directly, never a shim).

### Driver-local mirror (config only — no `TileLayer` construction)

- **New** `driver_app/lib/core/map/driver_map_tile.dart` (mirrors the landed rider
  `rider_app/lib/core/map/rider_map_tile.dart`):

  ```dart
  final driverMapTileConfigProvider = Provider<MapTileConfig>((ref) {
    return MapTileConfig.openStreetMap(
      userAgentPackageName: 'com.example.driver_app', // real applicationId
      appName: 'driver_app',
      appVersion: ApiConfig.appVersion,               // '1.0.0' default / APP_VERSION define
      urlTemplate: ApiConfig.mapTileUrl,
      contact: 'ricardoapuch@gmail.com',
      apiKey: ApiConfig.mapTileApiKey.isEmpty ? null : ApiConfig.mapTileApiKey,
    );
  });
  ```

  This is the **only** driver-local map symbol. The composed UA is
  `driver_app/<appVersion> (+contact: ricardoapuch@gmail.com)`, sent via the shared factory's
  `NetworkTileProvider(headers:)`. `MapTileConfig.apiKey` is `null` on the OSM path; the two deferred
  plans supply it later. Do **not** add a driver-local `TileLayer` factory or tile provider — the
  construction and the test seam are the shared `buildMapTileLayer`/`mapTileLayerProvider`.

- **Config plumbing** in `driver_app/lib/config.dart`, mirroring the rider exactly (precedent
  `API_BASE_URL` at `:2-5`; the existing `appVersion` at `:16` becomes the `APP_VERSION` define):

  ```dart
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const String mapTileApiKey = String.fromEnvironment('MAP_TILE_API_KEY');
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
  ```

  `mapTileApiKey` and `appVersion` are supplied at build time (CI secret / `--dart-define`), never
  committed and never hardcoded in `trip_screen.dart`; the key is unused on the OSM path and is only the
  seam for the deferred plans.

## Scope

### 1. Release `INTERNET` permission (required, no decision)

- Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `driver_app/android/app/src/main/AndroidManifest.xml`, directly under the opening `<manifest>` tag
  (`:1`) and before `<application>` (`:2`), so it merges into every variant. Leave the debug/profile
  copies as-is (harmless duplicate; they keep the tooling contract explicit).
- This is a prerequisite for any tile source; also fixes all API/WS calls in release.

### 2. Tile source — LOCKED: OSM-compliance now (one decision across both apps)

Reuse the rider's locked decision; the driver gets no separate vote. From the landed `[map]`
capability (`rider_app_plans/STATUS.md` → Landed `[map]`):

- **Keep** `https://tile.openstreetmap.org/{z}/{x}/{y}.png` for now. **No API key.**
- **Sent UA must be truthful and contact-bearing:** the shared factory sends
  `driver_app/<appVersion> (+contact: ricardoapuch@gmail.com)` via `NetworkTileProvider(headers:)`
  (the shared factory is the single construction path). Never a browser string.
- **Respect OSM usage limits:** no bulk/offline downloading, honour rate limiting / `Retry-After`, keep
  the default (non-aggressive) `TileLayer` concurrency, do not proxy/prefetch tiles.
- OSM attribution is mandatory — see §4.
- The two alternatives are **deferred** rider-authored plans, referenced not re-authored:
  - `rider_app_plans/[map]_self_hosted_tile_host.md` (`status: deferred`)
  - `rider_app_plans/[map]_runtime_remote_tile_config.md` (`status: deferred`)

  When either is chosen, only `MapTileConfig` values change (URL/attribution/key); the driver mirror
  and screens do not. Both must be applied **identically in both apps through the one shared config**.

### 3. Adopt the shared factory + driver-local config (ADD-only)

- **Shared (already landed):** `shared/lib/src/map/map_tile_config.dart`, `map_tile_layer.dart`,
  `map_tile_attribution.dart`, the three barrel `export` lines (`shared/lib/ride_hailing_shared.dart:27-29`),
  and the `shared/pubspec.yaml:19` `flutter_map` dependency are all present — **consume, do not create**.
- **Driver-local:** new `driver_app/lib/core/map/driver_map_tile.dart` with only
  `driverMapTileConfigProvider`, parameterised by the driver's real `applicationId`
  (`com.example.driver_app`), `appName: 'driver_app'`, `appVersion: ApiConfig.appVersion`,
  `contact: 'ricardoapuch@gmail.com'`.
- **Rewire** `trip_screen.dart:16-21` to delete the inline `TileLayer` literal and `:366` to render
  `ref.watch(mapTileLayerProvider(ref.watch(driverMapTileConfigProvider)))`; the screen no longer names a
  tile host, `userAgentPackageName`, or UA.
- **Seam rename (explicit):** the old driver-local `tripMapTileProvider` is **removed** rather than
  aliased; the seam becomes the shared `mapTileLayerProvider`. Update the three override sites
  (`trip_screen_test.dart:99`, `home_screen_test.dart:79,294`) to
  `mapTileLayerProvider.overrideWith((ref, config) => null)`. One vocabulary across both apps.

### 4. Shared attribution widget (LOCKED: add now)

- Render the shared `MapTileAttribution(config: ...)` on the driver trip map (it already renders on
  both rider maps — `rider_app/lib/features/home/presentation/home_screen.dart:490` and
  `active_ride_screen.dart:542`). Fed by `MapTileConfig.attribution`; the OSM factory populates
  `© OpenStreetMap contributors`. `attribution` is nullable so a future provider with no attribution
  renders nothing.

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
   `mapTileLayerProvider` test seam lives in shared. No driver-local `TileLayer` factory.
5. **Config:** compile-time `MAP_TILE_URL`/`MAP_TILE_API_KEY`/`APP_VERSION` via `String.fromEnvironment`
   in `driver_app/lib/config.dart`; only `driverMapTileConfigProvider` is driver-local.
6. **API key:** deferred until a hosted provider is chosen; only the `MapTileConfig.apiKey` seam lands.
7. **Deferred follow-ups:** `rider_app_plans/[map]_self_hosted_tile_host.md` and
   `rider_app_plans/[map]_runtime_remote_tile_config.md` (rider-authored, driver consumes).

## Residual questions (not blockers)

- **Contact string:** the driver passes the owner-supplied `'ricardoapuch@gmail.com'`. The shared
  `MapTileConfig.defaultContact` is the placeholder `'tiles@example.invalid'`
  (`shared/lib/src/map/map_tile_config.dart:59`) and must not ship.
- **Is `applicationId` final?** `com.example.driver_app` is the stock template value. If renamed before
  release, the driver `driverMapTileConfigProvider` value and the rider's equivalent must change in the
  same shared-config commit.
- **Exact UA format** is a landing detail; the invariant is "truthful, identifying, contact-bearing,
  never a browser string".

## Out of scope

- The rider tile fix itself (`rider_app/**`), rider plans, and Go code.
- Editing the now-landed `shared/lib/**` contract, and the Android manifest in this task — the manifest
  edit is a **proposed step**, not an edit performed here; the shared contract is consumed as-is.
- Standing up tile infrastructure or fetching tile config at runtime — the two deferred rider plans.
- A caching/offline tile layer, vector tiles, or a routing-style tile proxy through the API.
- Any driver map beyond `TripScreen` — there is no other `TileLayer` in the driver.

## Cross-domain

- Canonical contract and tile-source decision: the landed `[map]` capability
  (`rider_app_plans/STATUS.md` → Landed `[map]`; code `shared/lib/src/map/`). The earlier driver plan
  said `shared/` must **not** gain `flutter_map`, kept the `TileLayer` construction app-local, and had
  no shared attribution widget — all three are superseded by the now-landed shared contract.
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
    `User-Agent` is the truthful `driver_app/<appVersion> (+contact: ricardoapuch@gmail.com)`, **not** a
    browser string and not `com.driver.app`.

## Open questions

- Is the driver `applicationId` final (`com.example.driver_app` is the stock template value)? If it will
  be renamed before release, the driver `userAgentPackageName`/UA strings should use the final id — and
  the rider's should use its own final id, in the one shared config.
