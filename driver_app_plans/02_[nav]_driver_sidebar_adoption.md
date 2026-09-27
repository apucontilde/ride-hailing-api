---
tag: nav
depends_on: ["rider_app_plans/[nav]_shared_sidebar_core.md"]
status: open
---

# Stage 02 — Driver app adopts the shared sidebar / settings / profile core

> **Status: 🟠 OPEN — nothing landed.** `depends_on` is the shared core stage alone: nothing in
> this stage's *work* requires the rider to have landed, and `depends_on` means work
> prerequisites (`.opencode/skills/plan-management/SKILL.md`). **Sequencing interlock, not a
> dependency:** land `rider_app_plans/01_[nav]_rider_sidebar_adoption.md` (stage 01) *first*,
> because the "both sidebars are identical" acceptance criterion is only evaluable once the
> rider has actually adopted the shared widget — parity is the point of this stage, not
> extraction. The two stages are otherwise independent and either may be built alone.
> Nothing here adds a new shared component; if you need one, it belongs in the shared core
> stage.

**Goal:** the driver's sidebar becomes `AppSidebar` with a driver-owned item list, and the
`/settings` and `/profile` screens become the shared widgets. The two apps then share one
sidebar, one settings screen, one profile header, and one menu card, and differ only in
which destinations they list.

## Current state to replace (re-audited today)

- **Sidebar** — `driver_app/lib/features/home/presentation/home_screen.dart:156-193`:
  `Drawer > ListView(EdgeInsets.zero)` (`:157-158`) with a `UserAccountsDrawerHeader`
  (`:160-166`) and 3 items (`:167-174` Profile, `:175-182` `"Ride history & earnings"`,
  `:183-190` Settings). The header is **inert** — no `onDetailsPressed`, no
  `GestureDetector` — unlike the rider's (contrast
  `rider_app/lib/features/home/presentation/home_screen.dart:214-230`). Its
  `accountEmail` slot is abused to show `Status: ${driver?.status ?? 'unknown'}` (`:162`), and
  its avatar is a hardcoded `CircleAvatar(Icon(Icons.person))` (`:163-165`) even though
  `DriverProfile.photoUrl` exists and `ProfileScreen` already uses it
  (`driver_app/lib/features/profile/presentation/profile_screen.dart:203,209-213`).
  `name` is `driver!.fullName` or the literal `'Driver'` (`:75-77`).
- **Open trigger** — the `AppBar` (`:119-155`) declares no `leading`/`actions`, so Flutter
  supplies the implicit hamburger. Nothing to delete; it gets *replaced* by the shared button
  so both apps open the drawer with the same widget.
- **`/vehicle` is unreachable from the drawer** — only from inside `/profile`
  (`driver_app/lib/features/profile/presentation/profile_screen.dart:156-161`). This stage puts
  it in the sidebar (gated, see below).
- **Settings** — `driver_app/lib/features/settings/presentation/settings_screen.dart:15-47`
  (3 `Card > ListTile` rows) + `_confirmSignOut` (`:49-73`), structurally identical to the
  rider's, differing only in `"Driver App"` and the dialog copy *"…to accept ride requests."*
  (`:55`).
- **Profile** — `driver_app/lib/features/profile/presentation/profile_screen.dart`: the private
  `_ProfileHeader` (`:185-257`) with two rider-absent extras — the online dot row (`:222-236`)
  and the star `ratingLabel` row (`:247-254`) — plus the 3-tile menu card (`:153-178`) whose
  `"Ride history"` label (`:163-165`) disagrees with the drawer's `"Ride history & earnings"`
  (`home_screen.dart:175-177`).
- **Zero tests.** There is no `driver_app/test/features/{profile,settings,vehicle}/` directory
  at all, and `home_screen_test.dart` (265 lines, 7 tests) never opens the drawer — this is
  known bug #4 in `driver_app_plans/STATUS.md:40`, which this stage is the first real chance
  to shrink.

## Driver item list (app-owned)

`driver_app/lib/features/navigation/driver_nav_items.dart` (new):

