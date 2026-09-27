---
tag: nav
depends_on: []
status: open
---

# Shared navigation / settings / profile core in `shared/`

> **Status: 🟠 OPEN — nothing landed.** `shared/lib` contains **zero** widgets today: a
> `grep -rn "Drawer\|StatelessWidget\|BuildContext" shared/lib` returns nothing, and the
> package declares `uses-material-design: false` (`shared/pubspec.yaml:29`). This stage adds
> the first UI to the shared package and changes **no app file** — both apps keep their
> hand-rolled drawers and settings screens, so it can be reverted by deleting the new files.
> It is *not* visually inert: the shared `AppTheme` change below restyles `ListTile` in both
> apps (see Risks).
>
> Two adoption stages build on it: stage 01 (`rider_app_plans/01_[nav]_rider_sidebar_adoption.md`)
> and stage 02 (`driver_app_plans/02_[nav]_driver_sidebar_adoption.md`). Do not start either
> before this lands and the `shared/test/**` widget suites are green.

**Goal:** both apps draw the *same* sidebar, the *same* settings rows and the *same* profile
header, while keeping their own (different) destination lists. The shared package owns every
**section** and **component**; each app owns only the list of `AppNavItem`s it passes in.

## Why (the drift, re-audited today)

Both sidebars are hand-rolled `Drawer > ListView > UserAccountsDrawerHeader + N × ListTile`,
with **no menu-item model anywhere** in the monorepo. Concretely, right now:

| | rider | driver |
| --- | --- | --- |
| Drawer code | `rider_app/lib/features/home/presentation/home_screen.dart:199-286` (header 214-230, items 231-270, `_buildDrawerItem` 276-286) | `driver_app/lib/features/home/presentation/home_screen.dart:156-193` (header 160-166, items 167/175/183) |
| Items | Profile, History, Payment, Security, Settings (5) | Profile, Ride history & earnings, Settings (3) |
| Header tappable? | **yes** — `GestureDetector` *and* `onDetailsPressed`, both → `/profile` (`home_screen.dart:214-230`) | **no** — inert, no `onDetailsPressed` (`home_screen.dart:160-166`) |
| Header 2nd line | the user's email (`:221`) | `Status: ${driver?.status}` — the `accountEmail` slot abused for status (`:162`) |
| Header avatar | hardcoded `CircleAvatar(Icon(Icons.person))` (`:222-224`) | hardcoded `CircleAvatar(Icon(Icons.person))` (`:163-165`) |
| Uses `photoUrl`? | **no** — even though `ProfileScreen` does (`profile_screen.dart:235-236`) | **no** — even though `ProfileScreen` does (`profile_screen.dart:203,209-213`) |
| Divider / section headers / selected state | none | none |
| Sign-out in the drawer | **no** (3 taps: drawer → Settings → Sign out) | **no** (2 taps) |
| Open trigger | floating `IconButton(Icons.menu)` over the map, `Positioned(top: padding.top + 8)` + `SafeArea` → **status-bar inset applied twice** (`:179-192`) | AppBar's implicit hamburger (AppBar 119-155 declares no `leading`) |
| `/vehicle` reachable from the drawer? | n/a | **no** — only from inside `/profile` |

The driver header is the one place that genuinely needs the shared widget to do more than
the rider's: it must stop hiding status in the `accountEmail` slot, it must become tappable,
and it should show the same online dot + status row the `AppBar` already draws at
`driver_app/.../home_screen.dart:133-148` (the star rating is *not* in that AppBar — it lives
only in `ProfileScreen` at `:247-254`).

Icons and labels have already drifted between the drawer and the profile screen's menu card,
in the *same* app. The rider's drawer renders `/history` as `Icons.history` + `"History"`
(`rider_app/.../home_screen.dart:240-241`) and `/payment` as `Icons.payment` + `"Payment"`
(`:248-249`); its profile card renders `/history` as `Icons.history` + `"Ride history"`
(`rider_app/.../profile_screen.dart:167-168`) and `/payment` as `Icons.credit_card` +
`"Payment"` (`:174-175`) — same destinations, different icon for payment. The driver has the
label drift: `"Ride history & earnings"` in the drawer
(`driver_app/.../home_screen.dart:175-177`) vs `"Ride history"` in the profile card
(`driver_app/.../profile_screen.dart:164-165`).

Settings is the most obviously duplicated thing in the repo: the two files are
**structurally identical** — same `Scaffold`, same `AppBar('Settings')`, same three
`Card > ListTile` rows with the same icons, same `SizedBox(height: 12)` gaps, same
`_confirmSignOut` body — differing only in the app name and one sentence of dialog copy:

| | rider | driver |
| --- | --- | --- |
| Screen | `rider_app/lib/features/settings/presentation/settings_screen.dart:20-51` | `driver_app/lib/features/settings/presentation/settings_screen.dart:15-47` |
| Row 1 | `Icons.info_outline` / `"Rider App"` / `'v${ApiConfig.appVersion} · companion to driver_app'` (`:25-31`) | `Icons.info_outline` / `"Driver App"` / `'v${ApiConfig.appVersion} · companion to rider_app'` (`:20-27`) |
| Row 2 | `Icons.dns_outlined` / `"Server"` / `ApiConfig.baseUrl` (`:33-39`) | identical (`:29-35`) |
| Row 3 | `Icons.logout` / `"Sign out"` (`:41-47`) | identical (`:37-43`) |
| Sign-out | `_confirmSignOut` (`:53-77`) | `_confirmSignOut` (`:49-73`) — same code, copy differs: *"…to request rides."* vs *"…to accept ride requests."* |

