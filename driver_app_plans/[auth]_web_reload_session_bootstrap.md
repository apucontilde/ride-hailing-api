---
tag: auth
depends_on: ["landed shared web-session-robustness core ([auth] localStorage AuthStorage + checkAuth; shared/lib/src/auth/auth_storage.dart, driver_app_plans/STATUS.md → Landed [auth])"]
status: open
---

# [auth] Web reload bootstraps the session on every entry path

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification). A real browser reload is **UNVERIFIABLE in this WSL tree**; the
> widget-level bootstrap probe is the proxy (closing steps under Verification).
>
> **Chain head (unnumbered).** `depends_on` names *landed* capability (the shared session core that
> already persists tokens in web `localStorage`), not an open plan, so this file is unnumbered
> (`.opencode/skills/plan-management/SKILL.md`). The sibling `01_[trip]_post_auth_live_trip_restore.md`
> names **this open plan** and therefore carries the `01_` prefix. **Nothing here is claimed landed.**

## Goal

Reloading the driver web app on a non-splash route (for example `/#/trip`) must not bounce the
driver to `/login`. A driver whose tokens are in `localStorage` must come back authenticated on
**every** entry path, including a hash deep link.

## Verified root cause (evidence, not prose)

- Flutter web uses the **default HASH URL strategy** — there is no `usePathUrlStrategy()` anywhere in
  `driver_app/lib`, `rider_app/lib` or `shared/lib` (source grep is empty; only build-artifact
  references under `rider_app/.dart_tool/` mention `url_strategy.dart`). So reloading `/#/trip` boots
  `go_router` **at `/trip`**.
- `initialLocation: '/splash'` is used only when the platform supplies no initial route —
  `driver_app/lib/core/router/app_router.dart:30`. On a hash reload the platform *does* supply
  `/#/trip`, so `/splash` is skipped and `SplashScreen` never mounts.
- `checkAuth()` is called **only** from `SplashScreen._checkAuth()` —
  `driver_app/lib/features/auth/presentation/splash_screen.dart:20-31`. With splash skipped, nothing
  loads the persisted tokens.
- The router `redirect` reads `authProvider`, whose initial state is the default `unauthenticated`
  (the `AuthState()` constructor default, `shared/lib/src/auth/app_auth_controller.dart:32-36`), so
  the first redirect for `/trip` hits `if (!isAuthenticated) return isAuthRoute ? null : '/login';`
  and lands on `/login` — `driver_app/lib/core/router/app_router.dart:46`.
- The shared auth layer is **landed and correct**; it is simply never invoked on this path. Tokens
  persist in web `localStorage`:
  - `shared/lib/src/auth/auth_storage.dart:4-5,59-81` (best-effort read/write/delete).
  - `shared/lib/src/auth/auth_key_value_store_web.dart:11-26` (`window.localStorage`, survives a page
    reload; selected by the conditional import at `auth_storage.dart:4-5`).
  - `shared/lib/src/auth/app_auth_controller.dart:146-204` (`checkAuth` storage→`/me` probe),
    `:319` (`login` saves tokens), `:397-446` (`refreshToken` single-flight rotation + persistence).

**Net:** no token load on a non-splash reload → the router decides on the default `unauthenticated`.

## The one shared contract (adopt verbatim; do not invent a differing one)

The rider sibling `rider_app_plans/[auth]_web_reload_session_bootstrap.md` is the canonical statement
of the same contract — one shared contract, per-app bootstrap. The driver adopts it **verbatim**:

1. **C1 — exactly one `checkAuth()` per app launch, on every entry path.** A bootstrap step runs
   `checkAuth()` once, before the app makes any auth decision, and it must run whether the boot route
   is `/splash`, `/`, or a hash deep link like `/#/trip`.
2. **C2 — the router must not evaluate auth redirects before bootstrap resolves.** The `redirect`
   gates on a bootstrap-resolved flag so it can never read the transient default `unauthenticated`.
3. **C3 — no `shared/` change.** `checkAuth()`, `AuthStorage` and the web `localStorage` store are
   correct and landed; the fix is app-local bootstrap wiring. If a shared symbol is ever judged
   necessary, it is a cross-domain ask to the cross-app-planner — **do not edit `shared/` here**.

## Scope (app-local only)

- `driver_app/lib/main.dart:5-8` (sync `main()`, bare `ProviderScope`) and
  `driver_app/lib/app.dart:31-37` (`MaterialApp.router`) — add the bootstrap.
- `driver_app/lib/core/router/app_router.dart:27-52` — gate `redirect` on the resolved flag.
- `driver_app/lib/features/auth/presentation/splash_screen.dart:20-31` — remove/guard the now-duplicate
  `checkAuth()` so C1 is "exactly once".

## Recommended design (app-local, no `shared/` edit)

**Recommended: await the bootstrap in `main()` and gate the redirect on a resolved flag.**

1. In `main()`, build a `ProviderContainer`, `await container.read(authProvider.notifier).checkAuth()`,
   then `runApp(UncontrolledProviderScope(container: container, child: const DriverApp()))`. This
   mirrors the `ProviderContainer`/`UncontrolledProviderScope` harness the router suite already uses
   (`driver_app/test/core/router/app_router_test.dart:21-36`).
2. A `bootstrapCompletedProvider` (`StateProvider<bool>`, default `false`) is flipped `true` by the
   bootstrap after `checkAuth()` returns. **Belt and suspenders** with step 1: it keeps the redirect
   honest if a later change moves the bootstrap out of `main()`.
