---
tag: nav
depends_on: []
status: open
---

# `[nav]` — Guaranteed back navigation on every driver screen

> Independent plan (no open-plan prerequisite; it references, but does not require, the sibling
> `[nav]_home_destination.md`). Owner: `driver-planner`. Verify: `melos run analyze` +
> `melos run test` (Linux FVM SDK — see Verification).
> **CROSS-DOMAIN:** the shared `AppBackButton` contract below is co-owned with the parallel rider
> plan. This plan edits `driver_app/**` and proposes `shared/lib/**` ADDitions only — it never edits
> `shared/`, `rider_app/**`, or `rider_app_plans/**`.

## Problem

"Every screen must have a back navigation arrow." Today the driver app has **no** guaranteed back
affordance for the top-level sections and several root-entered screens: the shell shows a hamburger
(`Icons.menu`), and auth/onboarding screens are entered with `context.go`, so Flutter's implicit
back button (`canPop == false`) never renders.

## Screen survey (verified, complete)

Every route in `driver_app/lib/core/router/app_router.dart:53-111` and every screen under
`driver_app/lib/features/`:

| Route | Screen / AppBar | Current back affordance (`file:line`) | In shell? |
| --- | --- | --- | --- |
| `/home` | body-only; shell AppBar | hamburger `AppSidebarToggleButton` (`driver_shell.dart:63`) | yes (`app_router.dart:81-84`) |
| `/profile` | body-only (`profile_screen.dart:53-57`) | same shell hamburger (`driver_shell.dart:63`) | yes (`:85-88`) |
| `/settings` | body-only (`settings_screen.dart:25-30`) | same shell hamburger | yes (`:89-92`) |
| `/vehicle` | body-only (`vehicle_screen.dart:30`) | same shell hamburger | yes (`:93-96`) |
| `/rides-history` | body-only (`rides_history_screen.dart:65`) | same shell hamburger | yes (`:97-100`) |
| `/splash` | `const Scaffold(body:…)`, **no AppBar** (`splash_screen.dart:33-40`) | none (boot root) | no (`:54-57`) |
| `/login` | `AppBar(title: 'Driver Log In')` (`login_screen.dart:94-95`) | implicit only if `canPop`; entered by `go` → none | no (`:58`) |
| `/register` | `AppBar(title: 'Drive With Us')` (`register_screen.dart:49-50`) | implicit only if `canPop`; entered by `go` (`login_screen.dart:167`) → none | no (`:59-62`) |
| `/forgot-password` | `AppBar(title: 'Forgot Password')` (`forgot_password_screen.dart:63-64`) | implicit only if `canPop`; entered by `go` (`login_screen.dart:163`) → none | no (`:63-66`) |
| `/reset-password` | `AppBar(title: 'Reset Password')` (`reset_password_screen.dart:68-69`) | implicit only if `canPop`; entered by `go` (`forgot_password_screen.dart:108`) → none | no (`:67-70`) |
| `/onboarding` | `AppBar(title: 'Become a Driver')` (`onboarding_screen.dart:57-58`) | implicit only if `canPop`; force-redirected (`app_router.dart:48`) → none | no (`:71-74`) |
| `/safety` | `AppBar(title: 'Safety & support')` (`safety_screen.dart:100-101`) | implicit back arrow **works** because it is `push`ed (`settings_screen.dart:77`) | no (`app_router.dart:103-109`) |
| `/trip` | `PopScope(canPop: !isTerminal)` + `AppBar(automaticallyImplyLeading: !isTerminal)` (`trip_screen.dart:195-205`) | implicit back arrow while non-terminal; suppressed when terminal | no (`app_router.dart:110`) |

Modal sheets (`offer_sheet.dart`, `rate_sheet.dart`) are not routes/screens and are out of scope.

## Decision — what "back" means

### 1. Top-level shell sections

Driving to a section is `context.go` (`driver_shell.dart:91`), so `canPop` is false — the shell
owns the only `AppBar` (`driver_shell.dart:59-65`) and this is therefore a shell-level decision.
Recommended:

