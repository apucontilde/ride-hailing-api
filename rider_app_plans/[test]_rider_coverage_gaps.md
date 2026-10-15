---
tag: test
depends_on:
  - "[auth] web-reload session bootstrap (rider_app_plans/STATUS.md → Landed [auth])"
  - "[nav] universal back navigation (rider_app_plans/STATUS.md → Landed [nav])"
  - "[nav] Home as a first-class destination / profile link card (rider_app_plans/STATUS.md → Landed [nav])"
status: open
---

# [test] Rider coverage gaps — web-reload widget, shell back, profile Home row

> Coalesces rider bugs **#31**, **#27**, **#28** (`rider_app_plans/STATUS.md` → Known bugs), all
> test gaps over already-landed capabilities. Owner: `rider-planner`. Verify: `melos run analyze` +
> `melos run test` (Linux FVM SDK). Independent and unnumbered: every `depends_on` target is landed
> capability, not an open plan.

**Tag rationale (`test` over `auth`/`nav`).** The three gaps share one slice — "close rider test
coverage with no behavioral change" — and one review unit; splitting them across `auth` (web-reload)
and `nav` (shell back + profile card) would produce two half-plans that both need the same harness.
Tags name the orthogonal slice of work, not the bug-row label. The only production touch is one
additive, production-defaulted test seam (below); no behavior change anywhere.

## Gap #31 — no full-widget web-reload test

**Current coverage:** the redirect decision is unit-tested
(`test/core/router/app_router_test.dart:50-164`), the bootstrap is integration-tested
(`test/app_bootstrap_test.dart:77-108`), and a cold-start widget test pumps the real `RiderApp`
(`test/features/auth/presentation/splash_screen_test.dart:16-46`). Nothing mounts the app **at a
reloaded shell location** with a stored session and asserts it lands on `HomeScreen`.

**Why the existing cold-start test does not cover it:** `RiderApp`/`routerProvider` hardcodes
`initialLocation: '/splash'` (`core/router/app_router.dart:26-28`), so the cold-start test exercises
only the splash→login path. The web-reload defect was that a browser reload boots the router at
`/#/home` (or any shell section), *bypassing* `/splash`; `resolveRedirect` must send that
still-`bootstrapComplete:false` location to `/splash` and then, once the stored session resolves,
back to the shell section rather than `/login` (`core/router/post_auth_route.dart:59-90`, gate
`:65-67`).

### Seam decision: injectable initial location (a provider), not the bootstrap override

Add an additive, production-defaulted provider read by `routerProvider`:

```dart
/// Test seam: where the router boots. Production is `/splash`; a widget test
/// overrides it with a shell location to reproduce a browser reload.
final routerInitialLocationProvider = Provider<String>((ref) => '/splash');
```

and use `initialLocation: ref.read(routerInitialLocationProvider)` in `routerProvider`
(`core/router/app_router.dart:28`). Overriding the existing bootstrap provider alone cannot
reproduce the reload: it changes *when* the gate resolves, not *where the router booted*, which is
the whole failure mode.

### Test to add (new `test/features/auth/presentation/app_reload_test.dart`, or extend `splash_screen_test.dart`)

- Overrides: `authStorageProvider` with a staged stored access+refresh token; `apiClientProvider` →
  a `DioAdapter` answering `GET /rider/me` (200) and `GET /rides/current` (200, `{ride:null}`);
  `webSocketServiceProvider` mocked; `routerInitialLocationProvider` → `/home`; plus the hermetic
  seams `HomeScreen` needs — `mapTileLayerProvider` → `null`
  (`test/features/home/presentation/home_screen_test.dart:132`) and `locationServiceProvider` → the
  existing `FakeLocationService` (`home_screen_test.dart:126-130`). Overriding
  `locationPingServiceProvider` is optional: its `LocationHelper.getPositionStream` throws under
  `flutter_test` and is caught (`features/home/data/location_ping_service.dart:46-54`).
- Pump the real `RiderApp` (the `ProviderScope` + `RiderApp` pattern from
  `splash_screen_test.dart:25-33`).
- Assert: while the bootstrap is unresolved the first frame shows the splash spinner
  (`CircularProgressIndicator`, as `splash_screen_test.dart:37`); after `pumpAndSettle`,
  `find.byType(HomeScreen)` is `findsOneWidget` and `find.byType(LoginScreen)` is `findsNothing`.
  This is the exact reload regression: a stored session at `/home` must not bounce to `/login`.
- Negative control: the same harness with no stored token → `LoginScreen` (mirrors the cold-start
  case).
