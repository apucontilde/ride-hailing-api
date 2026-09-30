---
tag: nav
depends_on: []
status: open
---

# App-wide driver drawer via a ShellRoute (bug #10)

Bug **#10** of `driver_app_plans/STATUS.md`: the `AppSidebar` is attached only to `/home`
(`driver_app/lib/features/home/presentation/home_screen.dart:166`), so every other section is
reached by a push and costs a back-press to switch. Make the sidebar available on the app's
top-level sections with a **`ShellRoute`** (decided 2026-09-29 — supersedes the earlier per-screen
scaffold idea).

**Read first:**

- `driver_app/lib/features/home/presentation/home_screen.dart:125-197` — the only `AppSidebar`
  construction (nav items, account header, footer/sign-out), plus the rich AppBar (`:126-165`).
- `driver_app/lib/core/router/app_router.dart:75-98` — the section routes:
  `/home`, `/profile`, `/settings`, `/vehicle`, `/rides-history` (siblings; `/trip` at `:95-98`
  is **not** a section).
- `driver_app/lib/features/navigation/driver_nav_items.dart:23` — `buildDriverNavItems()`.
- `shared/lib/src/navigation/app_sidebar_toggle_button.dart:40` — the toggle calls
  `Scaffold.of(context).openDrawer()`, so the drawer must live on the **nearest** `Scaffold` above
  the toggle.
- `driver_app/lib/features/trip/presentation/trip_screen.dart:187-197` — trip uses `PopScope` and
  must stay drawer-free.

## Gap (verified)

The `AppSidebar` block is inlined in `HomeScreen.build`. Profile/settings/vehicle/history build
their own `Scaffold` with a default back arrow and no drawer. There is no `ShellRoute`.

## Decision (recorded)

**Use a `ShellRoute`** wrapping the five top-level sections. The shell owns the single `Scaffold`
(drawer + navigation chrome); section screens render as the shell's `body` and **drop their own
`Scaffold`**, so `Scaffold.of(context)` inside the toggle resolves to the shell's drawer. This is
the whole point of choosing `ShellRoute` over per-screen `drawer:` — one drawer instance, one
toggle-by-`Scaffold.of` that works everywhere.

- **Shell-owned chrome.** The shell builds
  `Scaffold(appBar: AppBar(leading: AppSidebarToggleButton(), title: <route-aware title>), drawer: AppSidebar(...), body: child)`.
  The section title comes from `GoRouterState` (a small route→title map); screens stop declaring
  their own `AppBar`.
- **Home's rich header.** The current home AppBar (avatar + name + status dot, `:126-165`) is
  home-specific; keep it as body content at the top of the home body, or keep a home-only AppBar
  **rendered inside the shell body** (not a nested `Scaffold`). Either way it must not introduce a
  second `Scaffold`.
- **Back vs hamburger.** Sections are top-level siblings, so the leading is the sidebar toggle and
  the per-page back arrow is dropped; switching sections is via the sidebar.
- **`/trip` is excluded** (pushed mid-journey, owns terminal/`PopScope` handling). The push flows
  inside sections keep whatever chrome they have.

## Work

1. Add a `DriverShell` builder used as the `ShellRoute.builder` in
   `driver_app/lib/core/router/app_router.dart`, wrapping `/home`, `/profile`, `/settings`,
   `/vehicle`, `/rides-history`. Leave `/trip` (and the auth/onboarding routes) outside it.
2. Move the `AppSidebar` construction (`home_screen.dart:166-197`) into the shell, wiring
   `driverProfileProvider` / `profileNotifierProvider.ratingSummaryLabel` / the status dot /
   `onSignOut` / `onSignOutCompleted` exactly as home does today — one instance for all sections.
3. Convert the five section screens to body-only widgets (no own `Scaffold`/`AppBar`); home's rich
   header becomes body content. Verify the toggle opens the shell drawer from every section.
4. Tests: `driver_app/test/features/navigation/` — open the drawer from at least one non-home
   section; assert `/trip` has no drawer; nav-item taps still route; update
   `home_screen_test.dart` for the shell refactor.

## Tests

- Widget tests: drawer reachable from a section other than `/home`; absent on `/trip`; nav taps
  route; the shell AppBar title changes per section.

## Accept

- The drawer is reachable from every top-level section without a back-press; `/trip` is unchanged.
- `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
