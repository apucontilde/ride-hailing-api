---
tag: nav
depends_on: []
status: open
---

# [nav] Home as a first-class sidebar destination

> Independent rider workstream, but the enum half is **CROSS-DOMAIN**: the driver app
> (`driver_app_plans`, parallel plan) adopts the *same* shared destination. No API change.
> Owner: `rider-planner`; shared symbols co-owned with `driver-planner`.
> Verify: `melos run analyze` + `melos run test`.

## Goal

Make **Home** a first-class destination in the shared navigation contract so it appears in the
drawer **and** in the profile's `AppNavLinkCard` (both are fed from the one list), and so the
driver app can name the same place identically.

Today neither sidebar can navigate to `/home`: the eight destinations in `AppNavDestination`
have no `home`, and `buildRiderNavItems()` omits it. A rider who opens `/profile` or
`/settings` must know to press the OS back / hamburger; there is no "Home" row.

## Current state (verified)

### The shared contract has no `home`

- `shared/lib/src/navigation/app_nav_destination.dart:17-38` — enum values:
  `profile`, `rideHistory`, `payment`, `vehicle`, `security`, `settings`. **No `home`.**
- `shared/lib/src/navigation/app_nav_section.dart:7-11` — the fixed groups
  `account('ACCOUNT')`, `activity('ACTIVITY')`, `safety('SAFETY')`, `app('APP')`. **No HOME.**
- Barrel already exports both files — `shared/lib/ride_hailing_shared.dart:17,20` — so a new
  enum value needs **no barrel edit** (do not add a shim; the invariant holds).
- `AppSidebar` groups by `AppNavSection` in enum order and **skips empty groups**
  (`shared/lib/src/navigation/app_sidebar.dart:58-73`), so a new section with no item costs
  nothing.

### The rider list omits Home

- `rider_app/lib/features/navigation/rider_nav_items.dart:20-42` — five items:
  `profile(/profile)`, `rideHistory(/history)`, `payment(/payment)`, `security(/security)`,
  `settings(/settings)`. **No `home(/home)`.**
- The profile card is fed from the **same** list minus `profile` —
  `rider_app/lib/features/home/presentation/profile_screen.dart:110-114` — so today it also has
  no Home row. Adding the item there is automatic; no second edit.
- The shell routes `/home` already exist and highlight correctly:
  `rider_app/lib/core/router/app_router.dart:60-63`; `rider_shell.dart:47-48,69,74-77`.
  Selecting `/home` works today (the route is registered); only the *row* is missing.

### Parity is a test contract

- `shared/test/navigation/app_nav_item_test.dart:11-14` asserts the exact `.values` id list;
  `:18-36` asserts each destination's canonical label/icon/section.
- `rider_app/test/features/navigation/rider_nav_items_test.dart:9,16-18,31-33,44-93` asserts the
  rider list length, ids, routes, icons, sections and the single label override.
- `driver_app/test/features/navigation/driver_nav_items_test.dart:16-24,31-36` asserts the
  driver's list. Both suites must move together (CROSS-DOMAIN, below).

## Scope

### 1. Add the shared destination (CROSS-DOMAIN)

Edit `shared/lib/src/navigation/app_nav_section.dart` — add a leading `home` group:

```dart
enum AppNavSection {
  home('HOME'),        // NEW, first
  account('ACCOUNT'),
  activity('ACTIVITY'),
  safety('SAFETY'),
  app('APP');
  ...
}
```

Edit `shared/lib/src/navigation/app_nav_destination.dart` — add the first value:

```dart
home('home', 'Home', Icons.home_outlined, AppNavSection.home),
```

- `id: 'home'` is a **test contract** (`Key('sidebar-item-home')`), kebab-case per the file's
  doc comment (`:14-16`).
- `label: 'Home'` is the canonical copy; no app overrides it.
- `icon: Icons.home_outlined` (never overridden — one of the two parity guarantees).
- `section: AppNavSection.home` — see the decision below; the alternative is
  `AppNavSection.account` with **no** section change.
- No barrel edit: `shared/lib/ride_hailing_shared.dart:17,20` already exports both files.

### 2. Add Home to the rider list

`rider_app/lib/features/navigation/rider_nav_items.dart` — insert **first**:

```dart
AppNavItem(destination: AppNavDestination.home, route: '/home'),
```

Resulting order (matches the section order): Home, Profile, History, Payment, Security,
Settings. The profile card automatically gains a Home row (it filters only `profile`,
`profile_screen.dart:111-113`).

### 3. Confirm the shell needs no change

`/home` is already a shell route (`app_router.dart:60-63`), already the title-map exception
(`rider_shell.dart:37-43,84-85`), and already highlighted when current (`rider_shell.dart:69`).
**Do not add `/home` to `_sectionTitles`** — it has no `AppBar` (edge-to-edge map), by design.

### 4. Tests to move

- `shared/test/navigation/app_nav_item_test.dart:11-14` — ids list gains `'home'` first.
- `shared/test/navigation/app_nav_item_test.dart:18-36` — add the `home` canonical assertions
  (`label 'Home'`, `icon Icons.home_outlined`, `section AppNavSection.home`).
- `shared/test/navigation/app_nav_item_test.dart:41-46` — section titles become
  `['HOME', 'ACCOUNT', 'ACTIVITY', 'SAFETY', 'APP']`.
- `rider_app/test/features/navigation/rider_nav_items_test.dart:9` — `hasLength(5)` → `6`;
  `:16-18` ids; `:31-33` routes; `:50-58` icons; `:64-78` sections (`account` → `home` name);
  `:87-92` the "other five" canonical-label loop now iterates six.
