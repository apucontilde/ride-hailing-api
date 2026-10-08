---
tag: design
depends_on: ["[design] shared style foundation (rider_app_plans/STATUS.md, landed)"]
status: open
---

# [design] Driver adoption of the shared style system (tokens + components)

> **Independent plan.** The shared foundation (tokens + component library in
> `ride_hailing_shared`) and the rider migration have **landed** — see
> `rider_app_plans/STATUS.md` → Landed `[design]`. This plan only migrates `driver_app/` onto
> those landed symbols. It depends on landed *capability*, not an open plan, so it is unnumbered
> per `.opencode/skills/plan-management/SKILL.md`. It must **not** redefine, re-author, or fork
> any shared token/component. Owner: `driver-planner`. Verify:
> `melos run analyze` + `melos run test` (Linux FVM SDK + native Melos 8).

## Why this is unnumbered

This plan depends only on already-landed *capability* — the `[design]` shared style foundation
recorded in `rider_app_plans/STATUS.md` → Landed `[design]` — not on an open plan. Per
`.opencode/skills/plan-management/SKILL.md`, the `NN_` prefix is reserved for stages whose
`depends_on` names an **open** plan; a plan whose prerequisite is landed code stays unnumbered
(cf. `api_plans/[routing]_intercity.md`). The `01_` prefix this file previously carried was
dropped when the rider design source plan landed, was condensed into `STATUS.md`, and was
deleted.

## Canonical owner / consumer (CROSS-DOMAIN)

| Role | Plan / package | Owns |
| --- | --- | --- |
| **Canonical owner** | Landed `[design]` foundation in `rider_app_plans/STATUS.md` (`shared/lib/src/theme/*`, `shared/lib/src/components/*`) | Token classes, component library, barrel exports, `shared/test/components/*`, the `AppColors`→polyline blue/grey mapping. |
| **Consumer** | this plan (`driver_app_plans/[design]_shared_style_adoption.md`) | Driver screen migration + the `driver_app`-only `AuthTextField` deletion + driver test updates. |

There is **one** definition of every shared symbol (`shared/`), one barrel, and two consumers
(rider, driver). No driver-local copy of a shared token/component may survive.

## Shared symbols adopted verbatim (do NOT redefine)

Adoption path for every symbol below is the barrel —
`package:ride_hailing_shared/ride_hailing_shared.dart` (`shared/lib/ride_hailing_shared.dart`;
the landed `[design]` foundation added one `export` line per new file). The driver plan adds **no**
app shim.

### Tokens — canonical directory `shared/lib/src/theme/` (landed `[design]` foundation)

| Symbol | Roles/fields adopted | Notes |
| --- | --- | --- |
| `AppColors` | `primary`, `onPrimary`, `success`, `warning`, `danger`, `info`, `muted`, `surface`, `outline`; plus the banner tints used today (rider `Color(0xFFFFF8E1)`/`Color(0xFFFFEBEE)`, driver `red.shade50`/`blue.shade50`); route-polyline `blue`/`grey` must resolve exactly (landed `[design]` foundation). | New class. `appSeedColor` `0xFF1A73E8` stays the single seed. |
| `AppTextStyles` (extended) | role tokens `title`, `subtitle`, `body`, `label`, `caption`, `fare`. | Existing `shared/lib/src/theme/app_theme.dart:34-46` (currently only `sidebarSectionHeading`). |
| `AppSpacing` | `xs/sm/md/lg/xl` | Existing `app_theme.dart:13-21`. |
| `AppRadii` | `sm/md/lg` + new sheet radius (20/28) + `pill`/`full`. | Existing `app_theme.dart:25-31`. |
| `AppElevation` | `card`/`sheet`/`banner`. | New. |
| `AppMotion` | durations + curves for snapping/animated states. | New. |

The per-file layout of the new token classes (`AppColors`, `AppElevation`, `AppMotion`) is
**owned by the landed `[design]` foundation**; the driver consumes the class names via the barrel, never a hardcoded
`shared/src/...` import in app code.

