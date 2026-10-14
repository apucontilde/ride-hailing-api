---
tag: auth
depends_on:
  - "shared web-session persistence + `checkAuth` recovery (rider_app_plans/STATUS.md → Landed `[auth]`) — shared/lib/src/auth/app_auth_controller.dart:146-204,397-398,435-445; shared/lib/src/auth/auth_storage.dart:4-5,59-81; shared/lib/src/auth/auth_key_value_store_web.dart:11-26"
status: open
---

# [auth] Web reload session bootstrap — run `checkAuth()` on every entry path

> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> Verification). **Chain head, unnumbered** — the only prerequisite is *landed* shared `[auth]`
> capability named in `rider_app_plans/STATUS.md` (Landed `[auth]` → "Web session persistence"), not
> an open plan, so this file carries no `NN_` prefix. It is the head of the `[auth] → [trip]`
> restore chain; `01_[trip]_post_auth_live_trip_restore.md` `depends_on` **this** open plan.
>
> **Nothing in this file is claimed landed.** The shared auth layer itself *is* landed and correct;
> the defect is purely that the rider app never calls into it on a non-splash entry.

## Request (verbatim)

> login does not persist between reloads on both apps web.

## Verified root cause (recon, code-confirmed)

The shared auth layer is **landed and correct** — tokens are persisted in `localStorage` and
`checkAuth()` recovers a session. The bug is that on a web reload `checkAuth()` is **never called**,
so the router bounces an authenticated user to `/login` before the session is read.

1. **The web build uses go_router's default HASH URL strategy.** There is no `usePathUrlStrategy()` /
   `url_strategy` anywhere in `rider_app/`, `driver_app/` or `shared/` (verified — no match in the
   tree). A reload carries the route in the fragment (`.../#/home`).
2. **`initialLocation: '/splash'` is only used when the platform supplies no initial route.**
   On a hash reload the browser/engine supplies `/home`, so the router boots at `/home`; the
   `SplashScreen` widget is never constructed and its `initState` → `_checkAuth()` never runs —
   `rider_app/lib/features/auth/presentation/splash_screen.dart:16-37`.
3. **The `redirect` then reads the default unauthenticated state and bounces.** `AuthState` starts
   `AuthStatus.unauthenticated` (`shared/lib/src/auth/app_auth_controller.dart:27-36,86`); the
   redirect sends any non-auth route to `/login` —
   `rider_app/lib/core/router/app_router.dart:22-39` (`isSplash` short-circuits; `:36`
   `if (!isAuthenticated && !isAuthRoute) return '/login';`).
4. **The tokens really do survive the reload** — nothing loads them on a non-splash boot:
   - `AuthStorage` picks `window.localStorage` at compile time —
     `shared/lib/src/auth/auth_storage.dart:4-5`;
   - reads return `null` on failure, writes are best-effort — `auth_storage.dart:59-81`;
   - web backend `WebLocalStorageKeyValueStore` — `auth_key_value_store_web.dart:11-26`;
   - `checkAuth` recovers a refresh-token-only cold start and retries a `/me` 401 —
     `app_auth_controller.dart:146-204`; single-flight refresh — `:397-398`;
     definitive-vs-transient failure handling — `:135-144,435-445`.
5. **`scripts/dev-all.sh` pins the web origin** (`WEB_PORT=5173`, `--web-port`) precisely so the
   `localStorage` session is stable across dev-server restarts — `scripts/dev-all.sh:30,50-52,100-103`.

**Net:** the session survives the reload; the app just never asks. A user who reloads `/#/home` lands
on `/login` even though a valid refresh token is sitting in `localStorage`.

## The fix (recommended): authenticate once, on every entry path

Invoke `checkAuth()` **exactly once at bootstrap**, and gate the router `redirect` on a
bootstrap-resolved flag so it cannot bounce to `/login` before the session is read. This covers all
three entry paths that currently skip the check: cold start, web reload, and (for login) the
post-`_submit` transition.