- **UNVERIFIABLE here:** a *real* browser reload. The exact closing step: run the app in Chrome
  (`flutter run -d chrome`, or the Windows-host browser target), sign in, navigate to `#/home`, hard
  reload, and confirm Home — not the login screen. State this in Verification; do not claim the
  widget test *is* the browser reload.

## Gap #27 — shell back test only exercises `/profile`

**Evidence:** `test/features/navigation/rider_shell_test.dart:83-102` pumps only `/profile`; all five
non-home sections share the identical
`isHome ? null : AppBar(leading: AppBackButton(onFallback: → /home), actions: [AppSidebarToggleButton])`
branch (`features/navigation/rider_shell.dart:85-93`).

**Test to add:** parameterise the existing case over the five sections — `/profile`, `/history`,
`/payment`, `/security`, `/settings` — reusing the existing `pumpShell` helper (it already builds all
six `_Body` routes, `rider_shell_test.dart:22-64`). Per section assert:

- `find.byType(AppBackButton)` is `findsOneWidget`;
- `AppSidebarToggleButton` is a descendant of the `AppBar`;
- after tapping `AppBackButton` + `pumpAndSettle`, `home-body` is shown.

Implement as `for (final location in sections) testWidgets('$location …')` so a failure names the
section. `/home`'s no-`AppBar`/no-back case (`:104-109`) is unchanged.

## Gap #28 — profile card's `nav-link-home` row is unasserted

**Evidence:** the profile card is fed
`buildRiderNavItems().where((item) => item.destination != AppNavDestination.profile)`
(`features/home/presentation/profile_screen.dart:110-115`), and `AppNavLinkCard` keys each row
`Key('nav-link-${items[i].id}')` (`shared/lib/src/navigation/app_nav_link_card.dart:43`;
`AppNavItem.id` → `destination.id`, `shared/lib/src/navigation/app_nav_item.dart:55`). `home` is the
only row (`nav-link-home`) with no direct assertion; the shared card test only covers
`nav-link-payment`/`nav-link-vehicle` (`shared/test/navigation/app_nav_link_card_test.dart:101-110`).

**Test to add (in `test/features/home/presentation/profile_screen_test.dart`):**

- Assert `find.byKey(const Key('nav-link-home'))` is `findsOneWidget` and `nav-link-profile` is
  `findsNothing` (the page's own destination is excluded).
- Assert the expected row set: `nav-link-home`, `nav-link-ride-history`, `nav-link-payment`,
  `nav-link-security`, `nav-link-settings` present; `nav-link-profile` and `nav-link-vehicle` absent.
- Tap the Home row and assert it routes: add a `/home` stub `GoRoute` to the test router (it currently
  stubs only `/settings`, `profile_screen_test.dart:91-106`) and assert the stub renders after
  `pumpAndSettle` (the card's `onItemSelected` calls `context.push(item.route)`,
  `profile_screen.dart:114`).

## Explicit test list (one sweep)

| # | File | Case |
| --- | --- | --- |
| T1 | `test/features/auth/presentation/app_reload_test.dart` (new, or extend `splash_screen_test.dart`) | stored session + boot at `/home` → resolves to `HomeScreen`, never `LoginScreen` |
| T2 | same | no session + boot at `/home` → `LoginScreen` (negative control) |
| T3 | `test/features/navigation/rider_shell_test.dart` | for each of `/profile`,`/history`,`/payment`,`/security`,`/settings`: shell back arrow + `AppBar` toggle, tap → `home-body` |
| T4 | `test/features/home/presentation/profile_screen_test.dart` | `nav-link-home` present, `nav-link-profile` absent, exact row set |
| T5 | same | tapping the Home row pushes `/home` |

Production touch: only `routerInitialLocationProvider` (T1/T2), default `/splash` — no behavior
change. Everything else is test-only.

## Related deferred work (referenced, not duplicated)

- The rider push-registration seam is already landed (`rider_app_plans/STATUS.md` → Landed `[push]`)
  and server delivery is deferred: `api_plans/[push]_production_provider.md` (`[push]`, `status:
  deferred`) is the **one canonical** push plan, and its §Scope item 3 owns the cross-domain
  "replace `NoopPushTokenSource` with the real SDK source" step, referencing the rider half by path
  into Landed `[push]` — it is **not re-authored here**. Push is not in scope for this test sweep.
- `[ontrip]_eta_state_reset.md` (bug #30) is a separate rider plan; no dependency between the two.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- T1 asserts after the injectable-initial-location seam above is added (it cannot boot at `/home`
  without it). T3/T4/T5 pass on the current tree once written.
- **UNVERIFIABLE here:** the real browser reload. Close with `flutter run -d chrome` → sign in →
  navigate to `#/home` → hard reload → assert Home, not login.
