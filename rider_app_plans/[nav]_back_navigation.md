---
tag: nav
depends_on: []
status: open
---

# [nav] Back navigation on every screen

> Independent rider workstream, but the shared widget is **CROSS-DOMAIN**: the driver app
> (`driver_app_plans`, parallel plan) adopts the *same* `AppBackButton`. No API change.
> Owner: `rider-planner`; shared symbol co-owned with `driver-planner`.
> Verify: `melos run analyze` + `melos run test`.

## Goal

Give **every** reachable screen a back affordance, and make it identical in both apps:

- top-level sections get a **shell-level** leading back arrow (today they only have a hamburger);
- pushed sub-screens keep a normal pop, standardized through one shared widget;
- screens entered with `context.go` (so `canPop == false`) get an **explicit** back target;
- the edge-to-edge `/home` map and the transient `/splash` root are the deliberate exceptions.

This is a **shell-level decision** because `RiderShell` owns the only `AppBar`/`Scaffold` for the
six sections (`rider_shell.dart:26-91`), so a per-section arrow cannot be done in the body-only
section screens.

## Screen survey (verified, complete)

| Route | How it is entered | Chrome today | Back affordance today | Planned |
| --- | --- | --- | --- | --- |
| `/home` | shell; initial after login (`splash_screen.dart:32`) | **no `AppBar`** — shell returns `null` (`rider_shell.dart:84-85`); body-only `Stack` (`home_screen.dart:187`) with a `Positioned` toggle overlay (`:280-291`) | **none** (root) | none (root); keep the overlay toggle |
| `/profile` | shell | shell `AppBar(leading: AppSidebarToggleButton, title:)` (`rider_shell.dart:86-89`, title map `:37-43`) | **none** | shell back arrow → `/home` |
| `/history` | shell | same (`rider_shell.dart:86-89`) | **none** | shell back arrow → `/home` |
| `/payment` | shell | same | **none** | shell back arrow → `/home` |
| `/security` | shell | same | **none** | shell back arrow → `/home` |
| `/settings` | shell | same | **none** | shell back arrow → `/home` |
| `/splash` | `initialLocation` (`app_router.dart:25`) | `Scaffold` with no `AppBar` (`splash_screen.dart:41-45`) | **none** (transient root) | none; see decision D6 |
| `/login` | redirect (`app_router.dart:36`) | `AppBar(title: 'Log In')` (`login_screen.dart:94-95`) | implicit only — `canPop == false` because reachable by `go` | none (root); see decision D6 |
| `/register` | `context.go('/register')` from login (`login_screen.dart:167`) | `AppBar(title: 'Sign Up')` (`register_screen.dart:48-49`) | implicit only — `canPop == false` | explicit `AppBackButton` → `/login` |
| `/forgot-password` | `context.go('/forgot-password')` from login (`login_screen.dart:163`) | `AppBar(title: 'Forgot Password')` (`forgot_password_screen.dart:69-70`) | implicit only — `canPop == false` | explicit `AppBackButton` → `/login` |
| `/location-search` | `context.push` from Home (`home_screen.dart:122,361,393`) and Active ride (`active_ride_screen.dart:206`) | `AppBar(title: TextField)` (`location_search_screen.dart:53-64`) | implicit back (`canPop == true`) | standardize `leading: const AppBackButton()` |
| `/driver-matching` | `context.go('/driver-matching')` from Home (`home_screen.dart:670`) | `AppBar(leading: IconButton(Icons.close))` (`driver_matching_screen.dart:135-142`) | `Icons.close`; handler = `showNoDrivers ? _goHome : _cancelRequest` | `AppBackButton` with the **same** handler; see decision D4 |
| `/active-ride` | `context.go` from matching (`driver_matching_screen.dart:111,130`) and splash (`splash_screen.dart:30`) | `Scaffold` with **no `AppBar`** (`active_ride_screen.dart:466`); body-only `Stack` | **none** — only in-flow leave logic `context.go('/home')` (`:193,374,452`) | `Positioned` `AppBackButton` → the existing leave logic; see decision D5 |

