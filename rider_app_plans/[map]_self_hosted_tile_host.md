---
tag: map
depends_on: []
status: deferred
---

# [map] Self-hosted tile server (deferred follow-up)

> **DEFERRED** — do not start until `[map]_android_tile_access.md` has landed (the shared
> `MapTileConfig` + `buildMapTileLayer`/`mapTileLayerProvider` seam must exist). Owner:
> `rider-planner`. Verify: `melos run analyze` + `melos run test`.
>
> **CROSS-DOMAIN, authored once in the rider domain.** `driver_app_plans/[map]_android_tile_access.md`
> consumes this plan; `driver-planner` should reference this file rather than re-author it. Canonical
> shared symbols are defined in `[map]_android_tile_access.md` §3 and are **not** redefined here.

## Gate / trigger

- **Gate:** `[map]_android_tile_access.md` landed (shared tile factory + attribution widget in
  `shared/lib/src/map/**`; both apps rendering through it).
- **Trigger:** the product chooses option (c) — own infrastructure — over the OSM public host and over
  a hosted provider key.

## Goal

Replace the OSM public host (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`) with a self-hosted tile
server, so the app no longer depends on a third party's tile-usage policy, rate limits, or uptime. This
**removes the third-party policy risk entirely** and makes the OSM-specific compliance work
(truthful UA / contact, no bulk fetching) a courtesy rather than a compliance obligation.

## What changes

### 1. Stand up the tile server (infra, out of the Flutter repo)

- Choose and deploy a tile stack (e.g. OpenMapTiles/Planetiler extract + a tile server such as
  tegola / martin / tile-server-gl) for the target region(s), with storage + bandwidth provisioning.
- Decide hosting (same host as the API, a separate service, or a CDN in front).
- Health-check and a stable, HTTPS tile URL template the apps can pin.

### 2. Point the shared config at the new host (values only — no widget/code change)

- The shared symbols from `[map]_android_tile_access.md` §3 stay exactly as they are; only values
  change:
  - `MapTileConfig.urlTemplate` → the self-hosted URL template.
  - `MapTileConfig.attribution` → the self-hosted attribution text (the shared `MapTileAttribution`
    widget renders it unchanged).
  - `userAgentPackageName`/`userAgent` remain truthful (good practice even against your own server).
  - `MapTileConfig.apiKey` stays `null` unless the host is protected; if it is, supply the value
    through the existing `MAP_TILE_API_KEY` seam.
- Migration path: change `MAP_TILE_URL`'s default in `rider_app/lib/config.dart` (and the driver's
  `driver_app/lib/config.dart`) and/or add a `MapTileConfig.selfHosted(...)` factory alongside
  `MapTileConfig.openStreetMap`, then flip both apps in one shared-config commit.
- No screen edits: both maps and the attribution widget continue to consume the shared factory.

### 3. Decommission the OSM path

- After the self-hosted host is verified in production, drop the OSM URL default and any OSM-specific
  comment/rationale. Keep the truthful UA.

## Migration risks / decisions to surface

- **Region coverage:** the OSM extract is global; a self-hosted extract is only as large as imported.
  Decide the region set and the update cadence (data freshness).
- **Storage/bandwidth cost** and whether a CDN/edge cache is needed at fleet scale.
- **Vector vs raster:** if vector tiles are chosen, the map layer config changes (style layer, glyph/
  sprite endpoints) — a larger change than the raster swap and possibly a separate plan.
- **URL stability:** pin a versioned host so an infra rebuild does not silently change rendering.

## Out of scope

- The active Android tile-access fix and the shared contract (owner: `[map]_android_tile_access.md`).
- Runtime-fetched config (owner: `[map]_runtime_remote_tile_config.md`) — although the two compose
  (a self-hosted URL can be served by the runtime config).
- Vector styling, offline/caching tile layers, and API routing proxies.

## Cross-domain

- Canonical here in the rider domain; driver consumes by reference.
- If the self-hosted URL is served at runtime, this plan and
  `[map]_runtime_remote_tile_config.md` coordinate through the same `MapTileConfig`.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- Shared `map_tile_config`/`map_tile_layer` tests stay green with the new URL/attribution values.
- **UNVERIFIABLE in this WSL tree:** the self-hosted server itself. On an Android host / real infra,
  close by loading a release APK against the self-hosted host and confirming tiles + attribution render
  with no third-party requests.
