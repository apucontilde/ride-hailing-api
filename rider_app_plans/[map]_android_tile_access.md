---
tag: map
depends_on: []
status: open
---

# [map] Android map tiles show "Access Blocked" (OSM) + release build has no network

> Independent plan. Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test`
> (Linux FVM SDK — see STATUS.md Verification); the Android manifest/device symptoms are
> **UNVERIFIABLE** in this WSL tree and must be closed on an Android host (see Verification).
>
> **LOCKED (product owner, 2026-10-06):** OSM-compliance now (no API key, no provider); the tile
> factory is **fully shared** (`shared/` gains a `flutter_map` dependency); attribution is a shared
> widget; key handling is a deferred seam only. The two deferred follow-ups are
> `[map]_self_hosted_tile_host.md` and `[map]_runtime_remote_tile_config.md`.
>
> **CROSS-DOMAIN:** the driver plan `driver_app_plans/[map]_android_tile_access.md` MUST adopt the
> **same** shared contract defined in §3 below (co-owned). This plan is the canonical source for
> those symbols.

## Goal

On Android the rider maps (`HomeScreen` booking map and `ActiveRideScreen` live-trip map) render
OpenStreetMap's "Access Blocked" tile-usage-policy image instead of street tiles. Separately, an
Android **release** build has no network at all because `INTERNET` is declared only in the
debug/profile manifests. This plan fixes both, makes the app OSM-policy compliant now, and
de-duplicates the copy-pasted tile config into one **shared** code path used by both apps.

## Current state (verified)

### The two duplicated tile blocks

`rider_app/lib/features/home/presentation/home_screen.dart:196-205`:

```dart
TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.rider.app',
  tileProvider: NetworkTileProvider(
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
    },
  ),
),
```

`rider_app/lib/features/home/presentation/active_ride_screen.dart:476-484` is byte-for-byte the same
block (same URL, same `userAgentPackageName`, same spoofed desktop Chrome `User-Agent`). The two must
not drift; there is no shared source today.

### Root cause 1 — the spoofed desktop User-Agent wins, and OSM blocks it

`flutter_map` 7.0.2 injects its identifying header only if absent —
`~/.pub-cache/hosted/pub.dev/flutter_map-7.0.2/lib/src/layer/tile_layer/tile_layer.dart:299-300`:

```dart
this.tileProvider.headers.putIfAbsent(
    'User-Agent', () => 'flutter_map ($userAgentPackageName)');
```

Because both screens pass a `NetworkTileProvider(headers: {'User-Agent': <desktop Chrome>})`, the key
already exists (`NetworkTileProvider` stores it as final `headers`,
`.../network_tile_provider.dart:22-36`), so **`userAgentPackageName` is never sent**. OSM receives a
fake desktop-browser UA from an app. OpenStreetMap's tile usage policy forbids browser spoofing and
answers with the "Access Blocked" image. This is the confirmed mechanism; it is not a transient
outage.

### Root cause 2 — `userAgentPackageName` does not match the real application id

Even after root cause 1 is fixed the value is wrong: both screens pass `'com.rider.app'` but the Android
`applicationId` is `'com.example.rider_app'` (`rider_app/android/app/build.gradle.kts:18`; `namespace`
`:8`). A truthful package name is part of OSM policy compliance.

### Root cause 3 — Android release has no `INTERNET` permission

`rider_app/android/app/src/main/AndroidManifest.xml:1-45` declares **no** `uses-permission`. Only the
build-variant manifests add it: `src/debug/AndroidManifest.xml:6` and `src/profile/AndroidManifest.xml:6`
(`<uses-permission android:name="android.permission.INTERNET"/>`). A `flutter build apk --release`
therefore ships no network at all — no tiles, no API, no websocket. This is the stock Flutter template
behaviour (INTERNET is provided by debug/profile for the tooling) but it is a shipping bug for an
app that is entirely network-driven. Fix is required regardless of the tile-source choice.

### What is already available

- `flutter_map` ^7.0.2 (`rider_app/pubspec.yaml:41`), `latlong2` ^0.9.1 (`:42`); shared already depends
  on `flutter_riverpod` ^2.6.1 and `latlong2` (`shared/pubspec.yaml:14,19`) but **not** `flutter_map`.
- `ApiConfig` already reads compile-time config through `String.fromEnvironment` and `rider_app/lib/config.dart:2-5`
  (`API_BASE_URL`), so a tile key/URL follows the same precedent.
- The driver app has a test seam worth copying: `tripMapTileProvider` is a
  `Provider<TileLayer?>` so tests override it with `null` and never hit the network —
  `driver_app/lib/features/trip/presentation/trip_screen.dart:15-21` (overrides at
  `driver_app/test/features/trip/presentation/trip_screen_test.dart:97`,
  `driver_app/test/features/home/presentation/home_screen_test.dart:79,294`). The rider maps have no such
  seam (grep: no `TileLayer`/`tileProvider` override in `rider_app/test`).

## Scope

### 1. Release `INTERNET` permission (required, no decision)

- Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `rider_app/android/app/src/main/AndroidManifest.xml`, directly under the opening `<manifest>` tag
  (before `<application>`), so it merges into every variant. Leave the debug/profile copies as-is
  (harmless duplicate; they keep the tooling contract explicit).
- This is a prerequisite for any tile source; also fixes all API/WS calls in release.

### 2. Tile source — LOCKED: OSM-compliance now

The provider decision is closed for this plan:

- **Keep** `https://tile.openstreetmap.org/{z}/{x}/{y}.png` for now. **No API key.**
- **Remove** the spoofed desktop-Chrome `User-Agent`. Send a **truthful, identifying UA with a contact**
  (never a browser string), and use the **real `userAgentPackageName` `com.example.rider_app`**
  (`build.gradle.kts:18`, not `com.rider.app`).