Not a rider screen but relevant: `shared/lib/src/settings/app_settings_screen.dart:75-76` builds
its own `Scaffold(appBar: AppBar(title: Text(title)))`. **No production code uses it** — grep
finds only `shared/test/settings/app_settings_screen_test.dart:6,17,60,88`. Both apps compose the
shared `AppSettingsSection`/`AppSettingsRow` rows directly and are body-only
(`rider_app/.../settings_screen.dart:8-19,32`; `driver_app/.../settings_screen.dart:16-30`). Its
implicit `AppBar` back arrow would appear only if it were ever pushed. **Out of scope** (no
consumer); recorded as a drift note, not a task.

## Scope

### 1. Shared `AppBackButton` (CROSS-DOMAIN)

New file `shared/lib/src/navigation/app_back_button.dart`, exported from
`shared/lib/ride_hailing_shared.dart` (one `export` line; **no shim**).

⚠️ **Reconciled with the parallel driver plan** (`driver_app_plans/[nav]_back_navigation.md:
98-137`, authored 2026-10-07): the two domains must ship **one** signature. The driver plan's
richer API is adopted verbatim here, because `onFallback` is exactly what a `go`-entered
top-level section needs (pop when possible, else `/home`) and avoids repeating
`canPop` checks at every call site:

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

  /// Explicit target, highest precedence. When null the button pops if the
  /// navigator canPop, else calls [onFallback].
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
onFallback?.call())`. `shared/` owns no router, so it never calls `go`; the app passes the target.

- Renders `Icons.arrow_back` (the test contract), not `Icons.close`.
- Sits safely in `AppBar(leading:)` (same contract as `AppSidebarToggleButton`,
  `app_sidebar_toggle_button.dart:37-41`).
- New shared test `shared/test/navigation/app_back_button_test.dart`: default glyph,
  explicit `onPressed` wins, pops when poppable, calls `onFallback` when not (pump inside a
  `Navigator`).

### 2. Shell decision — back on top-level sections

`rider_app/lib/features/navigation/rider_shell.dart:84-89`:

- For a non-home section, `leading:` becomes
  `AppBackButton(onFallback: () => context.go('/home'))`, and the drawer toggle moves to
  `actions: [const AppSidebarToggleButton()]` so the sidebar stays one tap away.
- `/home` keeps `appBar: null` and the `Positioned` overlay toggle
  (`home_screen.dart:280-291`) — there is no `AppBar` to host a leading there.
- Why `go('/home')` and not `maybePop`: the six sections are siblings pushed with `go`
  (`rider_shell.dart:74-77`), so there is no stack to pop and `canPop` is `false`.

This is the **recommended** option B below; it is what makes the shell-level answer to "what does
back mean on a top-level section" concrete. If the human picks option A (no section back arrow;
the new Home row from `[nav]_home_destination.md` is the affordance), delete this whole section.

### 3. Sub-screens

- `/location-search` — set
  `appBar: AppBar(leading: const AppBackButton(), title: TextField(...))`
  (`location_search_screen.dart:54-64`); behavior unchanged (it is pushed, so the button pops),
  glyph standardized.
- `/register` — `AppBar(leading: AppBackButton(onPressed: () => context.go('/login')))`.
- `/forgot-password` — same leading → `/login`.
- `/login` and `/splash` — **no back** (roots; decision D6).

### 4. Flow screens

- `/driver-matching` (`driver_matching_screen.dart:135-142`) — replace the `Icons.close`
  `IconButton` with `AppBackButton(onPressed: showNoDrivers ? _goHome : _cancelRequest)`
  (the existing handler), unless the human picks D4.
- `/active-ride` (`active_ride_screen.dart:466-534`) — add a top-left overlay, mirroring Home's
  toggle pattern:
  ```dart
  Positioned(
    top: 8, left: 16,
    child: SafeArea(
      child: AppBackButton(
        onPressed: () { /* existing leave logic */ },
      ),
    ),
  )
  ```
  The handler must reuse the screen's existing leave path (the cancel confirmation then
  `context.go('/home')`, `:139-205`, `:366-375`, `:445-453`); it must not pop (the screen is
  reached by `go`, `canPop == false`). See decision D5 for the mid-trip guard.

## Shared contract the driver plan MUST adopt (CROSS-DOMAIN, verbatim)

```dart
// shared/lib/src/navigation/app_back_button.dart
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    this.onPressed,
    this.onFallback,
    this.tooltip = 'Back',
    this.icon,
  });
  final VoidCallback? onPressed;    // explicit target (highest precedence)
  final VoidCallback? onFallback;   // called when the navigator cannot pop
  final String? tooltip;
  final IconData? icon;             // defaults to Icons.arrow_back
}
```

Driver adoption: import it from the barrel and use it as the leading affordance on every pushed
driver screen that today relies on an implicit/`Icons.close` leading
(e.g. `driver_app/lib/features/safety/presentation/safety_screen.dart:101`,
`.../onboarding/presentation/onboarding_screen.dart:58`,
`.../auth/presentation/{login,register,forgot_password,reset_password}_screen.dart`,
`.../trip/presentation/trip_screen.dart:202`). The driver shell keeps its own router-free
callback and, if it adopts the section back arrow, uses the same `AppBackButton` symbol with
`onFallback: () => context.go('/home')`. The exact enum destination contract is in
`[nav]_home_destination.md`.

## Tests to update / add

- **New** `shared/test/navigation/app_back_button_test.dart`.
- `rider_app/test/features/navigation/rider_shell_test.dart` — add: every non-home section
  renders one `AppBackButton`; tapping it navigates to the `/home` body; the
  `AppSidebarToggleButton` is now found in `actions` (the existing `:71-91,126-136` assertions
  must be revisited because the toggle's position/leading changes).
- `rider_app/test/features/navigation/rider_sidebar_test.dart:141-163` — the Home overlay-toggle
  path still resolves `Scaffold.of` through the shell; unaffected, but re-run.
- `rider_app/test/features/home/presentation/location_search_screen_test.dart` — assert the
  leading is `AppBackButton` and pops.
- `rider_app/test/features/home/presentation/driver_matching_screen_test.dart` — the close
  button assertions change glyph/handler.
- `rider_app/test/features/home/presentation/active_ride_screen_test.dart` — assert the overlay
  back arrow exists and triggers the leave/cancel path (no pop).
- `rider_app/test/features/auth/presentation/register_screen_test.dart`,
  `forgot_password_screen_test.dart` — assert back → `/login`; `login_screen_test.dart` and
  `splash_screen_test.dart` — assert **no** back arrow.
- `rider_app/test/integration/auth_flow_test.dart:132` — `find.byIcon(Icons.menu)` on `/home`
  still holds (the Home overlay toggle keeps `Icons.menu`); re-run.
- `shared/test/navigation/app_sidebar_toggle_button_test.dart` — unchanged (widget untouched).
- `shared/test/settings/app_settings_screen_test.dart` — unchanged (no production consumer).

## Invariants

- **`shared/` owns no router.** `AppBackButton` pops via `Navigator` and otherwise calls the
  app-supplied `onFallback`/`onPressed`; it never calls `context.go`/`push`.
- **No shim.** Import from the barrel; never add `rider_app/lib/.../app_back_button.dart`.
- **The shell owns the only `Scaffold` on the six sections.** Their bodies stay body-only; the
  back arrow lives in the shell `AppBar`, not in a section screen.
- **`/home` stays edge-to-edge with no `AppBar`**; its nav affordance is the `Positioned` overlay.
- **`/splash` and `/login` stay root screens** (no back) unless decision D6 says otherwise.
- Do not remove public providers or the existing leave/cancel logic; the back arrow reuses it.
- Keep the `Icons.menu` default on `AppSidebarToggleButton` (asserted by
  `auth_flow_test.dart:132`, `rider_sidebar_test.dart:175`).

## Out of scope

- The Home **destination/sidebar row** — see `[nav]_home_destination.md` (coordinated: the
  section back arrow's target is `/home`, and if the human picks the "rely on the Home row"
  option A here, that plan is the whole fix).
- `AppSettingsScreen`'s own `Scaffold`/`AppBar` (no consumer; drift note only).
- The driver screens themselves (parallel driver plan).
- Any change to where a screen logically leaves to (cancel semantics, pickup recovery); the back
  arrow reuses the existing handlers.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

Widget assertions:

1. `/profile`..`/settings` each render exactly one `AppBackButton` in the shell `AppBar`; tapping
   it lands on `/home`; the sidebar is still openable from `actions`.
2. `/driver-matching` and `/active-ride` show `Icons.arrow_back` and route through the existing
   leave/cancel logic without popping.
3. `/register` and `/forgot-password` show `Icons.arrow_back` and go to `/login` even though
   `canPop` is false.
4. `/login`, `/splash` and `/home` show **no** `AppBackButton`.
5. `/location-search` back button pops back to the originating screen.

## Open product decisions surfaced (human)

1. **D1 — shell-level meaning of "back" on a top-level section** (both apps must match):
   - **B (recommended):** `leading = AppBackButton → /home`; hamburger moves to `actions`.
     Every section has a real arrow and the drawer stays reachable.
   - **A:** no arrow on sections; rely on the new **Home** sidebar row
     (`[nav]_home_destination.md`). Minimal, but a section still shows only a hamburger, which
     does not literally satisfy "every screen has a back arrow."
   - **C:** show both a back arrow (leading) and the hamburger (leading) — unusual, cramped.
2. **D2 — where does section back go?** always `/home` (recommended; deterministic, no history in
   `go`-based navigation) vs. a remembered previous section (needs app-owned history state).
3. **D3 — is this a shared widget?** `AppBackButton` (recommended; enforces rider/driver visual
   parity) vs. Flutter's implicit `BackButton`. The shared widget is required to make the two
   apps identical and is the CROSS-DOMAIN contract above.
4. **D4 — `/driver-matching` glyph semantics:** replace `Icons.close` with `Icons.arrow_back`
   and reuse `showNoDrivers ? _goHome : _cancelRequest` (recommended; satisfies the requirement)
   vs. keep `Icons.close` (cancel is semantically not "back") and accept this one exception.
5. **D5 — `/active-ride` back guard:** show the arrow always and route it through the existing
   cancel confirmation while a trip is live (recommended; consistent with the cancel button) vs.
   show it only on terminal/completed states and direct-`go('/home')` then.
6. **D6 — auth/splash back arrows:** `/login` and `/splash` are roots (no back, recommended) vs.
   forcing an arrow that exits the app / is a no-op. `/register` and `/forgot-password` get an
   explicit arrow → `/login` regardless.
7. **D7 — `/location-search` ownership:** standardize on `AppBackButton` (recommended) vs. keep
   Flutter's implicit arrow there.

## Cross-domain notes

- **API: none.**
- **Shared (CROSS-DOMAIN):** `AppBackButton` in `shared/lib/src/navigation/app_back_button.dart`
  + one barrel `export` line. Both apps adopt; do not shim.
- **Driver (`driver_app_plans`, parallel):** adopt `AppBackButton` for every pushed sub-screen
  and, if D1-B is chosen, in `DriverShell`. Note the driver `/home` **does** have an `AppBar`
  (`driver_shell.dart:59-65`) unlike the rider's — its `AppBar` must remain back-free as the
  root, or the driver plan must special-case it.
- **`[nav]_home_destination.md` (this wave):** the section back arrow's target (`/home`) and the
  new Home sidebar row are two facets of the same shell decision; land/verify together and
  re-run `rider_shell_test.dart` on whichever lands second.
- **`[design]` (landed — `STATUS.md` → Landed `[design]`):** `AppButton` now exists;
  `AppBackButton` is a specialized leading control and can be kept or later expressed via it.
- **STATUS rows to update on landing:** add a `### [nav]` line (universal back affordance +
  shell decision, `file:line`); remove this plan's row and delete this file.
