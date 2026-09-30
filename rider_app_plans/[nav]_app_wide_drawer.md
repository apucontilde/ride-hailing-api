---
tag: nav
depends_on: []
status: open
---

# App-wide rider drawer via a ShellRoute (bug #9)

Bug **#9** of `rider_app_plans/STATUS.md`: the sidebar exists only on `/home`
(`rider_app/lib/features/home/presentation/home_screen.dart:96`), and `AppSidebar.selectedRoute`
is wired but no section-level sidebar consumes it — so switching sections costs a back-press. Make
the sidebar available on the app's top-level sections with a **`ShellRoute`** (decided 2026-09-29;
the driver twin is `driver_app_plans/[nav]_app_wide_drawer.md`, same shape, separate app).

**Read first:**

- `rider_app/lib/features/home/presentation/home_screen.dart:96-120` — the only `AppSidebar`
  construction (nav items, account header, footer/sign-out).
- `rider_app/lib/features/home/presentation/home_screen.dart:211-222` — the floating
  `AppSidebarToggleButton` inside the body `Stack` (home has **no AppBar** — it is a fullscreen
  map).
- `rider_app/lib/core/router/app_router.dart:38-99` — the routes. Section-like:
  `/home`, `/profile`, `/history`, `/payment`, `/security`, `/settings`. Flow routes that should
  **stay out** of the shell: `/location-search` (`:59`), `/driver-matching` (`:70`),
  `/active-ride` (`:74`).
- `rider_app/lib/features/navigation/rider_nav_items.dart` — `buildRiderNavItems()`.
- `shared/lib/src/navigation/app_sidebar_toggle_button.dart:40` — the toggle calls
  `Scaffold.of(context).openDrawer()`, so the drawer must live on the **nearest** `Scaffold` above
  the toggle.

## Gap (verified)

The `AppSidebar` block is inlined in `HomeScreen.build`; `profile`/`history`/`payment`/`security`/
`settings` build their own `Scaffold` with a default back arrow and no drawer. There is no
`ShellRoute`, and `selectedRoute` has no consumer.

## Decision (recorded)

**Use a `ShellRoute`** wrapping the six section routes. The shell owns the single `Scaffold`
(drawer + chrome); section screens render as the shell's `body` and **drop their own `Scaffold`**,
so `Scaffold.of(context)` inside the toggle resolves to the shell's drawer. One drawer instance,
one toggle that works everywhere.

- **Home keeps its overlay.** Home is a fullscreen map with the toggle as a `Positioned` child of
  its `Stack` (`:211-222`); with the nested `Scaffold` removed, that same toggle opens the shell
  drawer. Do not add an AppBar to home.
- **Other sections' chrome.** The shell provides a simple `AppBar` with the toggle leading and a
  route-aware title (from `GoRouterState`); `profile`/`history`/`payment`/`security`/`settings`
  stop declaring their own `AppBar`.
- **Back vs hamburger.** Sections are top-level siblings, so the leading is the sidebar toggle and
  the per-page back arrow is dropped; switching sections is via the sidebar.
- **Flows are excluded**: `/location-search`, `/driver-matching`, `/active-ride` keep their own
  chrome and are pushed from within a section.

## Work

1. Add a `RiderShell` builder used as the `ShellRoute.builder` in
   `rider_app/lib/core/router/app_router.dart`, wrapping `/home`, `/profile`, `/history`,
   `/payment`, `/security`, `/settings`. Leave the flow routes and the auth routes outside it.
2. Move the `AppSidebar` construction (`home_screen.dart:96-120`) into the shell, wiring the
   rider account header (`name`, `email` secondary line, `photoUrl`), `onSignOut` /
   `onSignOutCompleted`, and `selectedRoute` from the current location — one instance for all
   sections (this finally consumes the wired `selectedRoute`).
3. Convert the six section screens to body-only widgets (no own `Scaffold`/`AppBar`). Verify the
   home overlay toggle and each section's shell toggle open the shell drawer.
4. Tests: `rider_app/test/features/navigation/` (or the existing home suite) — open the drawer from
   at least one non-home section; assert the flow screens (`/active-ride`) have no drawer; nav taps
   route; `selectedRoute` reflects the active section.

## Tests

- Widget tests: drawer reachable from a section other than `/home`; absent on the flow routes; nav
  taps route; active-section highlight.

## Accept

- The drawer is reachable from every top-level section without a back-press; the ride flow screens
  are unchanged.
- `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