- **Respect OSM usage limits:** no bulk/offline downloading, honour rate limiting / `Retry-After`,
  keep the default (non-aggressive) `TileLayer` concurrency, and do not proxy/prefetch tiles.
- OSM attribution is mandatory — see §4.

#### User-Agent format (LOCKED, product owner 2026-10-06)

The UA is **truthful, identifying, and contact-bearing**, never a browser string. Exact format:

```
<app>/<version> (+contact: <email>)
```

- rider: `rider_app/<version> (+contact: <email>)`
- driver: `driver_app/<version> (+contact: <email>)`

`<version>` is that app's own version at build time; `<email>` is a real ops contact. **The real contact
email must be supplied before landing.** Until then the shipped value is a clearly-marked placeholder,
`MapTileConfig.defaultContact = 'tiles@example.invalid'` (`.invalid` cannot receive mail) — the
placeholder **must not ship**; see the Pre-release checklist.

Rationale: this is a dev/demo-scale app; OSM's policy targets human-scale use, so compliance without a
key is acceptable until a hosted provider or self-hosting is chosen. The two alternatives are deferred
as separate plans (**not** decisions in this plan):

- `[map]_self_hosted_tile_host.md` (status: deferred) — own infra, replaces the OSM public host,
  removes third-party policy risk; includes the migration path.
- `[map]_runtime_remote_tile_config.md` (status: deferred) — tile URL/key fetched at runtime instead
  of compile-time.

**API key:** deferred until a hosted provider is chosen. Do **not** add key handling here beyond leaving
the seam — `MAP_TILE_API_KEY` is read and passed through `MapTileConfig.apiKey` (nullable, unused now),
so the deferred plans can fill it without touching screens.

### 3. Fully shared tile factory (LOCKED) + canonical contract

The tile factory is **fully shared**: the actual `TileLayer` construction moves into
`shared/lib/src/map/**` and both apps use the one code path. This deliberately makes `shared/` depend on
`flutter_map` (owner decision, recorded under Invariants). Keep the **nullable provider override** test
seam in the shared factory.

The app only *builds a `MapTileConfig`* from its compile-time config and passes it to the shared
factory; it does not construct `TileLayer`s.

#### Canonical shared contract — CROSS-DOMAIN (adopt verbatim, do NOT re-specify)

Co-owned with `driver_app_plans/[map]_android_tile_access.md`; whichever plan lands first creates these
symbols, the other adopts them. If any path/name/signature changes, both domains change together.

**`shared/lib/src/map/map_tile_config.dart`** — pure value object (no `flutter_map` import):