- `rider_app/test/features/navigation/rider_sidebar_test.dart:193` — the rendered headings list
  now includes `HOME` (the rider list contains a Home item, so the group is non-empty);
  `:208-217` the id loop gains `'home'`; `:246-252` the navigation map gains
  `'home': 'Home Page'` — **add a `/home` stub row to the bespoke router at `:105`** and assert
  tapping `sidebar-item-home` lands on it.
- `shared/test/navigation/app_sidebar_test.dart:49-69,114-129` uses a **local** `fiveItems()`
  fixture (`:6-16`) with no Home item, so the empty HOME group is skipped and those assertions
  stay green **unless** the fixture is deliberately extended; extending it is optional and only
  needed if we want shared coverage of the HOME heading. Recommend adding a 6th item to the
  fixture so shared learns the new heading.
- Driver: `driver_app/test/features/navigation/driver_nav_items_test.dart:16-24,31-36` must add
  `'home'` first and a `home` route — **owned by the parallel driver plan**, not this one.

## Shared contract the driver plan MUST adopt (CROSS-DOMAIN, verbatim)

```dart
// shared/lib/src/navigation/app_nav_section.dart
home('HOME'),

// shared/lib/src/navigation/app_nav_destination.dart
home('home', 'Home', Icons.home_outlined, AppNavSection.home),
```

Driver adoption: `buildDriverNavItems()` inserts
`AppNavItem(destination: AppNavDestination.home, route: '/home')` **first**, and
`driver_app/test/features/navigation/driver_nav_items_test.dart` moves its expected id/route
lists to `['home', 'profile', ...]`. `DriverShell.sectionTitles` already maps `'/home'`
(`driver_shell.dart:40-46`), so no driver shell edit is needed.

⚠️ **Reconciliation (drift in the parallel driver plan):** its code block
(`driver_app_plans/[nav]_home_destination.md:39-55`) uses `home('HOME')` /
`AppNavSection.home` and matches this plan exactly, but its prose (`:73-75,93,107,120`) calls the
group `MAIN` / `AppNavSection.main`. The **binding** name is `AppNavSection.home('HOME')` — the
driver plan's `MAIN`/`main` mentions are a rename to be fixed at implementation time, not a
second section. Both apps must use the single `home` value.

## Invariants

- **Do not override `icon` or `section` in either app's items** — they are the parity guarantee
  (`rider_nav_items.dart:7-9`; `app_nav_item.dart:46-52`).
- **No shim.** Import from the barrel; never add `rider_app/lib/.../app_nav_destination.dart`.
- **`shared/` owns no router.** Home's route stays app-owned (`/home` in both apps).
- **The shell owns the only `Scaffold`.** This plan adds no `Scaffold`/`AppBar`.
- **`/home` stays out of `_sectionTitles`** and keeps no `AppBar` (edge-to-edge map).
- Preserve every existing destination's id/label/icon/section; this is purely additive.

## Out of scope

- The back affordance on sections and sub-screens — see `[nav]_back_navigation.md` (this wave,
  coordinated: if the human picks the "back arrow → `/home`" shell option there, this plan is its
  prerequisite UX, but neither plan blocks the other's implementation).
- Any reordering of the existing five rider rows beyond prepending Home.
- `AppSettingsScreen` (no production consumer; see the back plan).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

Widget/unit assertions to add or update:

1. `buildRiderNavItems()` is exactly `['home','profile','ride-history','payment','security','settings']`
   with routes `['/home','/profile','/history','/payment','/security','/settings']`.
2. The drawer renders a `HOME` heading above `ACCOUNT`, with a `sidebar-item-home` row whose
   label is `'Home'` and icon `Icons.home_outlined`.
3. Tapping `sidebar-item-home` closes the drawer and lands on the `/home` stub.
4. The profile card now contains a `nav-link-home` row (it is fed the same list minus `profile`).
5. The shared enum `.values` id list and section-title list match the new contract.

## Open product decisions surfaced (human)

1. **Section placement** — add a new leading `AppNavSection.home('HOME')` (**recommended**: Home
   is the landing surface and is not "account"), or keep the 4-group enum unchanged and place
   Home first under `AppNavSection.account` (no shared-section change, but semantically the drawer
   would head Home with "ACCOUNT"). This is a shared contract change either way and the driver
   must match.
2. **Order within the list** — Home first (recommended, mirrors the section order) vs. last.
3. **Icon** — `Icons.home_outlined` (recommended; matches the other outlined icons) vs.
   `Icons.home` (filled) vs. `Icons.dashboard_outlined`.
4. **Profile-card inclusion** — Home now appears on the profile card automatically. Keep it
   (recommended) or filter Home out there in addition to `profile`
   (`profile_screen.dart:111-113`).

## Cross-domain notes

- **API: none.**
- **Shared (CROSS-DOMAIN):** `AppNavSection.home`, `AppNavDestination.home` — both apps adopt.
  Both files are already barrel-exported; no shim, no barrel edit.
- **Driver (`driver_app_plans`, parallel):** adopt the two symbols verbatim and prepend the Home
  item. Coordinate the exact id (`home`) and label (`Home`) so the two sidebars cannot drift.
- **`[nav]_back_navigation.md` (this wave):** shares `rider_shell.dart` concerns but not files;
  the two plans are combined by the human shell decision. Re-run the shell suite on whichever
  lands second.
- **`[design]` restyle (landed — `STATUS.md` → Landed `[design]`):** may have restyled
  `AppSidebarItem`; no interaction with this enum change.
- **STATUS rows to update on landing:** add a `### [nav]` line (Home destination, `file:line`);
  remove this plan's row and delete this file.
