---
tag: nav
depends_on: ["[nav]_shared_sidebar_core.md"]
status: open
---

# Stage 01 — Rider app adopts the shared sidebar / settings / profile core

> **Status: 🟠 OPEN — nothing landed.** The shared core stage
> (`rider_app_plans/[nav]_shared_sidebar_core.md`, unnumbered because it is independent) must
> land first; this stage adds no new shared component. If you find yourself wanting to add
> one, it belongs in the shared core stage.

**Goal:** the rider's sidebar becomes `AppSidebar` with a rider-owned item list, and the
`/settings`, `/profile` screens become the shared widgets. After this stage the rider's sidebar
is pixel-identical in structure to the driver's *by construction* (same widget, same theme) —
stage 02 (driver) only supplies a different item list.

## Current state to replace (re-audited today)

- **Sidebar** — `rider_app/lib/features/home/presentation/home_screen.dart:199-286`:
  `_buildDrawer()` reads `riderProfileProvider` (`:200`) and `authProvider` (`:201`), builds a
  name-or-email fallback (`:204-206`), then `Drawer > ListView(EdgeInsets.zero)` (`:208-210`)
  with a `GestureDetector`-wrapped `UserAccountsDrawerHeader` (`:214-230`) and 5 items
  (`:231-270`) built by `_buildDrawerItem` (`:276-286`). Wired at `drawer: _buildDrawer()`
  (`:91`) on a `Scaffold` keyed by `_scaffoldKey` (`:21`, `:85`).
- **Open trigger** — `Positioned(top: MediaQuery.padding.top + 8, left: 16, child: SafeArea(
  child: IconButton(Icon(Icons.menu), onPressed: () => _scaffoldKey.currentState?.openDrawer(),
  style: IconButton.styleFrom(backgroundColor: Colors.white, elevation: 2))))`
  (`:179-192`). The status-bar inset is applied twice: once in the `Positioned` and again by
  the `SafeArea`.
- **Settings** — `rider_app/lib/features/settings/presentation/settings_screen.dart:20-51`
  (3 hardcoded `Card > ListTile` rows) + `_confirmSignOut` (`:53-77`). Its doc comment at
  `:14` points at `rider_app_plans/13_real_profile_and_account.md`, a file deleted in
  `a4ce42c` — fix the pointer while you are in here.
- **Profile** — `rider_app/lib/features/home/presentation/profile_screen.dart`: the private
  `_ProfileHeader` (`:202-263`), the first/last/phone edit form (`:100-132`, save
  `Key('profile-save-button')` at `:145`, error `Key('profile-error')` at `:137`, controller
  seeds at `:37-39`), and the 4-tile menu card (`:163-195`) whose labels/icons already
  disagree with the drawer — the drawer calls `/history` `"History"`
  (`home_screen.dart:240-241`) and `/payment` `Icons.payment` (`:248-249`), the card calls them
  `"Ride history"` (`:167-168`) and `Icons.credit_card` (`:174-175`).
- **Only one test touches the drawer** — `rider_app/test/features/home/presentation/home_screen_test.dart:63-105`
  ("drawer header shows the signed-in rider, not a literal") opens it via
  `find.byIcon(Icons.menu)` and asserts the name/email. There is **no** test asserting the
  drawer's contents, its item order, or that any item navigates.

## Rider item list (app-owned; the routes are the seam)

`rider_app/lib/features/navigation/rider_nav_items.dart` (new, ~25 lines) — one function, no
providers, no imports beyond the shared barrel:

```dart
List<AppNavItem> buildRiderNavItems() => const [
      AppNavItem(
        destination: AppNavDestination.profile,
        route: '/profile',
      ),
      AppNavItem(
        destination: AppNavDestination.rideHistory,
        route: '/history',
      ),
      AppNavItem(
        destination: AppNavDestination.payment,
        route: '/payment',
      ),
      AppNavItem(
        destination: AppNavDestination.security,
        route: '/security',
      ),
      AppNavItem(
        destination: AppNavDestination.settings,
        route: '/settings',
      ),
    ];
```

