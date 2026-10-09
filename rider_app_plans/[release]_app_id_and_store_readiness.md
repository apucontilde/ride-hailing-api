---
tag: release
depends_on: []
status: deferred
---

# [release] Finalize applicationId + store readiness (BOTH apps)

> **DEFERRED** — do not start until the product is preparing an actual store release. Owner:
> `rider-planner` (canonical author); the driver domain **references this file** and does not duplicate
> it. Verify: `melos run analyze` + `melos run test`; the Android/iOS build and store steps are
> **UNVERIFIABLE in this WSL tree** and must be closed on the respective host (see Verification).
>
> **Why deferred:** finalizing app identities, signing, and store metadata is release-preparation work
> gated on a product release decision — not a fix for a broken landed capability. It is independent
> (`depends_on: []`) and unnumbered (no open-plan prerequisite).
>
> **CROSS-DOMAIN, authored once in the rider domain.** Landed `[map]` (STATUS.md) uses this plan's
> final id value; the driver map plan adopts the same finalized id. `driver-planner` should add an
> Open-plans row pointing at this file rather than re-authoring it.

## Goal

Both apps (`rider_app`, `driver_app`) currently ship the stock Flutter template identity
(`applicationId` / Bundle Identifier `com.example.rider_app` and `com.example.driver_app`). Before a
real store release this plan finalizes a real reverse-DNS identity per app, updates the Android/iOS
build files, aligns the shared tile `MapTileConfig.userAgentPackageName` with the chosen id, settles
signing/config, and records the store metadata. Until it lands, the tile UA package name intentionally
tracks whatever the current stock id is.

## Current state (stock identities)

- `rider_app/android/app/build.gradle.kts:8` `namespace`, `:18` `applicationId` →
  `com.example.rider_app`; iOS bundle identifiers come from the Xcode project (stock
  `com.example.riderApp` / `Runner`).
- Driver counterpart: `driver_app/android/app/build.gradle.kts` `applicationId` →
  `com.example.driver_app` (stock).
- Landed `[map]` (`shared/lib/src/map/map_tile_config.dart`) sets
  `userAgentPackageName: 'com.example.rider_app'` (driver: `com.example.driver_app`) as the current
  truthful value; the shared tile factory has no other notion of the app id.

## Scope

### 1. Finalize the reverse-DNS identity (BOTH apps)

- Choose a stable owned domain (e.g. `com.<org>.rider` / `com.<org>.driver`), avoiding `example`,
  `com.example.*`, and any placeholder.
- Apply the same identity **consistently** to Android `applicationId` + `namespace` (must match the
  Kotlin/Java package where needed), the iOS Bundle Identifier (Runner + any extensions/targets), and
  any deep-link / URL-scheme / universal-link configuration that embeds it.
- Do **not** rename the Dart package name (`rider_app`/`driver_app`) or the repo; only the shipped
  application identity.
- One commit per app (or one cross-app commit) so Android, iOS, and the tile config never diverge.

### 2. Android / iOS build files

- Android: `android/app/build.gradle.kts` `namespace`/`applicationId`; confirm no stale
  `com.example.*` remains in `AndroidManifest.xml`, `google-services.json` (if push is added), or
  `proguard`/package paths. Leave `minSdk`/`compileSdk`/`targetSdk` as the Flutter defaults (the
  location/tile plans rely on them).
- iOS: Bundle Identifier(s) in the Xcode project / `Info.plist`; associated domains/esquemas if used.
  Set at least `CFBundleDisplayName` and the marketing version.
- This plan is the owner of the identity change; the map/location manifest plans only add permissions
  and must not hardcode the id.

### 3. Interplay with the shared tile `userAgentPackageName`

- The shared `MapTileConfig.userAgentPackageName` (and the app-local `riderMapTileConfigProvider` /
  driver provider values) **must match the finalized `applicationId`** — an OSM-policy-compliant UA has
  to name the real package. Update both apps' providers in the same commit as the identity change.
- The UA app label/version (`<app>/<version> (+contact: <email>)`, see Landed `[map]`) does not change;
  only the package-name component follows the id.
- **Until this plan lands**, `userAgentPackageName` tracks the current stock id
  (`com.example.rider_app` / `com.example.driver_app`) — which is exactly what Landed `[map]` shipped.
  Do not block on this deferred plan.

### 4. Signing / build configuration

- Android: create and configure a release keystore (`key.properties`/`signingConfigs`), never commit
  secrets; confirm `flutter build appbundle --release` produces a signed artifact.
- iOS: provisioning profiles / certificates / App Store Connect app records.
- Environment/build defines: settle the release values for `API_BASE_URL`, `MAP_TILE_URL`,
  `MAP_TILE_API_KEY` (as applicable), and `APP_VERSION` (the map plan's UA version component).
- Obfuscation/symbols and any CI release job are in scope here if the release process needs them.

### 5. Store metadata

- App names, descriptions, category, content rating, privacy policy + data-safety/App Privacy
  declarations (tiles/location/contacts map to these), screenshots, and support/contact URLs.
- Play Console / App Store Connect listing records for **both** apps.
- Cross-check policy declarations owned by feature plans: background location (driver,
  `driver_app_plans/[location]_background_tracking.md`) and the tile-provider attribution
  (Landed `[map]`) must be reflected in the store data-safety forms before release.

## Out of scope

- The actual permission/manifest changes (landed in `[map]`/`[location]` — STATUS.md — and the driver
  equivalents).
- The tile provider/attribution behavior itself.
- Any API/Go change.

## Cross-domain

- **Canonical here in the rider domain.** `driver-planner` references this file for the driver
  `applicationId` and store steps; the driver does not duplicate the plan.
- Landed `[map]` depends on this plan for the final `userAgentPackageName` value and recorded the
  pre-release "placeholder must not ship" checklist alongside it (the rider provider already passes a
  real contact).
- Not a blocker for any open feature plan: until this lands, the stock ids remain the truthful values.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- Dart suites stay green (this plan mostly touches platform build files + config values).
- **UNVERIFIABLE in this WSL tree:** the Android/iOS build and store steps. On the host, close with:
  - Android: `flutter build appbundle --release`, confirm the artifact is signed and the merged
    manifest / `BuildConfig.APPLICATION_ID` show the finalized id (no `com.example.*`).
  - iOS: `flutter build ipa --release`, confirm the Bundle Identifier and signing match the App Store
    Connect record.
  - Confirm the outbound tile `User-Agent` contains the finalized package id and a real contact (no
    `tiles@example.invalid`).
  - Confirm the store listings/data-safety forms are complete for both apps.