```dart
List<AppNavItem> buildDriverNavItems({
  bool includeVehicle = ApiConfig.vehicleFeatureEnabled,
}) {
  return [
    const AppNavItem(
      destination: AppNavDestination.profile,
      route: '/profile',
    ),
    if (includeVehicle)
      const AppNavItem(
        destination: AppNavDestination.vehicle,
        route: '/vehicle',
      ),
    const AppNavItem(
      destination: AppNavDestination.rideHistory,
      label: 'Ride history & earnings', // the one label override
      route: '/rides-history',
    ),
    const AppNavItem(
      destination: AppNavDestination.settings,
      route: '/settings',
    ),
  ];
}
```

- The `includeVehicle` **parameter** (defaulting to the `const`
  `ApiConfig.vehicleFeatureEnabled`, `driver_app/lib/config.dart:12`, currently `false`) is
  what makes the gated case testable without fighting the const. A sidebar row that opens a
  "Coming soon" screen is worse than no row. Document it — when the vehicle backend leaves
  STUB, flip the flag and the row appears with no other change.
- `"Ride history & earnings"` is the **only** label override, and it is deliberate: earnings
  are a driver-only concept. Icons and sections are never overridden.

## Changes

1. **`home_screen.dart:156-193`** — delete the inline `Drawer` entirely and pass:

   ```dart
   drawer: AppSidebar(
     items: buildDriverNavItems(),
     account: AppSidebarAccount(
       displayName: name,
       statusLabel: driver?.status,
       statusColor: driver?.isOnline == true ? Colors.green : Colors.grey,
       photoUrl: driver?.photoUrl?.isNotEmpty == true ? driver!.photoUrl : null,
       ratingLabel: ratingLabel,
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
       message: 'You will need to log in again to accept ride requests.',
       onSignOut: () => ref.read(authProvider.notifier).logout(),
       onSignOutCompleted: () => context.go('/login'),
     ),
   );
   ```

   The driver header is the one place that genuinely needs the shared widget to do more than
   the rider's: it must stop hiding status in the `accountEmail` slot, it must become tappable,
   and it should show the same online dot + status row the `AppBar` already draws at
   `home_screen.dart:133-148`. **Do not also pass `secondaryLine:`** — that is the rider's
   email line, and passing both renders the status twice. (The `'Status: '` prefix in today's
   `accountEmail` string, `home_screen.dart:162`, disappears with it; `statusLabel` owns the
   visible line now, so tests assert `find.text(driver.status)`, not `'Status: …'`.)
   The avatar is also a **deliberate visible change**: today it is a hardcoded
   `currentAccountPicture: const CircleAvatar(child: Icon(Icons.person))` (`:163-165`), so no
   driver ever sees their photo or initials in the drawer; the shared header shows
   `photoUrl` when set and up-to-two initials otherwise. No `initials:` argument is needed —
   `name` is `'Driver'` when unknown (`:74-77`), whose first letter is already `'D'`.
   ⚠️ **`ratingLabel` is a required new read in this file, and the plan does not leave it
   optional** — it exists only in `profile_screen.dart:66-67` today, sourced from
   `profileNotifierProvider.notifier.ratingSummaryLabel`
   (`features/profile/providers/profile_notifier.dart:40`), and the `AppSidebarAccount` above
   passes it plus the test suite asserts the rating row. Add it as the first statement of
   `build()`, next to the `name`/`driver` reads at `:74-77`:
   `final ratingLabel = ref.read(profileNotifierProvider.notifier).ratingSummaryLabel;`
   and import `../../profile/providers/profile_notifier.dart`. Do not reference an identifier
   that is not in scope, and do not drop the rating to avoid the import — the parity contract
   includes it.
   Keep the `name` and `driver` reads at `:74-77` — they are the driver's.
2. **`home_screen.dart:119-155`** — set `AppBar(leading: const AppSidebarToggleButton(), ...)`
   so the driver opens the sidebar with the *same* button widget the rider uses, rather than
   Flutter's implicit hamburger. Keep the existing title `Row` (avatar + name + status dot) —
   that is driver chrome, not shared chrome.