The profile screens drift the same way: `rider_app/.../profile_screen.dart:202-263` and
`driver_app/lib/features/profile/presentation/profile_screen.dart:185-257` are two
hand-rolled `_ProfileHeader` widgets with the same `CircleAvatar(radius: 40)` +
`Colors.blue.shade100` + `NetworkImage` + initials + `Chip` structure, the driver's carrying
two extras (online dot, star rating). They also diverge on a detail the shared form must not
paper over: the rider seeds `_phoneController` from `authProvider.user?.phone`
(`rider_app/.../profile_screen.dart:39`) while the driver seeds only first/last
(`driver_app/.../profile_screen.dart:31-32`), so the driver's phone field starts empty. Both profile screens also own a second hand-rolled menu
card — `Card > Column > ListTile + const Divider(height: 1)`
(`rider_app/.../profile_screen.dart:163-195`, `driver_app/.../profile_screen.dart:153-178`) —
duplicating a subset of the drawer's destinations with drifted labels.

**There is also no shared design vocabulary for any of this.** `AppTheme`
(`shared/lib/src/theme/app_theme.dart:4-33`) is a single `ThemeData` literal with 3
sub-themes (`appBarTheme:11`, `inputDecorationTheme:15`, `elevatedButtonTheme:24`); it has no
`drawerTheme`, no `listTileTheme`, no `TextStyle`, no spacing/radius tokens, and the only color
literal in the whole package is the seed `Color(0xFF1A73E8)` at `app_theme.dart:8`. The only
shape constants are the literal `12` radii at `app_theme.dart:17,28` and the `16`/`14`
paddings at `app_theme.dart:20-21`. So "make them look the same" is currently impossible to
express: there is nowhere to put a shared value.

## Parametrization rules (the seams — do not blur these)

Stage 01 must **not** import `go_router` or either app. `shared/pubspec.yaml` has no
`go_router` and the package is described as the pure core (`AGENTS.md` "Conventions"). Keep
it that way:

1. **Route strings are app-owned.** `AppNavItem.route` is a `String` the app fills in
   (`/history` vs `/rides-history`). `shared` never knows a route table.
2. **Navigation is a callback.** `AppSidebar` and `AppNavLinkCard` both take
   `onItemSelected: ValueChanged<AppNavItem>`; there is no default that navigates. The shared
   helper `closeSidebar(context)` pops the drawer (named to match Flutter's own `openDrawer`);
   the app does `closeSidebar(context); context.push(item.route);` — two identical lines in both
   apps. (`AppNavLinkCard` needs its own callback precisely because the card is used *outside*
   the drawer, on a page where there is nothing to pop.)
3. **Sign-out keeps the app as the owner of session state.** `performAppSignOut` takes
   `onSignOut: Future<void> Function()` and `onSignOutCompleted: VoidCallback?` — the *same*
   parameter name `AppSidebarFooter` takes, so the footer does not rename it. It owns only the
   confirm dialog and the ordering. The app still calls its own
   `ref.read(authProvider.notifier).logout()` and its own `context.go('/login')` — this
   respects the driver invariant *"Don't remove public providers… `core/auth/auth_provider.dart`
   is the single owner of session/token state"* (`driver_app_plans/STATUS.md:70`).
4. **Everything optional is a named parameter with a sensible default**, so stage 01 (rider, 5 items)
   and stage 02 (driver, 3–4 items) render the same component. Divergent *data* is passed in, never
   branched on inside `shared/`. Widget params whose call sites pass `null` are `String?` /
   `IconData?`, and every widget that appears in a `const` call site (`AppSidebarToggleButton`
   in `AppBar(leading:)`) needs a `const` constructor.
5. **No new shims.** The barrel has no `show` clauses (`shared/lib/ride_hailing_shared.dart:1-15`),
   so new symbols are public automatically. The shims exist only for *historical* import paths
   (per `AGENTS.md`); new app code imports
   `package:ride_hailing_shared/ride_hailing_shared.dart` directly (26 files across
   `rider_app/lib` + `driver_app/lib` reference the barrel today: **13 `import` directives** and
   **17 `export … show` directives** across 26 files — 4 files carry *both*, on separate
   directives (`*/core/auth/auth_provider.dart` and `*/core/network/websocket_service.dart` in each
   app), so "13 imports" and "26 files" are not the same set).
   The apps' 1-line theme shims (`rider_app/lib/core/theme/app_theme.dart:1`,
   `driver_app/lib/core/theme/app_theme.dart:1`) stay, because the `AppTheme` symbol is
   historical.