Do **not** override `icon` or `section` — those two are the parity guarantees and the mandated
`rider_nav_items_test.dart` asserts both equal the canonical values. A `label` override *is*
allowed and both apps need one (the canonical `rideHistory` label is `'Ride history'`, but the
rider's drawer says `'History'` and the driver's says `'Ride history & earnings'` — earnings are a
driver-only concept). The rider's override is `AppNavItem(destination: AppNavDestination
.rideHistory, label: 'History', route: '/history')`, and its test must assert that exact string
so the two apps' divergence is deliberate and greppable rather than accidental. The drawer and the
profile card still cannot disagree, because both read the *same* `AppNavItem` list. The
`route` strings are literals today because neither router has `name:` on any `GoRoute`
(`rider_app/lib/core/router/app_router.dart:38-99`); leave that alone, the shared item takes
a `String`.

## Changes

1. **`home_screen.dart:199-286`** — delete `_buildDrawer()` and `_buildDrawerItem`. Replace
   `drawer: _buildDrawer()` (`:91`) with:

   ```dart
   drawer: AppSidebar(
     items: buildRiderNavItems(),
     account: AppSidebarAccount(
       displayName: name,
       secondaryLine: email.isEmpty ? null : email,
       photoUrl: profile?.hasPhoto == true ? profile!.photoUrl : null,
     ),
     onAccountPressed: () {
       closeSidebar(context);
       context.push('/profile');
     },
     onItemSelected: (item) {
       closeSidebar(context);
       context.push(item.route);
     },
     footer: AppSidebarFooter(
       message: 'You will need to log in again to request rides.',
       onSignOut: () => ref.read(authProvider.notifier).logout(),
       onSignOutCompleted: () => context.go('/login'),
     ),
   );
   ```

   Keep the existing `ref.watch(riderProfileProvider)` / `ref.watch(authProvider)` reads
   (`:200-201`) and the name-or-email fallback (`:204-206`) — that logic is the rider's, not
   the shared widget's. `AppSidebarHeader` derives the initials itself (up to **two** letters,
   the same rule the profile screen uses at `profile_screen.dart:208-217`), so the drawer passes
   no `initials` at all. ⚠️ **Do not claim the drawer already shows initials or a photo — it does
   not.** Today the drawer passes a hardcoded `currentAccountPicture: const CircleAvatar(child:
   Icon(Icons.person))` (`home_screen.dart:222-224` — `:220-221` are `accountName`/
   `accountEmail`), which *overrides* the initials
   `UserAccountsDrawerHeader` would otherwise derive, so the avatar is a generic person glyph for
   every rider. Handing the account to the shared header makes it show `photoUrl` when set
   (rider bug #11) and up-to-two initials otherwise — a deliberate, visible change; list it in
   Acceptance. The `'R'` literal (`profile_screen.dart:210`) belongs to the *profile screen*
   header, not the drawer: it guards a name-less *profile*, whereas the drawer's display name
   falls back to the email and `'A'` is what the shared rule already yields. See Work item 5.
   The rider shows no status dot and no rating, so `statusLabel`/`ratingLabel` stay null.
2. **Sign-out moves into the drawer.** `/settings` keeps its sign-out row (both apps agree on
   that), but the drawer now also offers it. The rider's logout journey drops from 3 taps to
   1 and the copy stays byte-identical to today's dialog text
   (`settings_screen.dart:59`).
3. **`home_screen.dart:179-192`** — replace the hand-rolled floating `IconButton` with
   `AppSidebarToggleButton`, keeping the app-side `Positioned(left: 16, child: SafeArea(...))`
   and passing
   `style: IconButton.styleFrom(backgroundColor: Colors.white, elevation: 2)` so the button
   still reads over the map. This kills the double top-inset: `Positioned(top: …)` currently
   adds `padding.top` **and** the `SafeArea` adds it again — use `Positioned(top: 8, …)` and
   let the `SafeArea` own the inset. The rider's home has no `AppBar` on purpose (the map is
   edge-to-edge). If `_scaffoldKey` is then unused, remove it (`:21`, `:85`) rather than
   leaving a dead key.
4. **`settings_screen.dart`** — collapse to the shared screen: `Scaffold`/`AppBar`/rows all
   move into `AppSettingsScreen`. The screen becomes roughly:

   ```dart
   return AppSettingsScreen(
     appName: 'Rider App',
     appVersion: ApiConfig.appVersion,
     serverUrl: ApiConfig.baseUrl,
     companionAppName: 'driver_app',
     signOutMessage: 'You will need to log in again to request rides.',
     onSignOut: () => ref.read(authProvider.notifier).logout(),
     onSignOutCompleted: () => context.go('/login'),
   );
   ```

   Delete `_confirmSignOut` (`:53-77`) and the stale doc pointer at `:14`. When you update
   `rider_app_plans/STATUS.md`, **re-point the `[auth]` Landed entry's drawer-header evidence**
   (`rider_app_plans/STATUS.md:41`, currently `features/home/presentation/home_screen.dart:199-230`):
   those lines are the hand-rolled header this stage deletes, so the citation would rot. Point
   it at the `AppSidebar(` call site in `build()` (the `drawer:` argument, `home_screen.dart:91`
   today) instead — the
   capability the entry claims (the drawer shows the signed-in rider, not a literal) still holds,
   the evidence just moves.
5. **`profile_screen.dart`** — swap `_ProfileHeader` (`:202-263`) for `AppProfileHeader`, and
   the three `TextFormField`s + save button (`:100-132`, `:137`, `:145`) for `AppProfileForm`
   seeded with the controller values the current `initState` sets (`:37-39`, including
   `authProvider.user?.phone`). ⚠️ **Do not "keep `_save()` unchanged"** — once the shared form
   owns the `Form` and the controllers, three statements in it can no longer compile: `:51`
   (`_formKey.currentState!.validate()`), `:52` (`_phoneController.text.trim()`) and `:56`/`:63`
   (`_phoneController` again), and the three `initState` seeds at `:37-39` go with the
   controllers. Rewrite it as a thin wrapper over the callback's named arguments, deleting
   exactly those lines and keeping the rest verbatim:
   ```dart
   Future<void> _save({required String firstName, required String lastName, String? phone}) async {
     final ok = await ref.read(profileNotifierProvider.notifier).updateProfile(
           firstName: firstName, lastName: lastName, phone: phone,
         );
     if (!mounted) return;
     if (ok) { /* :60-63 re-read, :64-68 snackbar/unfocus */ } else { FocusScope.of(context).unfocus(); }
   }
   ```
   The `updateProfile(...)` call at `:53-57` needs no change — `phone` arrives already `null`
   when blank, which is what the old `phone.isEmpty ? null : phone` computed. Keep the post-save
   phone re-read (`:60-63`), which the driver's version does not have and must not be copied.
   The `_ProfileHeader` you delete is also where four pieces of behaviour live, all of them
   asserted by `profile_screen_test.dart`:
   - the **two-letter initials** (`:208-217`) — asserted as `'AR'` at `:119`;
   - the **`fullName → email → ''` display-name fallback** (`:221-224`) with its
     "email hidden when it *is* the name" rule (`:249-253`) — asserted at `:135-164`;
   - the **`status` `Chip`** (`:256-259`) — asserted as `find.text('idle')` at `:117`. Nothing
     else on the screen prints the status, so dropping this chip turns that test red. Pass
     `statusChipLabel: profile.status`.
   - the **`'R'` single-letter initial** when `profile.fullName` is empty (`:210`), which is a
     local literal, not app state. Pass `initials: profile.fullName.isEmpty ? 'R' : null` —
     keyed on the **profile's** name, not the display name, which falls back to the email and
     would silently render `'A'`. `AppProfileHeader` cannot invent it.
   The first three are specified on the shared widgets in the shared core stage; pass the data
   (`displayName: profile.fullName.isNotEmpty ? profile.fullName : (email ?? '')`,
   `secondaryLine: email`) rather than pre-computing a single string. **Also pass
   `photoUrl: profile.photoUrl`** — the shared contract declares it and today's header feeds it
   (`:235-236`), so leaving it out drops the avatar photo on the profile screen. No `?.`: this
   call site is inside the `body: profile == null ? … : ListView(…)` branch
   (`rider_app/.../profile_screen.dart:80-81`), so Dart has already promoted `profile` to
   non-nullable and `unnecessary_null_aware_operator` (a `flutter_lints` rule both
   `rider_app/analysis_options.yaml` and `shared/analysis_options.yaml` include, and fatal under
   `flutter analyze`) would reject the `?.`. The rider's
   model already normalises `'' → null` (`rider_app/lib/features/home/model/rider_profile.dart:30`),
   so no empty-string guard is needed here — but pass it raw anyway and let the shared widget
   normalise (the contract treats null and empty identically), because the driver cannot. Wire the form's
   `onSave: _save` — the widget now owns the controllers, so `_save()` reads its typed values
   from the callback's named arguments instead of from `TextEditingController`s, and `onSave` is
   `Future`-returning because `_save()` awaits `updateProfile`. Pass `isSaving: state.saving` (the button's `onPressed` disable at `:146`)
   and `errorText: state.error` (the `Text` at `:133-141`, which already carries
   `Key('profile-error')` at `:137`) so the shared form reproduces today's states; the
   `SnackBar('Profile saved')` and `FocusScope.of(context).unfocus()` (`:64-68`) stay in the
   `onSave` body. The post-save phone re-read (`:60-63`) survives too: store the fresh value
   in a `setState` field and pass it back as the form's `phone` seed, which re-applies it to the
   field. `profile_screen_test.dart:228` asserts exactly that (`+5065559999` appears after the
   save) — do not lose it.
   Swap the 4-tile menu card (`:163-195`) for `AppNavLinkCard(items: …, onItemSelected: …)`
   fed from the same `buildRiderNavItems()` list (minus `profile` itself, which is the page you
   are on), so the drawer and the profile card can no longer disagree about an icon or a label.
   ⚠️ The card's 4 `ListTile` **subtitles** (`:169,176,183,190`) have no `AppNavItem` field and
   will be dropped — `AppNavItem` carries label/icon/route only. No test asserts them; note the
   loss in the commit rather than adding a subtitle field to the shared type.
6. **Add no shims.** New shared symbols are imported from
   `package:ride_hailing_shared/ride_hailing_shared.dart` directly, per the `[nav]` invariant
   in `rider_app_plans/STATUS.md` (the shims exist for *historical* import paths — see
   `AGENTS.md` "Core-file re-export convention").

## Tests

The rider has **no bespoke router harness for `HomeScreen`**: the existing
`home_screen_test.dart` pumps `HomeScreen` with no `GoRouter` at all (the drawer test at
`:91-96` wraps it in `UncontrolledProviderScope(child: const MaterialApp(home: HomeScreen()))`),
so `context.push('/profile')` would throw. (Four other tests do touch the real router —
`rider_app/test/widget_test.dart:9` and `rider_app/test/features/auth/presentation/splash_screen_test.dart:13`
pump the whole `RiderApp`, `rider_app/test/integration/auth_flow_test.dart:103` drives it through
registration to `/home`, and `rider_app/test/core/router/app_router_test.dart:14,23,25`
exercises `routerProvider` — but none is a `HomeScreen` harness with stub destination routes, so
none can be extended into one.) The navigation assertions below therefore need a **new**
harness, and it must be a bespoke one — **not** `ref.read(routerProvider)`. The real router
starts at `/splash` (`rider_app/lib/core/router/app_router.dart:24`) and the redirect passes
splash through (`:33`), so frame 1 is `SplashScreen`, which awaits `checkAuth()`
(`rider_app/lib/features/auth/presentation/splash_screen.dart:22`) and then
`currentRideProvider.notifier.checkOnce()` (`:26`) before it navigates at all
(`splash_screen.dart:28-36`): it only reaches `context.go('/home')` (`:32`) if `authProvider`
reports authenticated, otherwise `context.go('/login')` (`:35`). So the real router needs an
**authenticated-state override** before the drawer is ever on screen. A current-ride stub is
*not* required — the `GET /rides/current` at
`rider_app/lib/features/home/data/current_ride_provider.dart:97` is swallowed by the bare
`catch (_)` at `:108-110`, leaving `needsRestore` false — but stub it anyway for determinism.

Build the harness the way the rider's other screen tests already do: a plain `GoRouter` with
`initialLocation: '/home'` and a `Scaffold` stub for each destination, as in
`rider_app/test/features/settings/presentation/settings_screen_test.dart:40-54` and
`rider_app/test/features/home/presentation/profile_screen_test.dart:80-105`. Declare
`/home`, `/profile`, `/history`, `/payment`, `/security`, `/settings` and `/login` (the
redirect target of sign-out). Do not retrofit the existing harness; keep its 2 drawer-free tests
where they are — the third migrates below, so 3 survive in total across the two files.
- `rider_app/test/features/navigation/rider_nav_items_test.dart` (new) — the list has 5 items;
  **no duplicate ids**; ids are exactly `[profile, ride-history, payment, security, settings]`;
  sections are exactly `[account, activity, activity, safety, app]`; every `icon` and `section`
  is the canonical one from `AppNavDestination` (assert no `icon:`/`section:` override slipped
  in); and the **only** `label` override is the asserted `'History'` on `rideHistory` — assert
  the other four labels equal their canonical values, so a second override cannot creep in.
- `rider_app/test/features/navigation/rider_sidebar_test.dart` (new) — pump `HomeScreen` under
  the new harness with the same `ProviderContainer` overrides the existing header test uses for
  `/rider/me` (`home_screen_test.dart:63-105`), open the drawer via
  `find.byType(AppSidebarToggleButton)`, then assert: the account section heading appears; each
  item is found by `Key('sidebar-item-<id>')`; the sign-out footer row is present; the four
  section headings appear in order; the header shows the real name and the email on its own
  line. (No descendant scoping needed here, unlike stage 02 (driver): the rider's home screen renders the
  name/email *only* inside the drawer — `home_screen.dart:220-221` — and `ProfileScreen` is a
  pushed route, not a sibling behind the open drawer.) Migrate and keep the existing
  `"drawer header shows the signed-in rider, not a literal"` assertion
  (`home_screen_test.dart:63-105`) into this file — it must keep passing, **including its
  `find.byIcon(Icons.menu)` tap at `:99` and its `find.text('Rider'), findsNothing` guard at
  `:104`**: the first survives because `AppSidebarToggleButton` defaults to `Icons.menu`. The
  second is a **historical placeholder** — nothing in either app would ever pass `'Rider'` as a
  status — so it stays green because neither the shared header nor the app produces that
  literal. Do not invent a mechanism for it, and do not let a later stage pass `'Rider'` as a
  `statusLabel`.
- `rider_app/test/features/navigation/rider_sidebar_test.dart` (extend) — **navigation
  coverage, which the app has never had**: tap each of the 5 items in turn and assert the
  destination screen appears (`ProfileScreen`, `HistoryScreen`, `PaymentScreen`,
  `SecurityScreen`, `SettingsScreen`); tap the header and assert `ProfileScreen`; tap the
  drawer sign-out row, confirm the dialog, and assert the router lands on `/login` and
  `riderProfileProvider` is null — the rider's profile cache really is cleared by
  `onLoggedOut` (`rider_app/lib/core/auth/auth_provider.dart:54-58`).
  ⚠️ **That assertion cannot fail in a container that never seeded the profile**:
  `riderProfileProvider` is `StateProvider<RiderProfile?>((ref) => null)`
  (`rider_app/lib/core/auth/auth_provider.dart:20`), exactly like the driver's, so it starts out
  `null` and the test would pass even with `onLoggedOut` deleted. This case needs its own
  container that **seeds a non-null value first** — the same recipe the driver stage mandates,
  and the same one the existing controller-level test already uses when it seeds at
  `auth_provider_test.dart:453` before asserting at `:466`:
  ```dart
  final container = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(mockApiClient),
    authStorageProvider.overrideWithValue(mockAuthStorage),   // getRefreshToken() → null, clearTokens() stubbed
    webSocketServiceProvider.overrideWithValue(mockWebSocketService), // disconnect() stubbed
  ]);
  container.read(riderProfileProvider.notifier).state =
      const RiderProfile(userId: 'r1', firstName: 'Ada', lastName: 'Rider');
  // …pump, sign out, then:
  expect(container.read(riderProfileProvider), isNull);
  ```
  All three overrides are required: `logout()` reaches `authProvider`
  (`rider_app/lib/core/auth/auth_provider.dart:102-115`), which reads storage and the socket and
  throws without them. Assert the **pre**-condition (`isNotNull`) in the same test so a future
  default change cannot silently neuter it.
- `rider_app/test/features/settings/presentation/settings_screen_test.dart` (extend) — the
  three rows still render with the rider's app name and version; the sign-out row still opens
  the confirm dialog, cancel keeps the session, confirm clears and returns `/login`
  (these cases already exist at `:59-118` — they must not be deleted, only re-pointed at the
  shared widget).
- `rider_app/test/features/home/presentation/profile_screen_test.dart` (extend) — the shared
  header still shows the real name/email from `/rider/me`; the save button still
  `PUT`s through `ProfileNotifier` and still shows `Key('profile-error')` on invalid input; the
  `AppNavLinkCard` rows still route (the existing `"Settings tile routes to /settings"`
  assertion at `:310-317`) via its new `onItemSelected`.
  ⚠️ **Four** existing assertions here break if the extraction drops behaviour, and they do not
  all live in the same widget. **Three** are `_ProfileHeader` internals: the status `Chip`
  (`find.text('idle')`, `:117`), the **two-letter initials** `'AR'` (`:119`), and the
  **email-as-display-name fallback** with the name-less account (`:135-164`). The **fourth**
  (`:132`) is a **seed** assertion, not a header one — it reads the seeded
  `TextFormField.controller.text` through the test's own `field()` helper (`:107-108`) and stays
  green because `AppProfileForm` owns its controllers and re-applies the `phone` seed. A
  *separate* concern keeps `:166-179` (malformed phone → `'Enter a valid phone number'`) green:
  the validator's `value == null || value.trim().isEmpty → null` short-circuit at
  `rider_app/.../profile_screen.dart:126-131`. All four must keep passing unchanged — which is
  why the initials rule, the "email hidden when it *is* the name" rule, the chip and the
  optional-phone rule are all specified on the shared widgets in the shared core stage, and why
  the `'R'` empty-name initial stays app-side here.
- `rider_app/test/integration/auth_flow_test.dart:132` — the existing
  `expect(find.byIcon(Icons.menu), findsOneWidget)` must keep passing. `AppSidebarToggleButton`
  must therefore still render `Icon(Icons.menu)`, or this assertion moves to
  `find.byType(AppSidebarToggleButton)` in the same commit.

## Acceptance

- `grep -rn "Drawer(\|UserAccountsDrawerHeader" rider_app/lib` returns **zero**, and
  `_buildDrawer`/`_buildDrawerItem` are gone.
- `grep -rn "ListTile(" rider_app/lib/features/home/presentation/home_screen.dart
  rider_app/lib/features/home/presentation/profile_screen.dart
  rider_app/lib/features/settings/presentation/settings_screen.dart` returns **zero** — the gate
  names the three rewritten files on purpose. `ListTile` elsewhere in the rider (e.g.
  `location_search_screen.dart:75`) is out of scope and stays.
- `grep -n "AppSidebar(" rider_app/lib/features/home/presentation/home_screen.dart` returns
  **exactly one** hit, and it is the rider's only drawer construction. Parity with the driver is
  *not* checkable here — it is stage 02 (driver)'s criterion, and only once both have landed.
- Every rider destination that was reachable from the drawer is still reachable, and sign-out
  is now also one tap from the drawer.
- No behaviour change to `/rider/me` reads/writes, to `ProfileNotifier`, or to the auth
  lifecycle. This stage is presentation only — with four deliberate content changes: the profile
  card's 4 `ListTile` subtitles go away; the drawer header starts honouring
  `RiderProfile.photoUrl` and falls back to initials instead of a hardcoded person glyph (that
  is rider bug #11 being fixed here, not a regression); the four `AppNavSection` headings
  (`ACCOUNT`, `ACTIVITY`, `SAFETY`, `APP`) appear, where today's drawer lists its five items
  flat under the header with no headings at all; and the header's photo tap is now a real tap
  target — the shared header's whole-header `onTap` replaces today's wrapping
  `GestureDetector` at `home_screen.dart:214-219` (which is deleted with the rest of
  `_buildDrawer()`, so `onDetailsPressed` is no longer needed) and must keep today's
  **pop-then-push** order (`:215-217`) via `closeSidebar(context)` first, or the drawer stays open over
  `/profile`. Nothing currently asserts that order — add it.
- `rider_app_plans/STATUS.md` gains a `[nav]` Landed entry with `file:line` evidence.
- `AGENTS.md` is updated in the same commit (**not conditional**): add the new shared widgets
  (`AppSidebar*`, `AppSettings*`, `AppProfile*`, `AppNav*`) to the `shared/` contents list in the
  Repo-layout bullet — that list is an inventory and goes stale the moment this lands — and add a
  `shared/lib` widget-testing note (the package gains its first widget tests, and
  `uses-material-design: false` becomes wrong).

## Risks

- **Don't lose the existing tests.** `home_screen_test.dart:63-105`,
  `settings_screen_test.dart:59-118`, `profile_screen_test.dart:117`/`:119`/`:132`/`:135-164`/`:310-317`
  and `auth_flow_test.dart:132` are the only guard rails on these surfaces. If one no longer
  applies, say why in the plan file — do not quietly delete it. All **five** of the
  `profile_screen_test.dart` assertions cited here live *inside* the widgets being replaced
  (`:117`/`:119`/`:135-164` in `_ProfileHeader`, `:132` in the form, `:310-317` in the tile
  card), so they are the likeliest casualties.
- **Deleting `_ProfileHeader` deletes logic, not just layout.** Its initials, its display-name
  fallback, its "never print the email twice" rule and its status `Chip` are asserted by
  `profile_screen_test.dart:117`, `:119` and `:135-164`. If the shared `AppProfileHeader` does
  not reproduce them exactly, the stage fails on its own tests — fix the shared widget, do not
  relax the assertions.
- **`[tracking]_ride_detail_receipt_rating.md` will add new destinations.** They must be added
  to `buildRiderNavItems()` (and only there) or they will be unreachable from the drawer. Note
  it in that plan's `depends_on` when it lands.
- **`AppSettingsScreen` removes the per-row `Card` structure's flexibility** (rows are grouped
  into sections). If the rider's `[safety]_sos.md` lands first, its settings entry becomes an
  `extraSections` entry rather than a bespoke row.
- **Widget tests pump `HomeScreen` with `ProviderContainer` overrides.** The drawer now also
  reads `authProvider` for logout; make sure the existing overrides still satisfy it, and that
  the **3** existing `rider_app/test/features/home/presentation/home_screen_test.dart` tests
  (`:47`, `:55`, `:63`) don't break for a reason unrelated to the drawer.

## Verify

```bash
make flutter-analyze
make flutter-test
```