### Components — canonical directory `shared/lib/src/components/` (landed `[design]` foundation)

| Symbol | Adopted contract (landed `[design]` foundation; do not add fields the owner did not define) |
| --- | --- |
| `AppButton` | primary/secondary/danger/text wrapping the Material variants with shared shape/size. |
| `AppTextField` | superset of both `AuthTextField`s: `controller`, `label`, `hint`, `keyboardType`, `obscureText`, `autofillHints`, `prefixIcon`/`suffixIcon`, `validator`, `textInputAction`, `onFieldSubmitted`. |
| `AppCard` | shared card look. |
| `AppListTile` | where a shared look is needed. |
| `AppBottomSheet` + `AppSheetHandle` | shared `Container` + top-radius + drag handle. |
| `AppEmptyState` | icon + message (+ optional action), matching rider `history_screen.dart:85-106` and driver `rides_history_screen.dart:310-335`. |
| `AppErrorState` / `AppErrorRow` | icon + message + optional retry, matching rider `home_screen.dart:505-522` and driver `rides_history_screen.dart:337-366` / `trip_screen.dart:259-279`. |
| `AppSectionHeader` | section title token/widget. |
| `AppStatusChip` / `AppBadge` | driver status dot/chip (`home_screen.dart:136-152`; rider `active_ride_screen.dart:683-687`). |

`AppRatingSheet` (if it lands) is owned by `rider_app_plans/[rating]_unify_rating_ui.md` and
consumes these tokens/components — see Cross-domain notes; this plan does not define it.

## Driver current state (verified, 2026-10-08)