- **`photoUrl` is "absent" when it is null *or* empty — in every widget that takes one**
  (`AppSidebarAccount`, `AppProfileHeader`). ⚠️ The two models disagree and the shared widget
  must absorb it: `RiderProfile` normalises `'' → null` in `fromJson`
  (`rider_app/lib/features/home/model/rider_profile.dart:30`, via `_textOrNull`) and even
  documents the hazard in a getter (`hasPhoto => photoUrl != null && photoUrl!.isNotEmpty`,
  `:49`), while `DriverProfile` passes `json['photo_url']` straight through and can hand you
  `''` (`driver_app/lib/features/driver/model/driver_profile.dart:10,30`). A naive
  `photoUrl != null ? NetworkImage(photoUrl!) : null` therefore calls `NetworkImage('')` for
  every driver with no photo — the common case — which is a red error box
  in a `CircleAvatar` and an unhandled async image error under `flutter_test`. Normalise once,
  in the shared widget: `final photo = (photoUrl ?? '').trim(); final has = photo.isNotEmpty;`
  and branch on `has`. Callers may pass either shape; do not make them pre-normalise.
- **`statusLabel` beats `secondaryLine`.** If both are non-null, render the status row and
  **not** the secondary line — the driver needs one status line, and rendering both duplicates
  it. State the precedence in the widget and cover it in the shared test.

## Shared component inventory — EVERYTHING both apps will share

All new files live under `shared/lib/src/`. Nothing here is adopted by an app in this stage;
this is the contract stages 01/02 implement against.

### `shared/lib/src/navigation/` — the sidebar

