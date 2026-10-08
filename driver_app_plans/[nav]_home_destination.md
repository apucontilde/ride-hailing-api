---
tag: nav
depends_on: []
status: open
---

# `[nav]` — Home as a first-class sidebar destination

> Independent plan (no open-plan prerequisite). Owner: `driver-planner`.
> Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see Verification).
> **CROSS-DOMAIN:** the shared symbols below are co-owned with the parallel rider plan; both apps
> must adopt the *same* contract. This plan edits `driver_app/**` and proposes `shared/lib/**`
> ADDitions only — it never edits `shared/`, `rider_app/**`, or `rider_app_plans/**`.

## Problem

The shared `AppNavDestination` enum has no `home` member
(`shared/lib/src/navigation/app_nav_destination.dart:17-38`), and `buildDriverNavItems` omits it
(`driver_app/lib/features/navigation/driver_nav_items.dart:23-45`). Both surfaces fed from that one
list therefore cannot reach `/home`:

- the drawer (`driver_shell.dart:66-92`), and
- the profile screen's `AppNavLinkCard`, which is fed the same list minus `profile`
  (`driver_app/lib/features/profile/presentation/profile_screen.dart:97-105`).

The route `/home` already exists inside the `ShellRoute` (`driver_app/lib/core/router/app_router.dart:81-84`)
and its title is already mapped (`driver_app/lib/features/navigation/driver_shell.dart:40-46`); only
its *destination identity* is missing. Home is currently reachable only by a cold start / splash
redirect (`splash_screen.dart:25`) or by a top-level `context.go` — never from the app chrome.

## Decision — shared destination contract (CROSS-DOMAIN, both apps)

Add **one enum member** and **one section** to the shared navigation core. Exact symbols the rider
plan must adopt verbatim:

The rider plan `rider_app_plans/[nav]_home_destination.md:63-88,131-139` is already authored and
fixes the symbol names. **This driver plan adopts them verbatim** — do not rename.

```dart
// shared/lib/src/navigation/app_nav_section.dart — declared FIRST, before account.
enum AppNavSection {
  home('HOME'),                 // NEW — Home lives here
  account('ACCOUNT'),
  activity('ACTIVITY'),
  safety('SAFETY'),
  app('APP');
  // ...
}

// shared/lib/src/navigation/app_nav_destination.dart — declared FIRST.
enum AppNavDestination {
  home('home', 'Home', Icons.home_outlined, AppNavSection.home),  // NEW
  profile('profile', 'Profile', Icons.person_outline, AppNavSection.account),
  // ... existing members unchanged
}
```

- **id** `home` (kebab-case, becomes `Key('sidebar-item-home')` / `Key('nav-link-home')`).
- **label** `Home` (no override in either app).
- **icon** `Icons.home_outlined` (parity guarantee: never overridden).
- **section** `AppNavSection.home` — a new leading group so Home is the first row under the first
  heading, not mixed into ACCOUNT/ACTIVITY where it has no semantic home. `AppNavSection` is a
  fixed render-order parity guarantee (`app_nav_section.dart:1-19`); adding a section is a
  deliberate shared change, not an app-local one.

Because `AppSidebar` groups by section in enum declaration order
(`shared/lib/src/navigation/app_sidebar.dart:58-73`) and the enum lists `home` first, Home renders
first for **both** apps with no shell change.

### Section alternative (already surfaced by the rider plan; human decision)

| Option | Heading cost | Semantic cost | Churn |
| --- | --- | --- | --- |
| **A. New `home('HOME')` (rider plan + this plan)** | one extra heading (`HOME`) in both drawers | clean: root destination is its own group | shared section enum + both apps' heading tests |
| **B. Reuse `AppNavSection.account`** | no new heading | poor: `Home` under `ACCOUNT` | smaller (no section-enum change) |

Either way the `AppNavDestination.home` member (id/label/icon) is fixed and shared. The rider plan
recommends A, so this driver plan is written for A; if the human picks B, both plans change
`section: AppNavSection.home` → `AppNavSection.account` and drop the section addition.