```dart
class MapTileConfig {
  const MapTileConfig({
    required this.urlTemplate,
    required this.userAgentPackageName,
    required this.userAgent,
    this.attribution,
    this.subdomains = const <String>[],
    this.apiKey,
  });

  /// OSM-compliant default. `userAgent` is composed truthfully as
  ///   '<appName>/<appVersion> (+contact: <contact>)'
  /// e.g. 'rider_app/1.4.0 (+contact: tiles@example.invalid)'. Never a browser string.
  factory MapTileConfig.openStreetMap({
    required String userAgentPackageName,
    required String appName,      // 'rider_app' (driver: 'driver_app')
    required String appVersion,   // this app's version at build time
    String urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    String contact = MapTileConfig.defaultContact,
  });

  final String urlTemplate;
  final String userAgentPackageName; // real applicationId, e.g. com.example.rider_app
  final String userAgent;            // '<appName>/<appVersion> (+contact: <email>)'
  final String? attribution;         // OSM/provider attribution text; null allowed
  final List<String> subdomains;
  final String? apiKey;              // null now; deferred hosted-provider seam

  /// PLACEHOLDER — a real ops contact MUST replace this before release. The
  /// `.invalid` TLD guarantees a shipped placeholder can never route mail and
  /// makes the non-compliance obvious; see the Pre-release checklist.
  static const String defaultContact = 'tiles@example.invalid';

  Map<String, String> get headers; // => {'User-Agent': userAgent}
}
```

**`shared/lib/src/map/map_tile_layer.dart`** — the ONE tile construction (imports `flutter_map`):

```dart
/// The single tile construction used by both apps.
TileLayer buildMapTileLayer(MapTileConfig config);

/// Test seam: production returns `buildMapTileLayer(config)`; tests override the
/// family with a provider returning `null` so no widget test hits the network.
final mapTileLayerProvider =
    Provider.family<TileLayer?, MapTileConfig>((ref, config) => buildMapTileLayer(config));
```

**`shared/lib/src/map/map_tile_attribution.dart`** — the shared attribution widget (fed by
`MapTileConfig.attribution`), rendered by both apps:

```dart
class MapTileAttribution extends StatelessWidget {
  const MapTileAttribution({
    super.key,
    required this.config,
    this.alignment = Alignment.bottomRight,
  });

  final MapTileConfig config;
  final Alignment alignment;
}
```

**Barrel** `shared/lib/ride_hailing_shared.dart` — add three `export` lines (one per new file, no shims):

```dart
export 'src/map/map_tile_config.dart';
export 'src/map/map_tile_layer.dart';
export 'src/map/map_tile_attribution.dart';
```

**`shared/pubspec.yaml`** — add `flutter_map: ^7.0.2` to `dependencies` (same constraint as
`rider_app/pubspec.yaml:41`). Rationale: the owner chose one shared tile code path over keeping
`shared/` `flutter_map`-free.

#### Forward note — shared background-tracking service (agreement only; do NOT design here)

A future **shared** background-tracking service (an Android foreground service that keeps an online
driver positioned when backgrounded) will live under `shared/lib/**` — e.g. `shared/lib/src/location/` —
and be exported from the barrel, so both apps use one implementation. The additive, opt-in
`LocationHelper` extension it needs (an Android `LocationSettings`/foreground-notification parameter)
is likewise a **shared-additive** change that leaves rider foreground-only behavior unchanged. It is
**owned by** `driver_app_plans/[location]_background_tracking.md` and is **not** designed or authorized
here; this plan only records that the service and its `LocationHelper` extension belong in `shared/`,
not in either app. See Cross-domain.

#### App-local (rider) — config only, no `TileLayer` construction

- **New** `rider_app/lib/core/map/rider_map_tile.dart`:

  ```dart
  final riderMapTileConfigProvider = Provider<MapTileConfig>((ref) {
    return MapTileConfig.openStreetMap(
      userAgentPackageName: 'com.example.rider_app', // real applicationId; finalized by [release]
      appName: 'rider_app',
      appVersion: ApiConfig.appVersion, // this app's version at build time
      urlTemplate: ApiConfig.mapTileUrl,
      // contact: '<real ops contact>' // MUST replace the placeholder before release
    );
  });
  ```

  When a hosted provider is later chosen, the deferred runtime/self-host plans supply `apiKey` here.
- **Rewire both screens** to watch the shared factory with the app config instead of the inline literal:
  `home_screen.dart:196-205` and `active_ride_screen.dart:476-484` become
  `const tile = ref.watch(mapTileLayerProvider(ref.watch(riderMapTileConfigProvider)));` and render
  `MapTileAttribution(config: ...)` as a `FlutterMap` child.
