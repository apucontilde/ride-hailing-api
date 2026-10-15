---
tag: push
depends_on: ["push delivery pipeline + device-token registration seam (STATUS.md)"]
status: deferred
---

# Plan: Push — real FCM/APNs/web provider (deferred)

> **Status: 🟠 DEFERRED (owner decision, 2026-10-15).** The delivery pipeline and the
> device-token registration **seam** are landed and adversarially confirmed
> (`STATUS.md` → Landed `[push]`); what is missing is a real provider and a real token
> source, and **neither credentials nor a push SDK exists in this harness**. This is the
> reason for the deferral, not an unresolved design.

**This is the ONE canonical plan file for push delivery.** The rider and driver halves are
owned in their own domains and are **referenced here by path, not duplicated**:

- Rider registration half — `rider_app_plans/STATUS.md` → `### [push]`
  (`rider_app/lib/core/push/`, `pushTokenSourceProvider` resolving `NoopPushTokenSource`).
- Driver registration half — `driver_app_plans/STATUS.md` → `### [push]`
  (`driver_app/lib/core/push/push_token_source.dart:59-72`). The driver STATUS already records
  this as a deliberate seam-only deferral, not a defect.

Those owners update their own STATUS when their half lands; this file tracks the **server**
half plus the cross-domain acceptance.

---

## Current state (verified)

- Provider abstraction and fan-out exist: `Provider` (`internal/service/push/provider.go:26-28`),
  `ProviderFunc` (`:31-35`), `MultiProvider` (`:55-73`), and the shipped default
  **`LogProvider`** — a credential-free, I/O-free **no-op** that logs and returns nil
  (`:37-48`).
- Production wiring installs that no-op: `pushProvider := push.NewLogProvider()` when no
  provider is injected (`internal/router/router.go:113-117`). `WithPushProvider`
  (`router.go:59-60`) has **no production caller**.
- The service is best-effort/void by design: `notify` never returns an error to the caller, so
  a push outage cannot fail a ride transition (`internal/service/push/service.go:43`).
- Device tokens are persisted for real: migration `018_push_pipeline.up.sql`,
  `internal/repository/device_token_repo.go:49,69,77`; handlers/repos
  `internal/handler/platform.go:164,198`.
- Token **minting is inert** on both apps: no `firebase_messaging` (or any push SDK)
  dependency is declared, so `pushTokenSourceProvider` resolves `NoopPushTokenSource`
  (`driver_app/lib/core/push/push_token_source.dart:59-72`;
  `rider_app/lib/core/push/push_token_source.dart:59-72`) and production registers nothing.
- **No credentials/SDK in this harness**: no FCM service account, no APNs key, and no push
  SDK in any `pubspec.yaml`. There is no way to verify real delivery here.

---

## Scope when picked up

1. **Server provider.** Implement real `push.Provider`s behind
   `internal/service/push/provider.go` — an FCM client for `"android"`, an APNs client for
   `"ios"`, and a web provider for `"web"` — and install them via `MultiProvider`
   (`:55-73`) at `internal/router/router.go:113-117`. Keep `LogProvider` as the
   credential-free fallback so a push outage still cannot fail a ride transition.
2. **Config, fail-closed.** Add credential config (e.g. `PUSH_FCM_CREDENTIALS`,
   `PUSH_APNS_KEY`, …) parsed fail-closed like the elevation bools; absent credentials →
   `LogProvider` (current behaviour), present-but-broken → surface at boot, never per-send
   panics.
3. **Token registration (cross-domain).** Replace `NoopPushTokenSource` with the real SDK
   source in each app's `pushTokenSourceProvider`. The registration/unregistration service
   and endpoints already exist and are unchanged:
   `POST /devices` / `DELETE /devices/{token}` (`internal/router/router.go:271-276`).
4. **Delivery contract.** Keep `NotifyUser` best-effort/void; never let a send failure change
   a ride status. A token that the provider rejects (unregistered/invalid) should be
   unregistered best-effort, logged, and never fatal.

## Tests / verification (when unblocked by credentials)

- A recording `push.Provider` unit test proving `MultiProvider` routes by platform and
  falls back safely (extend the existing `push` tests).
- A config test that missing credentials yield `LogProvider` and malformed credentials fail
  closed.
- End-to-end delivery is **UNVERIFIABLE in this harness** (no credentials, no SDK); record
  that explicitly on landing, as the pipeline's own docs already do.

## Open inputs

| Unknown | Resolve with |
| --- | --- |
| Credential source/format per platform (env vs mounted files) | Deployment decision; do not invent a secrets manager |
| Web push protocol (VAPID/Web Push) vs FCM web | Product/platform decision |
| Whether token refresh stream is per-app SDK or server-driven | App owners' SDK choice |