3. **`settings_screen.dart`** — collapse to `AppSettingsScreen`:

   ```dart
   return AppSettingsScreen(
     appName: 'Driver App',
     appVersion: ApiConfig.appVersion,
     serverUrl: ApiConfig.baseUrl,
     companionAppName: 'rider_app',
     signOutMessage: 'You will need to log in again to accept ride requests.',
     onSignOut: () => ref.read(authProvider.notifier).logout(),
     onSignOutCompleted: () => context.go('/login'),
   );
   ```

   Delete `_confirmSignOut` (`:49-73`). This is the first test coverage
   `settings_screen.dart` has ever had (known bug #4).
4. **`profile_screen.dart`** — swap `_ProfileHeader` (`:185-257`) for `AppProfileHeader`,
   passing the driver's extras (`statusColor`/`statusLabel` from `driver.isOnline`/`status`,
   `statusChipLabel: driver.onboardingStatus.isEmpty ? 'Onboarding pending' : driver.onboardingStatus`
   per `:238-245`, `ratingLabel` from `ratingSummaryLabel` at `:66-67`). ⚠️ **Pass
   `photoUrl: driver.photoUrl?.isNotEmpty == true ? driver.photoUrl : null`** — the shared
   contract declares it and today's header feeds it (`:203,209-213`), so omitting it drops the
   avatar photo. The explicit empty-string test is **not** redundant here:
   `DriverProfile.photoUrl` is passed straight through from JSON
   (`driver_app/lib/features/driver/model/driver_profile.dart:10,30`) and can be `''`, which
   `NetworkImage('')` renders as an error box — the common case for a driver with no photo.
   (Verified against the model file above, **not** driver known bug #3: that row
   (`driver_app_plans/STATUS.md:39`) is about onboarding never `PUT`ing first/last name, which
   is a name bug, not a photo bug. This un-normalised `photo_url` is a real latent defect this
   stage mitigates in the shared widget but does not fix in the model.)
   The shared widget normalises too, but do not hand it the raw value. Swap the edit form
   (`:91-123`, save `Key('profile-save-button')` at `:135`) for `AppProfileForm`, seeded with
   the controller values the current `initState` sets (`:31-32` — first/last only, **`phone`
   stays null**) and wired to
   `onSave: _save` (point the property straight at the method — a function *literal* cannot carry
   a type annotation, so the declared type
   `Future<void> Function({required String firstName, required String lastName, String? phone})`
   belongs in the shared contract, not here). `Future`-returning because `_save()` is `async` and
   `await`s `updateProfile` (`:43-51`), so the shared form can disable the button and show its
   spinner for the duration. ⚠️ **Do not "keep `_save()` unchanged"** — once the shared form owns
   the `Form` and the controllers, `:44` (`_formKey.currentState!.validate()`) and the three
   controller reads at `:46-50` can no longer compile, and the `initState` seeds (`:31-32`) go
   with the controllers. Rewrite it over the callback's named arguments, keeping `:45` and
   `:52-60` verbatim:
   ```dart
   Future<void> _save({required String firstName, required String lastName, String? phone}) async {
     final ok = await ref.read(profileNotifierProvider.notifier).updateProfile(
           firstName: firstName, lastName: lastName, phone: phone,
         );
     if (!mounted) return;
     if (ok) { /* :54-56 snackbar */ } else { FocusScope.of(context).unfocus(); }
   }
   ```
   Validation is not lost — `AppProfileForm` validates its own fields before invoking `onSave` —
   and the `phone: text.isEmpty ? null : text` computation at `:48-50` collapses into the shared
   form's "blank ⇒ null" contract. The `onSave` body keeps everything that is app-side today: the
   `if (!mounted) return;` after the await (`:52`), the `SnackBar('Profile saved')` (`:54-56`)
   and the `FocusScope.of(context).unfocus()` on failure (`:58`). Also pass
   `isSaving: profile.saving` and `errorText: profile.error` from the watched provider state — the
   driver has **no local** saving flag, it reads the notifier's (`profile.saving` at `:135-137`
   disables the button and swaps in the spinner, `profile.error` at `:127` feeds the unkeyed
   `Text` at `:128-132`), so wiring them reproduces today's states instead of dropping them, and
   `Key('profile-error')` moves onto that `Text`.
   `AppNavLinkCard(items: …, onItemSelected: …)` fed from `buildDriverNavItems()` minus
   `profile` (the card's 3 `ListTile` subtitles at `:159,166,173` have no `AppNavItem` field
   and will be dropped — note the loss; no test asserts them).
   ⚠️ **The `_ProfileHeader` you delete is also where the initials and the display-name
   fallback live** — `initials` from first+last (`:191-198`) and
   `displayName: driver.fullName.isEmpty ? 'Driver' : driver.fullName` (`:217`). The shared
   `AppProfileHeader` reproduces the initials rule itself; the `'Driver'` fallback stays
   **app-side** (pass `displayName: driver.fullName.isEmpty ? 'Driver' : driver.fullName`) so
   the shared widget never invents a label. Known bug #3 means a fresh driver's `fullName` is
   empty in practice, so that fallback is the *common* path, not an edge case. **No
   `initials:` argument here** — the old `'D'` guard (`:191-192`) is dead code you should *not*
   port: it fires only when `firstName` **and** `lastName` are both empty (`:192`), but the call site
   passes `driver.fullName` (`:217`), which the `'Driver'` fallback has already replaced. The
   shared rule derives `'D'` from `'Driver'` on its own, and a real name derives the same two
   letters the old getter did (it also joined *all* parts; the shared `take(2)` is equivalent
   for a two-part name). Passing `initials` would be redundant, and the rider's `'R'` guard
   (the rider stage) is a different case precisely because its display name falls back to the email.
   ⚠️ **Keep the driver's `ProfileNotifier` call shape and its empty phone field.** It sends
   only the provided fields (`features/profile/providers/profile_notifier.dart:54,63-69`) and
   does not re-read after save, unlike the rider's (which sends first/last/photo
   unconditionally (the body at `rider_app/lib/features/profile/providers/profile_notifier.dart:70-75`, and the doc comment at `:49-52` explains why leaving one out wipes it server-side)
   — and re-reads the phone). And because the driver's `_save()` sends
   `phone: text.isEmpty ? null : text` (`profile_screen.dart:48-50`), pre-filling the phone
   field from `authProvider` the way the rider does (`:39`) would silently start writing a
   phone value the app never wrote before. Sharing the *form widget* must not reconcile either
   divergence — leave the notifier and the seeds alone. This is also why the shared form's
   phone validator must keep its empty-is-valid wrapper (the shared core stage): a mandatory phone would
   block the driver's only save path entirely.