| File | Symbol | Responsibility |
| --- | --- | --- |
| `app_nav_destination.dart` | `enum AppNavDestination` | **The single source of truth for id / default label / icon / section.** Enum values carry `id`, `label`, `icon`, `section` via const constructor args. A destination whose route is app-owned still has a canonical id, so both apps name "the same destination" the same way. Members, in declaration order, each as `id` / `label` / `icon` / `section` — the labels are **canonical copy** and belong here, not at the call sites: `profile` (`'profile'`, `'Profile'`, `Icons.person_outline`, `account`), `rideHistory` (`'ride-history'`, `'Ride history'`, `Icons.history`, `activity`), `payment` (`'payment'`, `'Payment'`, `Icons.payment`, `activity`), `vehicle` (`'vehicle'`, `'Vehicle'`, `Icons.directions_car_outlined`, `activity`), `security` (`'security'`, `'Security'`, `Icons.shield_outlined`, `safety`), `settings` (`'settings'`, `'Settings'`, `Icons.settings_outlined`, `app`). ⚠️ The **id strings are kebab-case and are a test contract, not an implementation detail**: `Key('sidebar-item-<id>')` renders them (below) and both stages' mandated nav-item suites assert the exact id lists — rider `[profile, ride-history, payment, security, settings]`, driver `[profile, ride-history, settings]`. Write `'rideHistory'` here and both new suites go red for a reason no analyzer will report. ⚠️ These canonical values **resolve two known drifts**, and both resolutions are recorded content changes. Label: `rideHistory` is `'Ride history'` (the rider's own profile card says exactly that, `rider_app/.../profile_screen.dart:168`). **Both apps keep their own `label` override for it, deliberately** — the rider's drawer says `'History'` (`home_screen.dart:241`) and the driver's says `'Ride history & earnings'` (earnings are a driver-only concept) — and each app's mandated nav-item suite asserts its own exact string, so the divergence is deliberate and greppable rather than accidental. The canonical label is the **default for any other consumer**; it does not force either drawer to change text. An `AppNavItem.label` override is therefore legal (it is how both apps express this), while `icon` and `section` overrides are not (they are the parity guarantee). Icon: `payment` is `Icons.payment` (the drawer, `home_screen.dart:248`), so the rider's profile card's `Icons.credit_card` (`:174`) changes — the second half of rider known bug #9, fixed here. |
| `app_nav_item.dart` | `class AppNavItem` | One rendered row: `destination`, `route`, optional `label`/`icon`/`section` overrides. Exposes `id`, `label`, `icon`, `section`, `route`. `const` ctor. **No `isEnabled`**: the driver gates `/vehicle` by *omitting* the item, so a disabled-tile affordance would have no consumer. |
| `app_nav_section.dart` | `enum AppNavSection` | The fixed section set + its heading text: `account`, `activity`, `safety`, `app`. Fixed so the two sidebars always group the same way. |
| `app_sidebar_account.dart` | `class AppSidebarAccount` | Value object for the header, all fields optional with defaults so `const AppSidebarAccount()` compiles: `displayName: String = ''`, `photoUrl: String?`, `initials: String?`, and an *either/or* pair — `secondaryLine: String?` (the plain line under the name; rider: email) **or** `statusLabel: String?` + `statusColor: Color?` (the dot row; driver). Passing both renders the status twice, so pick one. Optional `ratingLabel: String?` (driver only). |
| `app_sidebar_header.dart` | `class AppSidebarHeader` | Replaces `UserAccountsDrawerHeader`. Whole header is tappable (`onTap`) **in both apps**; avatar honours `photoUrl`; renders the same optional `statusColor`/`statusLabel` dot row and `ratingLabel` row that `AppProfileHeader` has, from the same `AppSidebarAccount` value object. When `initials` is null it derives **up to two** letters itself — the first letter of the first two words of `displayName`, uppercased — because that is what both current headers do (`rider_app/.../profile_screen.dart:208-217`, `driver_app/.../profile_screen.dart:191-198`); the rider's `profile_screen_test.dart:119` asserts the exact string `'AR'`. `secondaryLine` is rendered only when it is non-empty **and** differs from `displayName` (today's "never printed twice" rule, `rider_app/.../profile_screen.dart:249-253`); an empty `displayName` renders the avatar with no name row. |
| `app_sidebar_item.dart` | `class AppSidebarItem` | The row: `leading: IconData` rendered as an explicit `Icon(size: 22)` — **not** a `ListTileThemeData.iconSize`, which does not exist — plus `label: String`, optional `trailing: Widget?`, `selected: bool = false`, `onTap: VoidCallback?`, and `key: Key('sidebar-item-<id>')` so tests find items without string-matching labels. |
| `app_sidebar_section.dart` | `class AppSidebarSectionHeader` | The small uppercase heading between groups. Takes `AppNavSection section` + optional `title: String?` override. |
| `app_sidebar.dart` | `class AppSidebar` | The whole `Drawer`: `Column(children: [Expanded(ListView(padding: EdgeInsets.zero, children: [AppSidebarHeader, …grouped items…])), footer])` — the `ListView` is the scroller, the footer is a sibling so it stays pinned. Params: `items: List<AppNavItem>`, `account: AppSidebarAccount`, `onItemSelected: ValueChanged<AppNavItem>`, `onAccountPressed: VoidCallback?`, `footer: Widget?`, `selectedRoute: String?`. Also exports the top-level helper `void closeSidebar(BuildContext context)` (one line: `Navigator.of(context).pop()`) so both apps write the same two lines — deliberately *not* named `closeAppDrawer`, so the stage-01 gate `grep -rnE "\bDrawer\(" shared/lib` matches exactly one line (a bare `"Drawer("` would also hit `openDrawer(` in the toggle button). `selectedRoute` exists for the follow-up in Risks — no adoption stage passes it yet, so its test is shared-only. |
| `app_sidebar_footer.dart` | `class AppSidebarFooter` | The pinned drawer footer both apps use for sign-out. Owns the `Icons.logout` row + destructive styling and delegates the flow to `performAppSignOut` from `app_sign_out.dart`. Params: `onSignOut: Future<void> Function()`, `onSignOutCompleted: VoidCallback?`, `message: String?`, `key`. |
| `app_sidebar_toggle_button.dart` | `class AppSidebarToggleButton` | The identical hamburger both apps open the sidebar with. **Renders `Icon(Icons.menu)` by default** (`icon: IconData?` overridable) — `rider_app/test/integration/auth_flow_test.dart:132` asserts exactly `find.byIcon(Icons.menu)`, and `icon` defaults to `Icons.menu` so that test keeps passing. Calls `Scaffold.of(context).openDrawer()` (exactly what Flutter's own `DrawerButton` does, so it is safe in an `AppBar(leading:)`). `const` constructor; params `icon: IconData? = Icons.menu`, `style: ButtonStyle?`, `tooltip: String?`. **Positioning stays app-side** — the rider keeps its `Positioned(left: 16)` wrapper. |
| `app_nav_link_card.dart` | `class AppNavLinkCard` | The `Card > Column > ListTile + const Divider(height: 1)` menu card from both profile screens (`rider_app/.../profile_screen.dart:163-195`, `driver_app/.../profile_screen.dart:153-178`). Params: `items: List<AppNavItem>` — **the same type the sidebar takes**, so both surfaces read icon/label from `AppNavDestination` and can no longer disagree — and `onItemSelected: ValueChanged<AppNavItem>`, required. Without it the card cannot navigate: `shared/` has no `go_router` and `AppSidebar`'s callback does not exist outside the drawer, so the app would have to reach past the widget. ⚠️ The 7 `ListTile` **subtitles** in today's cards (`rider_app/.../profile_screen.dart:169,176,183,190`, `driver_app/.../profile_screen.dart:159,166,173`) have no `AppNavItem` field and **will be dropped** — no test asserts them, but stages 01/02 must not claim "no behaviour change to presentation" without saying so. |

Section layout (identical in both apps; only the item list differs):

```
┌ AppSidebarHeader ──────────────────┐   tappable in BOTH apps
│ (avatar) Name                      │   photoUrl honoured
│         email | Status: online     │   secondaryLine XOR statusLabel
├────────────────────────────────────┤
│ ACCOUNT                             │   ← AppSidebarSectionHeader
│   👤 Profile                        │
│ ACTIVITY                            │
│   🕘 Ride history                   │
│   💳 Payment          (rider)      │
│   🚗 Vehicle          (driver*)    │
│ SAFETY                              │
│   🛡 Security          (rider)      │
│ APP                                 │
│   ⚙ Settings                        │
├────────────────────────────────────┤
│ ⏻ Sign out            ← AppSidebarFooter │ pinned, in BOTH apps
└────────────────────────────────────┘
```

`*` the driver gates the vehicle row on `ApiConfig.vehicleFeatureEnabled`
(`driver_app/lib/config.dart:12`).

### `shared/lib/src/settings/` — settings + sign-out

| File | Symbol | Responsibility |
| --- | --- | --- |
| `app_settings_screen.dart` | `class AppSettingsScreen` | The app-info row's subtitle is **exactly** ``'v$appVersion · companion to $companionAppName'`` — `rider_app/test/features/settings/presentation/settings_screen_test.dart:65-68` asserts that literal string, so the separator (`·`), spacing and ordering are part of the contract, not cosmetics. `Scaffold` + `AppBar(title: title)` + `ListView(padding: EdgeInsets.all(24))` (all exactly as both apps have it today) + the `AppSettingsSection`s passed in. Params: `appName: String`, `appVersion: String?`, `serverUrl: String?`, `companionAppName: String?`, `signOutMessage: String?`, `onSignOut: Future<void> Function()`, `onSignOutCompleted: VoidCallback?`, `extraSections: List<AppSettingsSection> = const []`, `title: String = 'Settings'`. |
| `app_settings_section.dart` | `class AppSettingsSection` | A titled group of rows, rendered as one `Card` (matching the current `Card > ListTile` + `SizedBox(height: 12)` rhythm) with an optional heading. Params: `title: String?` (omit for a bare group), `rows: List<AppSettingsRow>`, `icon: IconData?` (optional group icon). Stage 02 (driver) and the safety plan both construct one of these for `extraSections`, so the params must be named here, not invented at adoption time. |
| `app_settings_row.dart` | `class AppSettingsRow` | `leading: IconData?` + `title: String` + `subtitle: String?` + `onTap: VoidCallback?` + `isDestructive: bool = false` (red `Icons.logout` row) + `trailing: Widget?` override. Defaults reproduce the three rows both apps ship today. |
| `app_sign_out.dart` | `showAppSignOutDialog(BuildContext, {String? message})` → `Future<bool>`; `performAppSignOut(BuildContext, {String? message, required Future<void> Function() onSignOut, VoidCallback? onSignOutCompleted})` | The single sign-out flow: `AlertDialog(title: 'Sign out?')` with `TextButton('Cancel')` / `FilledButton('Sign out')`; on confirm `await onSignOut()` then `onSignOutCompleted?.call()`, with `context.mounted` guards. Replaces both copies of `_confirmSignOut`. |

`extraSections` is what unblocks the one open plan that asked for a settings entry tile and
currently has no home for one: `driver_app_plans/[safety]_sos_feedback.md:67` ("Entry tile
from the settings screen"). The rider has no equivalent ask — its SOS button goes in
`security_screen.dart` (`rider_app_plans/[safety]_sos.md:26`), which is already a drawer
destination. Stage 02 (driver) reconciles the driver's row; stage 01 adds nothing here.

### `shared/lib/src/profile/` — profile header and form

| File | Symbol | Responsibility |
| --- | --- | --- |
| `app_profile_header.dart` | `class AppProfileHeader` | The avatar block both `_ProfileHeader` widgets reimplement: `CircleAvatar(radius: 40)` + photo-or-initials, `displayName: String`, optional `secondaryLine: String?` (rider's email), optional `statusColor: Color?` + `statusLabel: String?` dot row (driver), optional `statusChipLabel: String?` (a `Chip`, **used by both apps** — rider `profile.status` at `:256-259`, driver `onboardingStatus` at `:238-245`), optional `ratingLabel: String?` (driver), and optional `initials: String?` (the empty-name case only — see (d)). ⚠️ **`photoUrl: String?` is mandatory to declare and both apps must pass it:** the two `_ProfileHeader`s being deleted both feed the avatar a photo (`rider_app/.../profile_screen.dart:235-236`, `driver_app/.../profile_screen.dart:203,209-213`), so a contract without it drops the photo on *both* profile screens while still compiling — the failure mode is silent, and the stage-01 acceptance gate "every parameter used by the stage-01/stage-02 snippets compiles" cannot catch it. Four behaviours must be **in the shared widget**, not re-implemented per app, because existing tests assert them: (a) initials are the first letters of up to two words, uppercased (`rider_app/.../profile_screen.dart:208-217`, `driver_app/.../profile_screen.dart:191-198` — `profile_screen_test.dart:119` asserts `'AR'`); (b) `secondaryLine` is hidden when it is empty **or equal to `displayName`**, so the email is never printed twice (`rider_app/.../profile_screen.dart:249-253`, asserted by `profile_screen_test.dart:158-160`); (c) the `statusChipLabel` chip renders whenever it is non-null — the rider asserts `find.text('idle')` at `profile_screen_test.dart:117` and that chip is inside the header being deleted; (d) an empty `displayName` renders the avatar alone, with no empty `Text`. ⚠️ `initials: String?` exists for the **empty-name** case only: the `'R'` single-letter fallback is internal to the private widget being deleted (`rider_app/.../profile_screen.dart:210`, which keys on `profile.fullName.isEmpty`), so the rider's profile screen must pass `initials: profile.fullName.isEmpty ? 'R' : null`. Key it on the **profile's** name, not the display name — the display name falls back to the email, so a guard on the display name never fires and the avatar silently renders `'A'`. Left null, a name-less account renders an empty avatar. |
| `app_profile_form.dart` | `class AppProfileForm` | First name / Last name / Phone `TextFormField`s wired to the existing shared `Validators.validateName` / `Validators.validatePhone` (`shared/lib/src/utils/validators.dart:29-48`), seeded by explicit `firstName: String?` / `lastName: String?` / `phone: String?` params (**the driver must pass `phone: null` to keep today's empty field** — its `initState` seeds only first/last, `driver_app/.../profile_screen.dart:31-32`). ⚠️ **The phone field must keep the empty-is-valid wrapper both apps have today**: `value == null \|\| value.trim().isEmpty ? null : Validators.validatePhone(value)` (`rider_app/.../profile_screen.dart:126-131`, `driver_app/.../profile_screen.dart:117-122`, with `hintText: 'Optional'`). Wiring `Validators.validatePhone` directly would make the phone mandatory (`validators.dart:30-32` returns `'Phone number is required'` for empty input) and no `PUT` could ever be sent with an empty phone — the driver's whole first/last-only save, and stage 02's test for it, would be unreachable. Field `labelText`s are exactly `'First name'`, `'Last name'`, `'Phone'` (today's values, `rider_app/.../profile_screen.dart:103,111,122`) — `profile_screen_test.dart:107-108,130-132,170-172,221-223` locate the fields with `find.widgetWithText(TextFormField, <label>)`, so renaming one breaks four tests. Plus: a server-side `errorText: String?` rendered under the fields keyed `Key('profile-error')`, a `FilledButton.icon(key: Key('profile-save-button'))` that shows a `CircularProgressIndicator` while `isSaving`, and the save callback `onSave: Future<void> Function({required String firstName, required String lastName, String? phone})` — **`Future`-returning, because both apps' `_save()` is `await updateProfile(…)`** (`rider_app/.../profile_screen.dart:53-57`, `driver_app/.../profile_screen.dart:43-51`) and the `isSaving` spinner has nothing to await otherwise. **`phone` is null when the field is blank**, which is exactly what the driver's `_save()` computes today (`driver_app/.../profile_screen.dart:48-50`) and is what keeps the rider's unconditional first/last/photo body working (`rider_app/lib/features/profile/providers/profile_notifier.dart:70-75`). The `firstName`/`lastName`/`phone` params are **seeds that are re-applied when they change** (`didUpdateWidget`), which is how the rider's post-save phone re-read (`rider_app/.../profile_screen.dart:60-63`) survives the form taking ownership of the controller: the parent re-passes the fresh phone and the field updates itself. The widget owns its own `Form` + controllers, so the caller no longer holds `TextEditingController`s — it passes plain strings in and an async callback out. `Key('profile-save-button')` is used by **both** apps today (`rider_app/.../profile_screen.dart:145`, `driver_app/.../profile_screen.dart:135`); `Key('profile-error')` exists **only in the rider** (`rider_app/.../profile_screen.dart:137` — the driver's error `Text` at `driver_app/.../profile_screen.dart:126-131` carries no key), so the driver *gains* that key rather than preserving it. |

### `shared/lib/src/theme/app_theme.dart` — the shared visual vocabulary (edit, not new)

Add to `AppTheme.light`, so both apps pick it up through their existing 1-line theme shims
(`rider_app/lib/core/theme/app_theme.dart:1`, `driver_app/lib/core/theme/app_theme.dart:1`)
with no app-side theme edit:

- `drawerTheme` — explicit `width`, `backgroundColor`, `surfaceTintColor`, `elevation`,
  `shape` (today all of these are Material defaults from the 304 dp tier).
- `listTileTheme` — `selectedTileColor`, `selectedColor`, `shape`, `contentPadding`.
  **There is no `iconSize` on `ListTileThemeData`** (it has `iconColor` but no size), so the
  22 dp icon stays on `AppSidebarItem` where `home_screen.dart:282` hardcodes it today.
- `dialogTheme` — the sign-out `AlertDialog` shape.
- Token objects alongside `AppTheme` (same file, so there is still exactly one theme file):
  `AppSpacing` (`xs/sm/md/lg/xl`) and `AppRadii` (`sm/md/lg`), and the sidebar section
  heading `TextStyle`. Today the only radius in the package is the literal `12` at
  `app_theme.dart:17,28` and the only paddings are `16`/`14` at `app_theme.dart:20-21`.

⚠️ `drawerTheme`/`listTileTheme` are **global** `ThemeData` values: they change `ListTile`
rendering on *every* screen in both apps, not just the sidebar. That is intended (it is how
the two apps end up identical) but it is the highest-blast-radius edit in this stage — see
Risks.

### `shared/lib/ride_hailing_shared.dart` + `shared/pubspec.yaml`

- Add one `export` line per new file — **17 lines** (11 nav + 4 settings + 2 profile), or 3
  sub-barrels re-exported from the main barrel. The main barrel is unfiltered, so these are
  pure widening — no `show` clauses, per house style.
- `uses-material-design: false` → `true` (`shared/pubspec.yaml:29`): intent-signalling only.
  Both apps already set `true` (`rider_app/pubspec.yaml:69`, `driver_app/pubspec.yaml:41`)
  and only the *primary* manifest drives font bundling, so this changes nothing at runtime —
  it just stops the shared package from declaring `false` while rendering `Icon`s. Tests are
  not blocked either way (`find.byIcon` matches the widget, not the glyph).

## Work

1. `shared/lib/src/navigation/` — the 11 files above. `AppSidebar` groups `items` by
   `AppNavSection` in the enum's declaration order, skipping empty groups, and lays them out
   as `Column(children: [Expanded(ListView(…)), footer])` so the footer is pinned.
2. `shared/lib/src/settings/` — the 4 files above.
3. `shared/lib/src/profile/` — the 2 files above.
4. Extend `AppTheme` with `drawerTheme`, `listTileTheme`, `dialogTheme`, `AppSpacing`,
   `AppRadii`, and the section-heading text style.
5. Barrel exports + `uses-material-design: true`.
6. **No app file changes in this stage.** Do not add shims.

## Tests — `shared/test/` gains its first widget suites

`shared/test/` is currently 3 pure-function files with no `testWidgets` at all
(`api_error_message_test.dart`, `ride_hailing_shared_test.dart`, `validators_test.dart`).
`flutter_test` is already a dev dependency and `mocktail`/`http_mock_adapter` are already
declared, so nothing new is needed. Follow the existing house style: import the barrel, never
`src/`; single quotes; regression comments that explain *why*.

- `shared/test/navigation/app_nav_item_test.dart` — `AppNavItem` from an
  `AppNavDestination` inherits id/label/icon/section; `label`/`icon`/`section` overrides win.
- `shared/test/navigation/app_sidebar_test.dart` — renders `AppSidebar` with a 5-item list
  and asserts: the four section headings appear in enum order; empty sections are omitted;
  every item is found by `Key('sidebar-item-<id>')` (not by label text); the header renders
  the display name, the secondary line, and initials when `photoUrl` is null; the secondary
  line is **hidden when it equals `displayName`** and hidden when empty; tapping the
  header invokes `onAccountPressed`; tapping an item invokes `onItemSelected` with that item
  and does **not** navigate by itself; `selectedRoute` highlights exactly one row;
  `closeSidebar(context)` pops the enclosing route.
- `shared/test/navigation/app_sidebar_footer_test.dart` — the footer renders the `Icons.logout`
  row, is a sibling of the scrollable (so it stays visible), and delegates to
  `performAppSignOut`.
- `shared/test/navigation/app_sidebar_toggle_button_test.dart` — pumping it inside a
  `Scaffold(drawer: ...)` opens the drawer on tap; it works from an `AppBar(leading:)` and
  from a `Positioned` overlay; `style` overrides the button chrome; and the default icon is
  `Icons.menu` (the regression guard for `auth_flow_test.dart:132`).
- `shared/test/settings/app_settings_screen_test.dart` — renders the default three rows with
  the caller's `appName`/`appVersion`/`serverUrl`; `extraSections` append below the defaults
  (one `AppSettingsSection(title:, rows:)` round-trip, since stage 02 and the safety plan
  both construct one); `performAppSignOut` returns without calling `onSignOut` when the dialog
  is cancelled, calls `onSignOut` then `onSignOutCompleted` when confirmed, and does **not**
  call `onSignOutCompleted` if `onSignOut` throws.
- `shared/test/profile/app_profile_header_test.dart` — initials are the first letters of up to
  two words (`'Ana Rojas'` → `'AR'`); the single-letter fallback when `initials` is supplied;
  photo used when `photoUrl` is set; the status dot and rating rows render only when supplied;
  an empty `displayName` renders no name row.
- `shared/test/profile/app_profile_form_test.dart` — empty **name** fields show the shared
  `Validators` messages; ⚠️ an **empty phone is valid** and shows no error (the regression guard
  for `Validators.validatePhone`'s `'Phone number is required'`), while a non-empty malformed
  phone shows `'Enter a valid phone number'`; the `phone` seed lands in the phone field (and
  `null` leaves it empty); **saving with a blank phone still fires `onSave` with
  `phone: null`** (the guard for the driver's only save path); `onSave` is awaited and the
  button stays disabled until it completes; a changed `phone` prop re-seeds the field (the guard
  for the rider's post-save re-read); save invokes `onSave` with the typed values; `isSaving`
  swaps the label for a spinner and disables the button; the error string renders under
  `Key('profile-error')`.
- `shared/test/navigation/app_nav_link_card_test.dart` — renders `List<AppNavItem>`; rows separated
  by a `Divider(height: 1)`; each row's `onTap` fires `onItemSelected` with its item.

## Acceptance

Core-stage gates (**this** stage is not allowed to change app code, so these are the only ones that
apply while the hand-rolled drawers are still there):

- `grep -rnE "\bDrawer\(" shared/lib` returns **exactly one** hit, and it must be
  `shared/lib/src/navigation/app_sidebar.dart`. The `\b` is load-bearing: a bare
  `grep "Drawer("` also matches `Scaffold.of(context).openDrawer()` in
  `app_sidebar_toggle_button.dart`, and the helper is named `closeSidebar` (not
  `closeAppDrawer`) so it matches nothing either. The **remaining** hazard is a *comment*: the
  same regex happily matches a doc comment that contains the literal ``Drawer(``, and this very
  plan is full of that phrasing — so no comment anywhere under `shared/lib` may spell it. If the
  count is 2+, diff the two hits before assuming the second is a real widget.
- `shared/lib` has no dependency on `go_router` and neither app is imported from `shared/`.
- `shared/pubspec.yaml` no longer declares `uses-material-design: false`.
- Every symbol named in the inventory tables above exists, is exported from the barrel, and
  every parameter used by the stage-01/stage-02 snippets compiles against it. **Read those two
  plans' code blocks before signing this stage off** — they are the contract.
- Both apps' *existing* screens still compile and pass their existing tests, unchanged.

Adoption-stage gates (each of stages 01/02, **not** this one — today the grep below legitimately
returns 5 hits, so do not run it as a core-stage sign-off):

- `grep -rn "Drawer(" rider_app/lib driver_app/lib` returns **zero** — the apps name
  `AppSidebar`, they do not name `Drawer`.
- `grep -rn "UserAccountsDrawerHeader" rider_app/lib driver_app/lib` returns **zero**. The apps
  hand sign-out to the shared widgets as `onSignOut:` / `onSignOutCompleted:` callbacks and never
  call `performAppSignOut` themselves, so do **not** gate on `performAppSignOut(context,` — that
  string matches nothing before, during or after this stage and would be a vacuous gate.

## Risks

- **Four parameters are declared with no consumer — keep them honest.** The same standard that
  dropped `AppNavItem.isEnabled` ("no consumer ⇒ no field") would also drop these, but they are
  declared now so the shared API does not have to change in a later stage:
  `AppSidebar.selectedRoute` (a future selected-row highlight), `AppSidebarAccount.initials`
  (a caller that already has initials), `AppSettingsSection.icon` (a grouped-icon settings
  section), and `AppSettingsRow.isDestructive` / `.trailing` (a sign-out row and a chevron).
  **Neither adoption stage passes any of them.** Each therefore needs a shared-only widget test
  in `shared/test/` proving it renders when supplied and does not crash when left at its
  default — exactly the treatment `selectedRoute` already gets. If a param is still unconsumed
  and untested at the end of the core stage, delete it instead of shipping it.
- **Global theme blast radius — and no test can see it.** Adding `listTileTheme`/`drawerTheme`
  to `AppTheme.light` restyles `ListTile` on every screen in both apps. `AppTheme` reaches the
  apps through exactly two `theme:` uses (`rider_app/lib/app.dart:14`,
  `driver_app/lib/app.dart:32`) plus the two 1-line shims, and four tests do pump the real
  themed widget tree (`rider_app/test/widget_test.dart:9`,
  `rider_app/test/features/auth/presentation/splash_screen_test.dart:13`,
  `rider_app/test/integration/auth_flow_test.dart:103`, `driver_app/test/widget_test.dart:9`) —
  but **none of them asserts any `ListTile` styling**, and the rest of the suite uses a bare
  `MaterialApp`/`MaterialApp.router`. So `make flutter-test` can go green with a visibly wrong
  sidebar. A manual visual pass over the login, register, onboarding, history and trip screens
  is the only real verification: budget for it, and do not let stages 01/02 paper over it.
- **`AppProfileHeader` and `AppProfileForm` are the least mechanical extractions.** The rider
  shows an email and a status `Chip`; the driver shows an online dot, an `onboardingStatus`
  `Chip` and a star rating (`driver_app/.../profile_screen.dart:222-254`). And the driver's
  phone field starts empty while the rider's is seeded
  (`driver_app/lib/features/profile/presentation/profile_screen.dart:31-32` vs
  `rider_app/lib/features/home/presentation/profile_screen.dart:39`), which changes what
  `PUT /driver/me` writes. Resist the temptation to invent a
  single "unified" header/form: keep every extra an optional parameter and keep the seeds
  explicit, so the two keep their own behaviour while the avatar/name block is identical.
- **Screen reachability is deliberately out of scope.** The sidebar exists only on `/home`
  today, so "switch sections" still costs a back-press. `AppSidebar.selectedRoute` is built so
  a future section-level sidebar can highlight the current item, but *making the sidebar
  reachable from every screen is not in these three plans* — it needs a `ShellRoute` or an
  app-wide `drawer:` and a decision about the back-button vs hamburger conflict. Recorded as a
  known bug in both `STATUS.md`s.
- **`_shellKey` is a misnomer** in both routers (`rider_app/lib/core/router/app_router.dart:19`,
  `driver_app/lib/core/router/app_router.dart:18`): it is the root `navigatorKey` and there is
  no shell. Don't build on the name.
- **Parity cuts both ways from stage 02 onward.** A later edit to `AppSidebar` silently
  changes both apps. The `shared/test/navigation/**` suites are therefore load-bearing for the
  apps, not just for the shared package.

## Verify

```bash
make flutter-analyze
make flutter-test
```