**Recommended mechanism — app-local, no `shared/` churn:**

1. `rider_app/lib/main.dart` builds a `ProviderContainer`, `await`s
   `container.read(authProvider.notifier).checkAuth()` once, then
   `runApp(UncontrolledProviderScope(container: container, child: const RiderApp()))`
   (or a tiny root bootstrap widget that does the await and shows the existing splash spinner while
   it runs — see Open inputs #1).
2. Add an app-local `bootstrapCompleteProvider` (a `bool`/`AsyncValue` that flips when
   `checkAuth()` settles). `app_router.dart`'s `redirect` returns `/splash` (or `null` when already
   there) while bootstrap is unresolved, and only applies the `isAuthenticated`/auth-route rules once
   it is resolved. This makes the ordering explicit, testable, and immune to a future re-entrant
   read.
3. Because the `GoRouter` is built after `checkAuth()` settles, a reload at `/#/home` already sees
   `AuthStatus.authenticated` and stays on `/home` — the bug is gone for **every** route, not just
   `/home`.

`checkAuth()` must remain **exactly once** (it performs a network `/me`/refresh); do not also call it
from the bootstrap *and* `SplashScreen.initState` in a way that double-probes. Keep `/splash` as a
valid route (a direct visit still works), but it is no longer the only trigger.

### Recommended vs alternatives

| Option | How | Tradeoffs | Verdict |
| --- | --- | --- | --- |
| **App-local bootstrap (RECOMMENDED)** | `checkAuth()` once before the first router read; `redirect` gated on a bootstrap flag. | **+** No `shared/`, API or driver change. **+** Fixes reload on **every** route. **+** Reuses the landed, correct `checkAuth` recovery. **−** Requires a small app-local seam (`bootstrapCompleteProvider`) and a testable initial-location/bootstrap injection point. | **Take this.** |
| Force `/splash` on web | `redirect` sends every unresolved non-splash location to `/splash` and lets `SplashScreen._checkAuth()` do the work. | **+** Smallest redirect delta. **−** Makes `/splash` a global gate; still needs a resolving flag to avoid the same bounce; leaves `SplashScreen` as a hidden prerequisite of the router. | Viable fallback, not preferred. |
| Shared `AuthStatus.resolving` | Add a `resolving` enum value to shared so the redirect can distinguish "unknown" from "unauthenticated". | **+** Most explicit signal. **−** A `shared/` edit consumed by both apps; `AuthStatus` is a shared contract and both apps' switches must be audited. | **Cross-domain ask — flag, do not edit `shared/`.** If chosen, `rider-planner` reports it to the coordinator for a shared/barrel change. |
| `usePathUrlStrategy()` + SPA fallback | Adopt path URLs and have the host/`flutter run` serve `index.html` for deep paths. | **−** Changes the public URL shape; needs host/SPA-fallback work; and it does **not** by itself fix the bug — a reload at `/home` would still skip the splash unless `checkAuth` runs at bootstrap. | Rejected as the fix (may be a separate cleanliness plan). |

**NO `shared/` edit is required** under the recommendation. If a reviewer concludes a shared symbol
*is* needed (e.g. `AuthStatus.resolving`), this plan must record it as a **cross-domain ask** and stop
— do not write into `shared/`. (`shared/` is ADD-only; no app file may be moved there.)

### Cross-domain ask (report, do not author here)

The **driver app has the identical defect** and must be mirrored by `driver-planner`:
`driver_app/lib/main.dart:5-8`, `driver_app/lib/core/router/app_router.dart:27-52` (same
`initialLocation: '/splash'` + default-`unauthenticated` `redirect`),
`driver_app/lib/features/auth/presentation/splash_screen.dart:13-31`. This rider plan does not edit
`driver_app/`. The API half is already recorded as **no change** by
`api_plans/[auth]_web_session_token_contract.md` (Bearer tokens, no cookie change required).

## Boundaries