5. **Reconcile with the two plans that author the same files this stage creates.**
   `[profile]_profile_settings_tests.md` is *independent* (`depends_on: []`) and also creates
   `driver_app/test/features/{profile,settings}/presentation/*_test.dart` — the same two files
   this stage's test list creates. Neither plan depends on the other, so **land one first and
   port the other's assertions**; do not create the files twice.
   - this stage **first** → when you write the two suites, include `[profile]:53,56`'s cases;
     but note its "gated vehicle tile shows 'coming soon'" case (`:55`) is **destroyed** by this
     stage: the `AppNavLinkCard` swap deletes the vehicle `ListTile` at
     `driver_app/.../profile_screen.dart:153-178` and the vehicle row now *vanishes* from the card
     when `vehicleFeatureEnabled` is false. Replace that case with an assertion that the vehicle
     row is **absent** from the card, and leave the vehicle screen's own suite to
     `[profile]` (it is the only plan that covers `test/features/vehicle/`).
   - `[profile]` **first** → extend its two suites instead of creating new ones, and re-point the
     "coming soon" case as above.
   `test/features/vehicle/` stays out of this stage entirely: the flag is `false`
   (`driver_app/lib/config.dart:12`) and this stage does not flip it, so a vehicle suite here
   could only test an unreachable screen. That is `[profile]`'s to own.
6. **Reconcile with the open safety plan's settings entry.** `[safety]_sos_feedback.md:67`
   asks for an "Entry tile from the settings screen", and this stage rewrites that very
   screen. It is deliberately *not* a `depends_on` (the safety plan's other work needs
   nothing from this chain), so handle both orders:
   - safety **not** landed → do **not** add a dead row. Note it and move on; the safety plan
     adds its own `extraSections` entry.
   - safety **already** landed → port its existing row into
     `AppSettingsScreen(extraSections: …)` and add a Risks note saying so, so a reader does
     not think the tile was lost. Either way the row must be an `extraSections` entry (a
     titled group), never a bespoke `Card > ListTile` outside the shared screen.