- **Config plumbing** in `rider_app/lib/config.dart` (mirrors the `API_BASE_URL` precedent `:2-5`):

  ```dart
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const String mapTileApiKey = String.fromEnvironment('MAP_TILE_API_KEY');
  // UA version component: '<app>/<appVersion> (+contact: ...)'. Set from the
  // release version (build define / CI) so the UA tracks the shipped build.
  static const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  ```

  The key is read at build time (`--dart-define`/CI secret), never committed, never hardcoded in a
  screen; it is unused in the OSM path and is only the seam for the deferred plans.

Driver counterpart (adopted, not specified here): `driver_app/lib/core/map/driver_map_tile.dart` with
`driverMapTileConfigProvider` using `com.example.driver_app` and `appName: 'driver_app'` (UA
`driver_app/<version> (+contact: <email>)`), plus the same `config.dart` constants.
The driver plan currently specifies app-local `buildDriverMapTileLayer`/`driverMapTileProvider` and a
`MapTileConfig` with no `flutter_map` in shared — **drift**: it must adopt the fully-shared contract
above instead.

### 4. Shared attribution widget (LOCKED: add now)

- Add `MapTileAttribution` (§3) to `shared/lib/src/map/`, fed by `MapTileConfig.attribution`, and render
  it on **both** maps (Home booking map and active-trip map), and the driver trip map.
- OSM-compliant attribution text/link is mandatory now (e.g. `© OpenStreetMap contributors`). When a
  hosted provider replaces OSM, its required attribution/logo value changes in `MapTileConfig` only.
- `MapTileConfig.attribution` is nullable so the widget can render nothing when a future config carries
  no attribution; the OSM factory populates it.

### 5. Tests

- **New** `shared/test/map/map_tile_config_test.dart` — asserts the OSM factory never emits a
  browser-spoofed UA and builds `userAgent` in the exact form
  `'<appName>/<appVersion> (+contact: <email>)'`; that `headers` is exactly `{'User-Agent': userAgent}`;
  and that `defaultContact` is the `.invalid` placeholder (so a release can assert it was replaced).
- **New** `shared/test/map/map_tile_layer_test.dart` (or extend the config test) — `buildMapTileLayer`
  produces a `TileLayer` whose `urlTemplate`/`userAgentPackageName`/`subdomains` come from the config
  and never a hardcoded browser UA.
- **Update** `rider_app/test/features/home/presentation/home_screen_test.dart` and
  `active_ride_screen_test.dart` to override `mapTileLayerProvider.overrideWith((ref, config) => null)`
  (the driver pattern) so no test attempts a tile fetch.
- Existing map/route tests must stay green.

## Locked decisions (product owner, 2026-10-06)

1. **Tile source now:** OSM-compliance — keep `tile.openstreetmap.org`, no key.
2. **Identity:** remove the spoofed desktop `User-Agent`; send a truthful UA in the exact form
   `<app>/<version> (+contact: <email>)` (rider `rider_app/<version> …`, driver `driver_app/<version> …`);
   use `userAgentPackageName: 'com.example.rider_app'` (finalized by
   `[release]_app_id_and_store_readiness.md`).
3. **Attribution:** add the shared widget **now**.
4. **Tile factory:** **fully shared** in `shared/lib/**`; `shared/` gains `flutter_map`; keep the
   nullable provider test seam in the shared factory.
5. **Config location:** compile-time `MAP_TILE_URL`/`MAP_TILE_API_KEY` via `String.fromEnvironment` in
   `rider_app/lib/config.dart` (the runtime-remote alternative is deferred).
6. **API key:** deferred until a hosted provider is chosen; only the `MapTileConfig.apiKey` seam lands.
7. **Deferred follow-ups:** self-hosted tile server and runtime-fetched remote tile config (separate
   plan files, `status: deferred`).
8. **UA contact:** ships as the clearly-marked placeholder `MapTileConfig.defaultContact =
   'tiles@example.invalid'`; the real email must be supplied before release and **must not ship the
   placeholder** (see Pre-release checklist).
9. **`applicationId`:** finalization deferred to `[release]_app_id_and_store_readiness.md`; until it
   lands `userAgentPackageName` tracks the stock `com.example.rider_app` (driver `com.example.driver_app`).