- **Rider-only, app-local.** `main.dart` + `app_router.dart` + (optionally) a root bootstrap
  widget/provider. No API change (`api_plans/[auth]_web_session_token_contract.md` already says so),
  no driver change (mirror only), **no `shared/` change**.
- The landed shared auth behavior must not be altered: `AuthStatus`, `checkAuth`, `refreshToken`
  single-flight, definitive/transient classification are consumed as-is.

## Tests (new / changed)

| Test | File | Asserts |
| --- | --- | --- |
| Reload-at-`/home` bootstrap | `rider_app/test/core/router/app_router_test.dart` (new) or `rider_app/test/app_bootstrap_test.dart` (new) | with a stored token + `/me` success and the router booting at `/home`, the first settled screen is `HomeScreen` — **not** `LoginScreen`, and the splash is not required. Needs an injectable bootstrap/initial-location seam (see Open inputs #1/#2). |
| No session still logs in | extend `rider_app/test/features/auth/presentation/splash_screen_test.dart:16-46` | no token ⇒ `/login` (existing behavior preserved); the bootstrap provider settles `unauthenticated` and `checkAuth` runs exactly once. |
| Bootstrap gate | new test around the `bootstrapCompleteProvider` seam | while resolving, the redirect targets `/splash`; after settle it applies the auth rules — a mutation test (flip the flag) proves a reload cannot bounce to `/login`. |
| `checkAuth` once | `rider_app/test/core/auth/auth_provider_test.dart` (extend) | the bootstrap path invokes `checkAuth` once (no double `/me` probe when the splash route is also visited). |

Existing tests that must stay green / be updated (not deleted):
`rider_app/test/features/auth/presentation/splash_screen_test.dart`,
`rider_app/test/features/navigation/rider_sidebar_test.dart:88`, and the other suites that override
`authProvider`/`authStorageProvider` (they pump `RiderApp` directly and must still compile with the
new bootstrap seam).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` must be clean; `melos run test` green across rider / driver / shared.
- **UNVERIFIABLE in this WSL harness:** the real browser reload. `flutter test --platform chrome`
  (run from `rider_app/`) can exercise the web `localStorage` backend, but the reload-through-the-URL
  behavior needs a served app. Close on an on-host browser:
  1. `scripts/dev-all.sh --no-driver` (fixed web port `5173`, so the origin is stable);
  2. log in, confirm the URL is `.../#/home`;
  3. press reload (or re-enter the URL) and confirm the app returns to `/home` **without** the login
     screen and **without** a visible blank state;
  4. log out, reload, and confirm `/login` (no stale session).
- `make flutter-analyze` / `make flutter-test` are **broken from this WSL tree** — do not use them.

## Open inputs / unknowns

1. **Bootstrap UX while `checkAuth()` is in flight.** Keep the existing splash spinner (root
   bootstrap widget) vs await in `main()` and accept a brief blank frame. Recommended: keep the
   spinner (no blank flash).
2. **Test seam for a reload-at-`/home`.** Pure widget tests always build the router at
   `initialLocation: '/splash'` (there is no browser URL), so proving the reload path needs either an
   injectable `initialLocation` or an override-able bootstrap provider. Confirm which seam is
   preferred (recommended: a `bootstrapCompleteProvider` the redirect reads, overridden in tests).
3. **Driver-app mirror ownership/timing** — cross-domain, `driver-planner` (report only here).
4. **Path vs hash URL strategy long-term** — a separate cleanliness decision; does not block this fix.

## Invariants touched (from STATUS.md)

- Keep the re-export-shim structure intact and add **no** shared symbol / shim under the
  recommendation.
- The API never answers an outage with 4xx (`RIDER_API_GUIDE.md` + STATUS.md Invariants); the
  bootstrap must treat a transient `checkAuth` failure as "keep tokens, unauthenticated this launch",
  never as a reason to wipe storage (that classification is already landed in `checkAuth`).
- One shared tile/config source of truth and the shell/scaffold invariants are untouched.