- **non-Home sections** (`/profile`, `/settings`, `/vehicle`, `/rides-history`):
  `leading: AppBackButton(onFallback: () => context.go('/home'))`, and move the sidebar toggle to
  `actions: [const AppSidebarToggleButton()]` so the drawer stays reachable.
- **`/home`** (the root): keep `leading: const AppSidebarToggleButton()`, no back arrow. A root has
  nowhere to go back to; this is the single documented exception to "every screen".

This intentionally answers the "both?" question (task) as **back-as-leading + hamburger-in-actions**
on every non-root section, and **hamburger-only** on Home.

### 2. Root-entered screens (`/login`, `/splash`, `/onboarding`)

- `/splash` — no AppBar by design (`splash_screen.dart:35`); it is the boot placeholder and
  auto-redirects. **Exempt** (no back arrow).
- `/login` — the auth root. **No back arrow** (nothing sensible behind it).
- `/onboarding` — force-redirected for authenticated non-drivers (`app_router.dart:48`), so a pop is
  a no-op. Its "back" must **sign out** (which makes the router redirect to `/login`), i.e.
  `AppBackButton(onPressed: () => ref.read(authProvider.notifier).logout())`.
  ⚠️ **Finding:** the existing "Use a different account" button just calls `context.go('/login')`
  (`onboarding_screen.dart:111-114`); with `app_router.dart:49` redirecting an authenticated
  non-driver back to `/onboarding`, that button is a **no-op** (a latent bug, not in `STATUS.md`).
  This plan should fix it to sign out, and record the bug.

### 3. Pushed sub-screens (normal pop)

- `/safety` — pushed (`settings_screen.dart:77`), so the implicit arrow already renders; make it
  explicit for a guaranteed arrow even if deep-linked: `leading: AppBackButton(onFallback: () =>
  context.go('/settings'))`. No `PopScope`, so pop and arrow coexist trivially.
- `/trip` — a pushed mid-journey flow with terminal handling: `PopScope(canPop: !isTerminal, …)`
  with `automaticallyImplyLeading: !isTerminal` (`trip_screen.dart:195-205`). A back arrow **must
  not** appear while terminal, or it could be tapped to bypass `_finishTrip`
  (`trip_screen.dart:198-200`). Keep the gate; standardize the leading slot as
  `leading: trip.isTerminal ? null : const AppBackButton()`. The shared button's default
  `Navigator.maybePop` triggers the same `PopScope` callback Flutter's implicit button does.
  **No behavioral change** — this is a glyph/parity standardization only.

### 4. Register / forgot / reset

Add an explicit arrow because they are entered by `go` (so `canPop` is false):

- `/register` → `AppBackButton(onPressed: () => context.go('/login'))`.
- `/forgot-password` → `AppBackButton(onPressed: () => context.go('/login'))`.
- `/reset-password` → `AppBackButton(onPressed: () => context.go('/forgot-password'))`
  (alternative: `/login`; surfaced below).

## Decision — shared `AppBackButton` contract (CROSS-DOMAIN, both apps)

New file `shared/lib/src/navigation/app_back_button.dart`, exported from the barrel
(`shared/lib/ride_hailing_shared.dart`, alongside `app_sidebar_toggle_button.dart:27`). Exact public
API both apps adopt verbatim:

```dart
/// The back affordance both apps use, so the driver and rider point-back UX is
/// identical. Mirrors AppSidebarToggleButton: a real IconButton rendering a real
/// Icon, so `find.byIcon(Icons.arrow_back)` works in both apps' widget tests.
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    this.onPressed,
    this.onFallback,
    this.tooltip = 'Back',
    this.icon,
  });

  /// Explicit target. When null the button pops if possible, else calls
  /// [onFallback]. Null [onFallback] makes it a no-op when it cannot pop.
  final VoidCallback? onPressed;

  /// Called when the navigator cannot pop (entered via `go`, e.g. a top-level
  /// section). Apps pass `() => context.go('/home')` here.
  final VoidCallback? onFallback;

  final String? tooltip;
  final IconData? icon; // defaults to Icons.arrow_back
}
```