7. **Add no shims.** New shared symbols are imported from
   `package:ride_hailing_shared/ride_hailing_shared.dart` directly, per the `[nav]` invariant
   in `driver_app_plans/STATUS.md` (the shims exist for *historical* import paths — see
   `AGENTS.md` "Core-file re-export convention").

## Tests

`driver_app/test/features/{profile,settings,vehicle}/` do not exist — creating
`driver_app/test/features/navigation/` and populating `settings/` is the point. The rider's
equivalent stage discovered the same gap: a drawer test needs a **router-backed** harness, or
`context.push` throws. The driver already has the right shape — a bespoke `GoRouter` with
`initialLocation: '/home'` at `driver_app/test/features/home/presentation/home_screen_test.dart:102-119`
(do **not** use `routerProvider`; the app router starts at `/splash`).

**Extend that harness, don't reuse it as-is.** Two things will otherwise make the tests
unpassable:

1. It declares only `/home` and `/trip` (`:106-108`). The new tests `context.push` to
   `/profile`, `/rides-history` and `/settings`, and sign-out goes to `/login` — add a
   `Scaffold` stub for each, or every tap throws.
2. It overrides `driverProfileProvider.overrideWith((ref) => profile)` (`:75`) with a non-null
   `const DriverProfile`, so "assert `driverProfileProvider` is null" can never pass in that
   container. The nulling is real — it happens in `onLoggedOut`
   (`driver_app/lib/core/auth/auth_provider.dart:59-63`) — but only in a container that does
   **not** pin the provider. ⚠️ **And a container that merely omits the override is just as bad:
   `driverProfileProvider` is `StateProvider<DriverProfile?>((ref) => null)`
   (`driver_app/lib/core/auth/auth_provider.dart:18`), so it starts out `null` and the assertion
   would pass even with `onLoggedOut` deleted — a test that cannot fail.** The sign-out assertion
   therefore needs its own container that **seeds a non-null value first**:
   ```dart
   final container = ProviderContainer(overrides: [
     apiClientProvider.overrideWithValue(mockApiClient),
     authStorageProvider.overrideWithValue(mockAuthStorage),   // getRefreshToken() → null, clearTokens() stubbed
     webSocketServiceProvider.overrideWithValue(mockWebSocketService), // disconnect() stubbed
   ]);
   container.read(driverProfileProvider.notifier).state =
       const DriverProfile(userId: 'd1', status: 'online');
   // …pump, sign out, then:
   expect(container.read(driverProfileProvider), isNull);
   ```
   All three overrides are required: `logout()` reaches `authProvider` (`:123-134`), which reads
   storage and the socket, and throws without them. Mirror the controller-level proof at
   `driver_app/test/core/auth/auth_provider_test.dart:286-298`, and assert the **pre**-condition
   (`isNotNull`) in the same test so a future default change cannot silently neuter it.

Also: the AppBar title `Row` keeps rendering `Text(name)` and the status
(`home_screen.dart:130`, `:144-147`), and it stays mounted behind an open drawer — so a bare
`find.text(name)` or `find.text(driver.status)` matches **two** widgets. Scope header finders to
`find.descendant(of: find.byType(AppSidebarHeader), matching: …)` — the *widget*, not
`AppSidebarAccount`, which is a plain value object and never becomes an `Element`.

- `driver_app/test/features/navigation/driver_nav_items_test.dart` (new) — with the default
  `includeVehicle == ApiConfig.vehicleFeatureEnabled` (currently `false`): ids are exactly
  `[profile, ride-history, settings]`, no duplicate ids, sections exactly
  `[account, activity, app]`, and the sole label override is the `ride-history` one. Then call
  `buildDriverNavItems(includeVehicle: true)` and assert `/vehicle` is inserted in the
  `activity` group, between profile and ride-history.