3. `app_router.dart` `redirect` gates first:
   `if (!ref.read(bootstrapCompletedProvider)) return isSplash ? null : '/splash';` before the
   existing auth rules. `/splash` shows a spinner; any other deep-linked route is held until resolved
   (no false `/login`).
4. `SplashScreen` no longer calls `checkAuth()`; it becomes a pure landing/redirect based on the
   already-resolved `authProvider` (or is retired in favour of the router gate). This satisfies C1
   ("exactly once") and removes the second `/me` probe.

### Alternatives considered

| Option | How | Tradeoffs |
| --- | --- | --- |
| **A — bootstrap in `main()` + resolved-flag gate (RECOMMENDED)** | Await `checkAuth()` on a `ProviderContainer`, then run the app; flag gates `redirect`. | **+** One boot path, one `/me`, works for hash deep links. **+** Smallest diff; no `shared/`. **−** `main()` becomes `async` and replaces `ProviderScope` with `UncontrolledProviderScope` (manual lifetime, app-lifetime is fine). |
| **B — root gate widget** | Keep `ProviderScope`; a `ConsumerStatefulWidget` runs `checkAuth()` in `initState`, shows `SplashScreen` until a `FutureProvider` resolves, then builds `MaterialApp.router`. | **+** Keeps `ProviderScope`. **−** More moving parts; must still gate `redirect` (C2) so a deep-linked route cannot decide before resolution. |
| **C — switch to `usePathUrlStrategy()`** | Call `usePathUrlStrategy()` and give the server a SPA fallback. | **− Rejected:** requires server rewrites/host config outside this repo, does not by itself load tokens, and the request is "session persists on reload", not "change URL strategy". Hash strategy is fine once bootstrap loads tokens. |
| **D — per-screen `checkAuth()` on mount** | Call `checkAuth()` from each entry screen. | **− Rejected:** N call sites, N `/me` probes, and a protected screen can still redirect before its own `checkAuth` runs. Violates C1. |

### Why the redirect flag is still needed under A

`redirect` runs synchronously on the first location evaluation. Even with the await in `main()`, any
future refactor that defers the bootstrap (or a web deep link that evaluates before the await
completes) must not read the default `unauthenticated`. The flag makes C2 a property of the router
rather than a timing accident.

## Tests to add/change

- `driver_app/test/core/router/app_router_test.dart` (extend `:15-57`): with persisted tokens and a
  **non-splash initial route** (build the router, then `container.read(routerProvider).go('/trip')`),
  the driver lands on `/trip`/`Home`, **not** `LoginScreen`, and `checkAuth` is invoked exactly once.
  Add: a not-yet-resolved bootstrap routes to `/splash`, never `/login`.
- `driver_app/test/features/auth/presentation/splash_screen_test.dart` (**new**, if splash remains):
  `checkAuth` is **not** called on mount after the bootstrap change; the screen redirects from the
  already-resolved state.
- Guard regression: no duplicate `checkAuth()` (assert one `/driver/me` probe per launch).
- Existing tests to keep green: `app_router_test.dart:40-45` (empty session still lands on `/login`)
  and `:47-56` (protected route with no session → `/login`).

## Cross-domain

- **`shared/` — NO change** (C3). If the bootstrap is ever judged to belong in shared, that is a new
  decision and a cross-app-planner ask; this plan does not edit `shared/`.
- **Rider sibling:** `rider_app_plans/[auth]_web_reload_session_bootstrap.md` — the other half of the
  same contract (one shared contract, per-app bootstrap). This driver plan references it and adopts C1
  /C2/C3 verbatim; it does **not** re-derive a differing contract. See Open inputs.
- `01_[trip]_post_auth_live_trip_restore.md` (open, same domain) layers the active-trip restore on
  top of this bootstrap and is the reason this file is a chain head.

## Open inputs / unknowns

| # | Unknown | Resolution |
| --- | --- | --- |
| 1 | The rider sibling path `rider_app_plans/[auth]_web_reload_session_bootstrap.md` is **not present in this tree** at authoring time (the rider directory holds only the 2026-10-13 `[ontrip]`/`[release]`/`[map]` plans) | Cross-app-planner to confirm the rider plan is authored under this exact filename or report the agreed name; the contract (C1–C3) is fixed regardless. Not a driver blocker. Do not edit `rider_app_plans/`. |
| 2 | Retire `SplashScreen` entirely vs keep it as a pure landing screen | Either satisfies C1; retirement is smaller if the router gate already renders `/splash`. Decide during implementation. |
| 3 | `main()` async + `UncontrolledProviderScope` vs the root gate widget (B) | Recommended A; confirm no test harness depends on `ProviderScope` being the root. |
| 4 | Exact bootstrap UI (spinner copy) while unresolved | Cosmetic; reuse the existing `CircularProgressIndicator` splash. |

## Dangling-`depends_on` check

`depends_on` names **landed** capability only (the shared web-session core in
`driver_app_plans/STATUS.md` → Landed `[auth]`), so this file is correctly **unnumbered**. No open
plan is named, so there is no dangling target. The rider sibling referenced in prose is not a
`depends_on` entry (flagged in Open inputs).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

On a web host (`flutter run -d chrome`, Windows SDK UNC-mapped per AGENTS.md): sign in, navigate to
`/#/trip` (or any protected route), press reload, and confirm the driver returns authenticated to the
same route instead of `/login`; then sign out and reload, and confirm `/login`. **UNVERIFIABLE in this
WSL tree.**