Behavior: render `IconButton(icon: Icon(icon ?? Icons.arrow_back), tooltip: tooltip)` whose
`onPressed` is `onPressed ?? (Navigator.of(context).canPop() ? Navigator.of(context).pop() :
onFallback?.call())`. Like `AppSidebarToggleButton` (`app_sidebar_toggle_button.dart:10-13`), the
concrete `Icon`/`IconButton` is part of the test contract.

`shared/` owns no router (`app_sidebar.dart:19-21`), so the button never calls `go`; apps pass
`onFallback`/`onPressed`. Shell composition stays app-side because the rider's Home is a bar-less map
(`rider_shell.dart:84-89`) while the driver's Home has a bar.

### Rider co-ownership (do not edit here)

The parallel rider plan must use `AppBackButton` in `RiderShell`'s non-Home `AppBar`
(`rider_app/lib/features/navigation/rider_shell.dart:84-89`) and in its own pushed screens, with the
Home fallback being the rider `/home`. The rider Home stays bar-less, so it is the same documented
root exception.

## Ambiguities to surface to the human (concrete choices)

1. **Both or one affordance on sections** —
   A. back-as-leading + hamburger-in-actions (recommended);
   B. hamburger-as-leading + back-in-actions;
   C. hamburger only and rely on the new Home sidebar row for "back" (no arrow — fails the stated
      requirement, listed for completeness).
2. **Home exception** — confirm `/home` may have **no** back arrow (root). Alternative: give Home an
   arrow whose action is system/exit (not recommended; not portable to web).
3. **`/onboarding` back** — sign-out to `/login` (recommended; fixes the no-op) vs "no back arrow"
   (leave `/onboarding` as a dead end).
4. **`/reset-password` back target** — `/forgot-password` (recommended, matches the entry path) vs
   `/login`.
5. **`/login` / `/splash`** — confirm they are the only two screens exempt from the arrow.
6. **`/trip` standardization** — keep Flutter's implicit arrow (zero change) vs swap to the shared
   `AppBackButton` (parity; recommended).

## Test updates (existing suites; `file:line`)

Driver:
- `driver_app/test/features/navigation/driver_shell_test.dart` — `openDrawer` taps the toggle
  (`:93-96`); with the toggle moved to `actions` on non-Home sections this still finds it by type,
  but add assertions: non-Home sections render `Icons.arrow_back` as `AppBar.leading`, Home does not;
  tapping the arrow on `/profile` lands on `/home` (add a `/home` stub route to the bespoke harness
  at `:33-72`, which currently lacks a real navigation target). The "AppBar title follows the
  section" case (`:145-156`) is unaffected.
- `driver_app/test/features/navigation/driver_sidebar_test.dart` — pumps `/home` only
  (`:177-213`), so its toggle finder (`:216`) is unchanged; add a Home exception assertion if the
  shell composition is touched.
- `driver_app/test/features/onboarding/presentation/onboarding_screen_test.dart` — if "Use a
  different account" is fixed to sign out, update/extend this suite (currently only asserts the
  name-save flow, `:133-183`).
- `driver_app/test/features/trip/presentation/trip_screen_test.dart` — if the leading swaps to
  `AppBackButton`, add/adjust a `find.byIcon(Icons.arrow_back)` assertion; the terminal-suppression
  behavior around `PopScope` (`trip_screen.dart:195-205`) must stay covered.
- `driver_app/test/features/safety/presentation/safety_screen_test.dart` — add an explicit
  `Icons.arrow_back` assertion for the pushed case.

Shared (owned by the shared/rider side; listed so they are not missed):
- New `shared/test/navigation/app_back_button_test.dart` — pops when poppable, calls `onFallback`
  when not, prefers explicit `onPressed`, renders `Icons.arrow_back` by default.

## Out of scope

- No change to `/trip` behavior/PopScope semantics (standardization only).
- No Go/API change; no rider or shared source edits (propose only).
- `/splash` and `/login` remain back-less roots.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Post-landing adversarial checks: every route in `app_router.dart:53-111` is classified above; no
top-level section other than `/home` lacks an `Icons.arrow_back`; `/trip` hides the arrow while
terminal; `/safety` pops; the new shared button is exported from the barrel and used by the rider.