## Pre-release checklist (LOCKED 2026-10-06)

- [ ] **Replace the UA contact placeholder.** `MapTileConfig.defaultContact` ships as
      `tiles@example.invalid`; supply the real ops contact (set `contact:` in
      `riderMapTileConfigProvider` and the driver provider, or override the default). A `.invalid` TLD
      cannot receive mail, so shipping it makes the UA non-contact-bearing and OSM-policy non-compliant.
- [ ] **Confirm the real `applicationId`.** `userAgentPackageName` must equal the finalized reverse-DNS
      id produced by `[release]_app_id_and_store_readiness.md`; until then it tracks the stock
      `com.example.rider_app` / `com.example.driver_app`.

## Residual questions

- **The real contact email is still needed** (owner input). The plan ships the clearly-marked placeholder
  `tiles@example.invalid`; see the Pre-release checklist. Until it is replaced the UA is truthful and
  identifying but not deliverable.
- **`applicationId` finalization is deferred** to `[release]_app_id_and_store_readiness.md`. When the id
  changes, the shared config's `userAgentPackageName` and the app-local provider values change on both
  apps in the same commit.

## Out of scope

- Driver-app tile fix code itself (owner: `driver-planner`); this plan only defines the shared contract
  the driver adopts.
- Standing up tile infrastructure or fetching tile config at runtime — those are the two deferred plans.
- A caching/offline tile layer, vector tiles, or a routing-style proxy through the API.

## Cross-domain

- **CROSS-DOMAIN, co-owned:** the shared contract in §3. `driver-planner` owns
  `driver_app_plans/[map]_android_tile_access.md` and the driver-local `driverMapTileConfigProvider`;
  this plan owns the shared symbols and the rider config/screens. The driver Mainifest `INTERNET` +
  location gaps are the driver's.
- **Driver drift to reconcile (report only here):** the driver plan currently (a) says `shared/` must
  **not** gain `flutter_map`, (b) keeps the `TileLayer` construction app-local
  (`buildDriverMapTileLayer`/`driverMapTileProvider`), and (c) has no shared attribution widget. The
  locked decision reverses all three; `driver-planner` must update its plan to the §3 contract.
- The two deferred plans (`[map]_self_hosted_tile_host.md`, `[map]_runtime_remote_tile_config.md`) are
  authored once in the **rider domain** as canonical and referenced by both domains. The driver plans do
  not duplicate them; `driver-planner` should add Open-plans rows pointing at these files.
- **CROSS-DOMAIN:** `[release]_app_id_and_store_readiness.md` is the canonical owner of the final
  reverse-DNS `applicationId`; this plan depends on it for the `userAgentPackageName` value. Both apps
  adopt the same finalized id.
- **Shared background tracking (agreement, not design):** the driver's "goes dark when backgrounded"
  feature is owned by `driver_app_plans/[location]_background_tracking.md`, but the service itself — and
  the additive `LocationHelper` extension it needs — lives in **shared** (`shared/lib/src/location/`,
  barrel-exported) so both apps share one implementation. This plan does not design it; both domains
  agree it is a shared artifact, not an app-local one. Rider behavior stays foreground-only (no
  `ACCESS_BACKGROUND_LOCATION`, per `[location]_android_location_permission.md`).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` / `melos run test` over `shared/` + `rider_app/` must be green (Linux FVM SDK).
- **UNVERIFIABLE in this WSL tree:** the Android symptoms themselves. The Flutter/Dart CLI is usable but
  no Android emulator/device or Gradle build is available here. On an Android host, close with:
  - `flutter build apk --release` then inspect the **merged** release manifest for
    `android.permission.INTERNET` (e.g. `./gradlew :app:processReleaseMainManifest` and read
    `app/build/intermediates/merged_manifests/release/AndroidManifest.xml`);
  - install the release APK and confirm tiles render (not "Access Blocked"), attribution is visible,
    and a ride request reaches the API;
  - temporarily point the tile URL at a local capture endpoint or a mock to assert the outbound
    `User-Agent` is exactly `<app>/<version> (+contact: <real email>)` and **not** the desktop Chrome
    string, that `com.example.rider_app` (not `com.rider.app`) is what is sent, and that the shipped UA
    does **not** contain the `tiles@example.invalid` placeholder.