- `driver_app/test/features/navigation/driver_sidebar_test.dart` (new) — pump `HomeScreen`
  under the extended harness, open the drawer via `find.byType(AppSidebarToggleButton)`,
  assert: the section headings appear in enum order; each item is found by
  `Key('sidebar-item-<id>')`; the header shows the driver's name and the status on the **dot
  row** (scoped to `AppSidebarHeader`; not the old `'Status: …'` email-slot string, and *not* a
  `secondaryLine`) and honours `photoUrl`; **tapping the header navigates to `/profile`** (this
  is the behaviour the driver never had — assert it explicitly, it is the headline fix); the
  sign-out footer row is present.
- `driver_app/test/features/navigation/driver_sidebar_test.dart` (extend) — tap each item and
  assert the destination screen (`ProfileScreen`, `RidesHistoryScreen`, `SettingsScreen`); tap
  the drawer sign-out, confirm, assert the router lands on `/login`; and — in the separate
  container described above — assert `driverProfileProvider` is null, the same thing
  `driver_app/test/core/auth/auth_provider_test.dart:283-298` already proves at the controller
  level.
- `driver_app/test/features/settings/presentation/settings_screen_test.dart` (new — this is
  known bug #4) — the three rows render with the driver's app name/version/server URL; the
  sign-out row opens the confirm dialog, cancel keeps the session, confirm clears tokens and
  returns `/login`.
- `driver_app/test/features/profile/presentation/profile_screen_test.dart` (new — also known
  bug #4) — the shared header shows the real name from `/driver/me`, the online dot and rating
  row appear, save still `PUT`s through `ProfileNotifier` (still a *sparse* body, and the
  still-empty phone field must stay empty after a first/last-only save), the `AppNavLinkCard`
  rows still route. ⚠️ `Key('profile-error')` is **new** here, not preserved: the driver's
  error `Text` (`profile_screen.dart:126-131`) carries no key today, unlike the rider's
  (`:137`). Asserting it is asserting the gain. The driver has **no** existing profile tests, so
  unlike the rider this suite is also where the header's own logic gets its first assertions:
  add cases for the two-letter initials (`'Ava' + 'Lopez'` → `'AL'`), the `'Driver'` display-name
  fallback when `fullName` is empty, and the `Chip` showing `onboardingStatus` (or
  `'Onboarding pending'`). Nothing guards them today — that is the point of the new suite.
- **`test/features/vehicle/` is NOT this stage's** — it is the third suite named in known
  bug #4, but it belongs to `[profile]_profile_settings_tests.md` (see Work item 5): the flag is
  `false` (`driver_app/lib/config.dart:12`) and this stage does not flip it, so a vehicle suite
  here could only exercise an unreachable screen. `driver_app_plans/STATUS.md` records the split
  so bug #4 is not double-counted or silently half-closed.

## Acceptance

- `grep -rn "Drawer(\|UserAccountsDrawerHeader" driver_app/lib` returns **zero**.
- `grep -rn "ListTile(" driver_app/lib/features/home/presentation/home_screen.dart
  driver_app/lib/features/profile/presentation/profile_screen.dart
  driver_app/lib/features/settings/presentation/settings_screen.dart` returns **zero** — the
  gate names the three rewritten files on purpose. `ListTile` elsewhere in the driver (e.g.
  `vehicle_screen.dart:73,79`, `rides_history_screen.dart:180`) is out of scope and stays.
- **Parity is now checkable:** the rider's and driver's sidebar call sites differ only in the
  item list and the account fields. Same widget, same theme, same section order.
- `driver_app_plans/STATUS.md` known bug #4 is either resolved or re-scoped with `file:line`
  evidence, and a `[nav]` Landed entry is added.
- `driver_app_plans/STATUS.md` known bug #12 (`:48`) is re-scoped in the same commit, because
  this stage makes "only from inside `/profile`" false — the card row it cites
  (`profile_screen.dart:156-161`) is one of the rows this plan deletes.
- No behaviour change to `/driver/me` reads/writes, to `ProfileNotifier`, to the availability
  toggle (`features/home/providers/availability_notifier.dart`), or to the auth lifecycle.
  Presentation only, with **five** deliberate content changes: (1) the drawer's `"Status: x"`
  email-slot line is replaced by the shared status row (the prefix and the `accountEmail` string
  go away); (2) the drawer avatar stops being a hardcoded person glyph and starts honouring
  `DriverProfile.photoUrl` / initials; (3) the four `AppNavSection` headings
  (`ACCOUNT`, `ACTIVITY`, `SAFETY`, `APP`) appear, where today's drawer lists its items flat under
  the header with no headings; (4) the drawer header becomes tappable (today's
  `UserAccountsDrawerHeader` at `:160-166` has no `onDetailsPressed` and no wrapping tap
  target, unlike the rider's `GestureDetector` at
  `rider_app/lib/features/home/presentation/home_screen.dart:214-218`); and (5) the profile
  card's 3 `ListTile` subtitles (`:159,166,173`) go away, since `AppNavItem` has no subtitle
  field. Each is a content change to record here, not a regression to excuse later. The
  `'Ride history & earnings'` label override and the absence of a `payment`/`security` item are
  unchanged by this stage.
  **(6) `/vehicle` loses its last in-app entry point in the whole driver app.** The 3rd
  `ListTile` card row (`:160`) is the **only** `context.push('/vehicle')` in `driver_app/lib` —
  the only other hit is the route declaration (`app_router.dart:88`). The drawer already omits
  `/vehicle` because `vehicleFeatureEnabled` is `false` (`lib/config.dart:12`) and this stage
  does not flip it, so afterwards the screen is reachable **only by deep link**. This is
  deliberate and matches driver known bug #12, but it removes the sole navigation affordance,
  so it needs its own assertion rather than a shrug: extend
  `driver_app/test/features/navigation/driver_nav_items_test.dart` to assert that with
  `vehicleFeatureEnabled == false` **neither** the drawer **nor** the profile card contains a
  `'/vehicle'` route, so a later change that re-adds one side cannot silently desync the other.
  Re-scope driver known bug #12 in the same commit (`driver_app_plans/STATUS.md:48`) — its
  current text ("only from inside `/profile`") becomes false the moment this stage lands. One of them is a
  **behaviour** fix that also needs a test: the header tap must `closeSidebar(context)` before
  pushing (today's `UserAccountsDrawerHeader` at `:160-166` has no `onDetailsPressed` and no
  wrapping `GestureDetector` at all, so today it is inert — tapping it does nothing). Add an
  assertion that tapping the header lands on `/profile` *with the drawer closed*; the
  "same widget as the rider" criterion below only holds if both call sites pop first.
- The role gate in `driver_app/lib/core/router/app_router.dart:45-47` is untouched and still
  works: an authenticated non-driver never reaches this sidebar (they are redirected to
  `/onboarding`).

## Risks

- **`[safety]_sos_feedback.md` interlock.** It is *not* a `depends_on` (it is independent
  work), but it wants a settings tile in the file this stage rewrites. Land whichever goes
  first and port the row to `extraSections` — see Work item 6.
- **`_ProfileHeader` extras must survive.** The online dot, the `onboardingStatus` `Chip` and the
  rating row are the driver's real differentiators (`profile_screen.dart:222-254`). If the
  shared header is called with plain `AppProfileHeader(displayName: …)` the driver silently
  loses them — the test must assert all three rows. Equally, the *lossy* parts (initials,
  the `'Driver'` label) are literals inside the deleted widget: they must be re-passed
  explicitly, or they disappear untested.
- **Known bug #3 bites here.** Onboarding never `PUT`s `/driver/me`
  (`onboarding_screen.dart:44`), so a fresh driver shows the literal `'Driver'`
  (`home_screen.dart:75-77`) in the sidebar header. That is a `[profile]` bug, not this stage's
  — but the shared header makes it more visible. Do not paper over it with a fake name.
- **The `AppBar(leading:)` change** alters the driver's app bar. Check the title `Row` still
  centres correctly and the status dot is not squeezed.
- **Parity cuts both ways.** After this stage, a change to the shared sidebar silently changes
  the rider. That is the intent, but it means the shared widget's own tests
  (`shared/test/navigation/app_sidebar_test.dart` from the shared core stage) are load-bearing for *both*
  apps, not just the shared package.
- **Stage 01 does not restyle `/onboarding`, `/vehicle` or `/trip` in this stage**, but the
  global `listTileTheme`/`drawerTheme` from the shared core stage does reach them. Check them; that blast
  radius is the shared core stage's risk, surfaced here.

## Verify

```bash
make flutter-analyze
make flutter-test
```