## Driver changes

1. `driver_app/lib/features/navigation/driver_nav_items.dart:23-45` — prepend
   `AppNavItem(destination: AppNavDestination.home, route: '/home')` as the first row (the list is
   already order-preserving; `home` first makes it render first regardless). No other item changes;
   the `includeVehicle` gate (`:24,31-35`) is untouched.
2. No change to `driver_shell.dart`: `sectionTitles['/home']` already exists (`:41`), and
   `selectedRoute: location` (`:71`) already highlights the active route, so `/home` highlights
   correctly once the row exists.
3. No change to `profile_screen.dart`: the card filter (`:97-105`) drops only `profile`, so the new
   Home row appears there automatically and routes via the existing `context.go` (`:104`).
4. Proposed **shared** additions (owned by the rider/shared plan; listed here for the contract):
   `AppNavDestination.home` and `AppNavSection.home` are added to the barrel automatically (the
   barrel exports the files, `shared/lib/ride_hailing_shared.dart:17,20`). No new shim.

## Rider co-ownership (do not edit here)

The parallel rider plan must add `home` at `/home` in `buildRiderNavItems`
(`rider_app/lib/features/navigation/rider_nav_items.dart:20-42`), and its shell must keep `/home`
in the `ShellRoute` (it already is, `rider_shell.dart:8-25`). The rider's `/home` is an
edge-to-edge map with no `AppBar` (`rider_shell.dart:84-89`), so the Home row is drawer-only there —
that is a rider-side composition detail, not a contract difference. The rider's nav-item and
sidebar tests must adopt the shared `home` id/section.

## Ambiguities to surface to the human

1. **Section for Home** — Option A (new `HOME`, recommended and already fixed by the rider plan)
   vs Option B (fold into `ACCOUNT`).
2. **Should Home also appear on the profile card?** Recommended yes (it is fed by the same list and
   the card is a shortcut surface); the alternative is to filter `AppNavDestination.home` out of the
   card like `profile`, leaving it drawer-only.
3. **Should `/home` be the first sidebar row even when `includeVehicle` is true?** Yes by the
   section ordering above; confirm no objection to Home outranking Vehicle.

## Test updates (existing suites; `file:line`)

Driver:
- `driver_app/test/features/navigation/driver_nav_items_test.dart` — item count `3` (`:16`),
  id/route/section/icon/label lists (`:19-24, 31-45, 47-67`), "no payment/security" (`:85-89`), and
  the gated counts `3`/`4` (`:124-125`) all change to include `home` (`4`/`5`, ids gain `'home'`
  first, sections gain `AppNavSection.home` first, routes gain `'/home'` first, icons gain
  `Icons.home_outlined` first).
- `driver_app/test/features/navigation/driver_sidebar_test.dart` — rendered headings
  `['ACCOUNT','ACTIVITY','APP']` (`:249-256`) and the destination-key loop `['profile',
  'ride-history','settings']` (`:265-268`) gain `HOME`/`home`; add a Home-label assertion.
- `driver_app/test/features/navigation/driver_shell_test.dart` — unaffected structurally (route set
  at `:188-198` unchanged); add a Home-row routing case if desired.

Shared (owned by the shared/rider side; listed so they are not missed):
- `shared/test/navigation/app_nav_item_test.dart:11-14` (id list) and `:41-46` (section titles) —
  both must include the new values.
- `shared/test/navigation/app_sidebar_test.dart:6-16` (`fiveItems()` uses the rider list; a `home`
  row is needed to cover the new `home` heading at `:49-69`).
- `driver_app/test/features/profile/presentation/profile_screen_test.dart:316-357` — no assertion
  breaks, but add coverage for the new `nav-link-home` row.

## Out of scope

- No route/shell change: Home is already registered and titled.
- No rider or shared source edits (propose only).
- No Go/API change.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Post-landing adversarial checks: `AppNavDestination.home` exists with exact id/label/icon/section;
`buildDriverNavItems()` leads with `home → /home`; the drawer and the profile card each render a
`home` row; `/home` highlights under `selectedRoute`.
