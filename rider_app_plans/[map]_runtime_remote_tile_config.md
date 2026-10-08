---
tag: map
depends_on: []
status: deferred
---

# [map] Runtime-fetched remote tile config (deferred follow-up)

> **DEFERRED** — do not start until `[map]_android_tile_access.md` has landed (the shared
> `MapTileConfig` factory + `mapTileLayerProvider` seam must exist). Owner: `rider-planner`. Verify:
> `melos run analyze` + `melos run test`.
>
> **CROSS-DOMAIN, authored once in the rider domain.** `driver_app_plans/[map]_android_tile_access.md`
> consumes this plan; `driver-planner` should reference this file rather than re-author it. Canonical
> shared symbols are defined in `[map]_android_tile_access.md` §3 and are **not** redefined here.

## Gate / trigger

- **Gate:** `[map]_android_tile_access.md` landed (shared tile factory + attribution widget; apps feed
  a `MapTileConfig`).
- **Trigger:** the product wants to change the tile URL / provider / key **without rebuilding and
  re-releasing** the apps (e.g. switching hosted provider, rotating a key, or pointing at the
  self-hosted server).

## Goal

Replace the compile-time `MAP_TILE_URL`/`MAP_TILE_API_KEY` (`String.fromEnvironment`, read in
`rider_app/lib/config.dart`) with a **runtime-fetched** tile configuration, so the active tile source
can change server-side. The shared `MapTileConfig` contract and the shared tile factory stay the same —
only *where the config comes from* changes.

## Scope

### 1. Serve the config remotely (API contract UNSPECIFIED — deferred, not a prerequisite)

- The tile config must be served from somewhere (a read-only API endpoint, a static CDN/config file, or
  another host) shaped to build a `MapTileConfig`:
  `{ "url": "...", "attribution": "...", "key": null, ... }`.
- **The endpoint owner and response shape are UNSPECIFIED and are not a prerequisite for this plan.**
  This is an open question to resolve only when this work is actually scheduled — it is **not** a
  requirement imposed on `api_plans` now. When scheduled, confirm the owner and the shape before
  implementing. The compile-time defaults plus the last-good-cache fallback below work regardless.

### 2. App-side consumption (rider; driver mirrors)

- Turn the config provider into an async one (e.g.
  `riderMapTileConfigProvider = FutureProvider<MapTileConfig>` or a notifier) that:
  - returns a **compile-time fallback** `MapTileConfig` immediately so the map always renders (never a
    blank map on a config-fetch failure);
  - fetches the remote config in the background and swaps in the remote value when it arrives;
  - caches the last-good config (session or persistent) and validates it (non-empty URL, attribution);
  - never logs the key.
- Screens consume the same shared `mapTileLayerProvider` — no screen change beyond how the config
  provider resolves.
- The compile-time constants remain the fallback and the offline default.

### 3. Key handling (only if a hosted provider is chosen)

- The remote config may carry the provider key; if so, it is delivered over HTTPS and kept in memory
  only. This is the seam the active plan left (`MapTileConfig.apiKey`) and the deferred self-host plan
  can use.

## Failure modes to keep honest

- **Config fetch fails / is malformed:** keep the last-good or compile-time fallback; do **not** blank
  the map and do not treat a config outage as a tile outage.
- **Provider switches under the user mid-session:** map tiles may mix two providers briefly; acceptable,
  but prefer applying on next map open.
- **Downgrade:** if the fetched URL is invalid, reject it and keep the fallback.
- **Caching:** a stale cached URL pointing at a dead host must be recoverable (retry/fetch on next open).

## Out of scope

- The active Android tile-access fix and the shared contract (owner: `[map]_android_tile_access.md`).
- Standing up tile infrastructure (owner: `[map]_self_hosted_tile_host.md`); this plan can *serve* the
  self-hosted URL but does not create it.
- Any remote-config API endpoint — owner and shape are UNSPECIFIED; an open question to raise only when
  this work is scheduled (see §1), not a designed prerequisite.
- Offline tile caching / vector styling.

## Cross-domain

- Canonical here in the rider domain; driver consumes by reference.
- If a remote endpoint is chosen, coordinating its owner/shape with `api-plans` is an open question to
  raise when this work is scheduled — it is **not** a designed prerequisite (see §1). The driver half
  coordinates with `driver-planner`.
- The **self-host** and **runtime-remote-config** deferred plans are alternative/composable paths over
  the same shared `MapTileConfig`; they share the `map` tag and are siblings, not a chain.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- Add tests for: fallback config used when the fetch fails; remote config applied when valid; malformed
  response rejected; key never rendered/logged. Keep the shared `map_tile_config` tests green.
- **UNVERIFIABLE in this WSL tree:** the end-to-end runtime swap on a device; close on an Android host
  by toggling the served config and confirming the displayed host changes without a rebuild.