Grep over `driver_app/lib` (matches the landed `[design]` foundation's inventory exactly):

- `0` `Color(0x…)` literals, `26` `Colors.*`, `2` `BorderRadius.circular`, `16` `TextStyle(`,
  `4` `fontSize:`, `35` `EdgeInsets`.
- `BorderRadius.circular`: `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:141`
  (`12`), `driver_app/lib/features/home/presentation/home_screen.dart:267` (`8`).
- Hand-tinted surfaces: `home_screen.dart:140-144` (green/grey status dot), `:161`
  (`Colors.red.shade50`), `:180` (`Colors.blue.shade50`); `offer_sheet.dart:145-147`;
  `rate_sheet.dart:92-95`.
- Duplicated widgets: `rides_history_screen.dart:310-335` (`_EmptyState`),
  `:337-366` (`_ErrorRow`); `trip_screen.dart:259-279` (error rows); `offer_sheet.dart:214-224`
  and `rate_sheet.dart:153-163` (buttons).
- `AuthTextField` is a driver-local copy —
  `driver_app/lib/features/auth/presentation/widgets/auth_text_field.dart:3-42` — used by
  `login_screen.dart:105,115`, `register_screen.dart:59,68,77`,
  `forgot_password_screen.dart:73`, `reset_password_screen.dart:78,87`.
- `AppTheme.light` already shared: `driver_app/lib/app.dart:34`; shim
  `driver_app/lib/core/theme/app_theme.dart:1` (`export ... show AppTheme`).
- Settings already reads `AppSpacing`/`AppRadii` (`settings_screen.dart:29,31`).

## Scope

### 1. Replace the app-local `AuthTextField` with shared `AppTextField`

- Migrate all `AuthTextField` call sites to the shared `AppTextField`:
  `driver_app/lib/features/auth/presentation/{login,register,forgot_password,reset_password}_screen.dart`.
  Pass the driver's `hint`/`keyboardType` values through as needed; the shared widget is the
  superset, so no local drift is allowed (the old driver copy had a required `String? hint` and a
  different `keyboardType` default — reconcile to the shared signature, do not preserve the local
  variant).
- **Delete** `driver_app/lib/features/auth/presentation/widgets/auth_text_field.dart` once every
  call site compiles against the shared widget. This is a **replacement** (re-authored in
  `shared/` by the landed `[design]` foundation), not a move — no file is moved into `shared/`.

### 2. Adopt the shared tokens in driver screens

Replace driver literals with the shared roles, behavior-preserving:

- `home_screen.dart:267` `BorderRadius.circular(8)` → `AppRadii.sm`;
  `onboarding_screen.dart:141` `BorderRadius.circular(12)` → `AppRadii.md`.
- `home_screen.dart:140-144` green/grey status dot → `AppColors.success`/`AppColors.muted`
  through `AppStatusChip`/`AppBadge`.
- `home_screen.dart:161` `Colors.red.shade50` → the `AppColors.danger` tint;
  `:180` `Colors.blue.shade50` → the `AppColors.info` tint (error/info surfaces through
  `AppErrorRow`/`AppEmptyState` where they are already message rows).
- Hand-written `TextStyle(fontSize:)` in `offer_sheet.dart`/`rate_sheet.dart`/`trip_screen.dart`
  → the `AppTextStyles` roles (`fare` for the money leg, `title`/`subtitle`/`body`/`caption`
  elsewhere).
- The one visual identity stays `appSeedColor` `0xFF1A73E8`; no per-app accent override, no dark
  mode (product decisions settled).

### 3. Adopt the shared components in driver screens

Migrate the landed `[design]` foundation **driver checklist** (see below). Preserve behavior and public
signatures: this is a presentation refactor only — no routing, API, provider or state-machine
change.

### 4. Driver screen migration checklist (driver half)

- `features/home/presentation/home_screen.dart`
- `features/rides/presentation/offer_sheet.dart`
- `features/rides/presentation/rate_sheet.dart`
- `features/rides/presentation/rides_history_screen.dart`
- `features/trip/presentation/trip_screen.dart`
- `features/profile/presentation/profile_screen.dart`
- `features/settings/presentation/settings_screen.dart`
- `features/onboarding/presentation/onboarding_screen.dart`
- `features/vehicle/presentation/vehicle_screen.dart`
- `features/safety/presentation/safety_screen.dart`
- `features/auth/presentation/*` + `widgets/auth_text_field.dart`
- `features/navigation/driver_shell.dart`

Order (keeps the tree compiling): the tokens, components (+ shared tests) and rider migration are
already landed, so migrate driver screens top-down; delete the local `AuthTextField` only after
its auth call sites are migrated.

### 5. Shared-package boundary

- No driver-specific symbol, provider, `ApiConfig`, route table, or `go_router` code enters
  `shared/`. The driver's screen body-only structure is unchanged; `DriverShell` stays the only
  `Scaffold`/`AppBar` owner for the five top-level sections.
- Only the presentation layer moves; `driver_app/lib/core/` provider wiring and the barrel import
  convention are untouched.

## Invariants

- **Canonical owner wins.** Every shared symbol is defined once by the landed `[design]`
  foundation; the driver plan cites and consumes it. No redefinition, no fork, no second
  `AuthTextField`.
- **Never move app files into `shared/`; only ADD.** The driver `AuthTextField` is deleted, not
  relocated; its replacement is re-authored in `shared/` by the landed `[design]` foundation.
- **No new app shims.** Import shared symbols from
  `package:ride_hailing_shared/ride_hailing_shared.dart` directly (AGENTS.md re-export rule).
- **Behavior-preserving.** No routing/API/provider/state-machine change; no endpoint or request
  shape change.
- **Preserve test keys.** Existing driver keys and semantics
  (`driver_app/test/features/**`) must stay green; semantic colors asserted in tests (e.g. the
  status-dot green/grey, error/info tints) must resolve through `AppColors` to the same values.
- **One identity / no dark mode.** `AppTheme.light` is the only theme; accent stays
  `0xFF1A73E8`.
- **Body-only sections.** The five sections must not build their own `Scaffold`/`AppBar`;
  `DriverShell` owns the only one (`driver_app/lib/features/navigation/driver_shell.dart:26`;
  STATUS.md Invariants). `/trip` and `/safety` stay outside the shell and keep their back
  affordance.
- **Toolchain.** Linux FVM SDK + native Melos 8 (`/mnt/i/flutter` is CRLF-broken;
  `make flutter-*` shells out to broken Windows `melos.bat`).

## Out of scope

- Defining any shared token/component (owned by the landed `[design]` foundation) or the shared rating widget
  (owned by `[rating]_unify_rating_ui.md`).
- Any API/Go change; any provider, router, or state-machine change.
- Dark mode, custom font, per-app theming, golden-test infrastructure (all settled out of scope).
- The deferred vehicle-surface work and the shell/back-navigation plans.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

- **Do not run a concurrent `melos` while a Flutter implementation agent is editing the
  workspace** — a competing `melos` corrupts `/.dart_tool`. Run the gate only when the workspace
  is quiescent.
- Baseline counts to preserve (re-count at landing; totals drift): **driver_app 337 passed**
  (recorded in `driver_app_plans/STATUS.md` Verification, 2026-10-05); for the full `melos run
  test` context `rider_app_plans/STATUS.md` records **rider 347 / shared 151** at the last
  condensation. The driver half must not lower the driver or shared totals.
- New/updated driver tests should assert through the shared widgets (e.g. `AppTextField` in the
  auth suites, `AppButton`/`AppEmptyState`/`AppErrorRow` in `offer_sheet_test.dart`,
  `rate_sheet_test.dart`, `rides_history_screen_test.dart`, `trip_screen_test.dart`,
  `home_screen_test.dart`, `driver_shell_test.dart`) without changing the existing keys or
  public signatures.
- **Visual-regression risk (no golden baseline):** only widget tests exist. The migration must
  be pixel-equivalent where tests or the settled decisions pin a value (accent, semantic
  tints, route-polyline blue/grey, sheet radius); capture a manual visual pass of the migrated
  driver screens (Linux FVM or the Windows GUI target) and state honestly if it cannot be run
  here. Golden tests are deferred (product decision).

## Cross-domain notes

- **Canonical owner:** the landed `[design]` foundation in `rider_app_plans/STATUS.md` → Landed
  `[design]` — this plan's `depends_on` capability. The shared tokens/components + rider
  migration are already landed; this plan adopts the landed signature unchanged (never
  edit the shared definition from the driver domain).
- **`rider_app_plans/[rating]_unify_rating_ui.md` (open):** its shared `AppRatingSheet`
  (`shared/lib/src/rating/app_rating_sheet.dart`) should consume these tokens/components. The
  driver `RateSheet` (`driver_app/lib/features/rides/presentation/rate_sheet.dart:8-174`) is the
  join point: whichever lands second, the driver `RateSheet`/`showRateSheet` must be a thin
  wrapper over the shared `AppRatingSheet` **and** use `AppButton`/`AppBottomSheet`/`AppColors`
  (no parallel copy). Coordinate ordering so the driver does not build `RateSheet` twice.
- **`[nav]`:** `AppSidebar`/`AppNav*` and `AppSettings*` already consume tokens; the driver
  shell migration is style-only and must not regress the body-only invariant
  (`driver_app_plans/STATUS.md` → Invariants).
- **API: none.** No endpoint or contract change.

## STATUS.md row to add (this pass)

Add to `driver_app_plans/STATUS.md` → **Open plans**:

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[design]_shared_style_adoption.md` | design | landed `[design]` foundation (`rider_app_plans/STATUS.md`) | Driver migration onto the landed shared tokens/components; delete the driver-local `AuthTextField` in favor of shared `AppTextField`; remove driver hardcoded colors/radii/text styles. No behavior change. |

Do **not** duplicate the shared token/component definitions in the driver STATUS Invariants beyond
a reference to the canonical owner.

On landing: add a one-line `### [design]` Landed entry (driver adoption + `file:line`), remove the
row above, and delete this file (git history is the archive).
