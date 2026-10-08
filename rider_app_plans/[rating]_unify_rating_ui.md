---
tag: rating
depends_on: []
status: open
---

# [rating] Unify the rating UI into one shared component

> Cross-app presentation unification. No endpoint, request, or `RatingStatus` logic change.
> Owner: `rider-planner` (driver adoption coordinated with `driver-planner`).
> Verify: `melos run analyze` + `melos run test`.

## Goal

There is exactly **one** rating form in the rider app and **one** in the driver app, and they
do the same job with materially different UI, validation and submit semantics. Unify the
presentation into a single reusable widget in `ride_hailing_shared`, consumed by both apps,
while keeping each app's API call and rating-status gate untouched.

## Current state (verified)

### The rider app has one rating form (the task premise of "two in the rider app" is not borne out)

- `RatingPromptDialog` — `rider_app/lib/features/home/presentation/rating_prompt_dialog.dart:15-87`.
  An `AlertDialog` ("Rate your ride") with five `IconButton` stars. Tapping a star **submits
  immediately**; there is no comment field and no separate submit button. Stars are disabled
  while `RideDetailState.isRating` (`:41-42,55-56`), an inline error text renders on failure
  (`:70-76`), and there is a `Skip` action (`:79-83`).
- It is opened from exactly one place: the post-completion flow
  `rider_app/lib/features/home/presentation/active_ride_screen.dart:352-369`
  (`_promptRating`), which gates on `riderRideRatingStatusProvider(rideId)` and
  `RideDetailState.canRate(rideId)` (`:357-363`) and passes the dialog the ride id.
- A grep for the rider rating UI (`Icons.star`, `rating-star`, `Rate your`) finds only
  `rating_prompt_dialog.dart`; the rider history tile
  (`features/home/presentation/history_screen.dart:109-181`) has **no** rating entry.

### The second, parallel form is in the driver app

- `RateSheet` + `showRateSheet` — `driver_app/lib/features/rides/presentation/rate_sheet.dart:8-174`.
  A modal bottom sheet ("Rate your rider") with a star row that only **selects** until a
  separate `Submit rating` button (`:153-163`) is pressed; an optional 280-char comment
  `TextField` (`:131-142`); local `_submitting` disabling (`:46,118-120`); inline error
  (`:143-151`); `Not now` skip (`:164-168`).
- It is opened from **two** driver entry points:
  - active trip completion — `driver_app/lib/features/trip/presentation/trip_screen.dart:238-240`
    (`onRate`, gated by `ratedRideStatusProvider` `:176-184`);
  - history/manual re-rate — `driver_app/lib/features/rides/presentation/rides_history_screen.dart:247-257`
    (`_RideTile`'s `Rate` button).
- So the duplication is the rider `RatingPromptDialog` vs the driver `RateSheet` (one widget
  reused at two driver entry points), **not** two rider widgets. This is a premise correction,
  not a rounding error: the unification target is the cross-app pair.

### The two forms differ where it matters

| Aspect | Rider `RatingPromptDialog` | Driver `RateSheet` |
| --- | --- | --- |
| Presentation | `AlertDialog` (`rating_prompt_dialog.dart:44`) | `showModalBottomSheet` (`rate_sheet.dart:10-14,90-95`) |
| Submit trigger | immediate on star tap (`:56`) | select then `Submit rating` (`:118-120,153-163`) |
| Comment | none | optional, max 280 (`:131-142`) |
| Busy/disable source | `RideDetailState.isRating` (`:41-42`) | local `_submitting` (`:32,46`) |
| Error surface | `state.error` (`:70-76`) | local `_error` (`:36,143-151`) |
| Unselected star color | grey (`:60`) | amber (`:124`) |
| Result contract | pops `RatingOutcome`; `failed` holds the dialog (`:27-37`) | pops `void`; failure keeps the sheet (`:68-80`) |

### The API and status logic that must not change

- Rider: `POST /rides/{id}/rate` with `{score, comment}` — endpoint
  `rider_app/lib/core/api/endpoints.dart:19`; `RideDetailNotifier.rateRide`
  `rider_app/lib/features/home/data/ride_provider.dart:187-232` (in-flight guard, already-rated
  guard, 409 → `alreadyRated`). `RatingStatus` / `riderRideRatingStatusProvider`
  `ride_provider.dart:26-40,339-380` is the prompt gate and stays rider-side.
- Driver: `POST /driver/rides/{id}/rate` with `{score, comment}` — endpoint
  `driver_app/lib/core/api/endpoints.dart:37` (`driverRideRate`); repository
  `driver_app/lib/features/rides/data/rides_repository.dart:154-170` (POST at `:164`);
  `RatingStatus` /
  `ratedRidesProvider` / `ratedRideStatusProvider` in
  `driver_app/lib/features/rides/data/rated_rides_provider.dart:27-41,199-242` stay
  driver-side.
- Both backends range-check 1..5 and use `UNIQUE(ride_id, rater_role)`; the 409 → success
  mapping is already handled rider-side (`ride_provider.dart:214-223`).

## Scope

### 1. Shared, presentation-only rating widget

New `shared/lib/src/rating/app_rating_sheet.dart` (plus `export` in
`shared/lib/ride_hailing_shared.dart`, one line per new file):

- `AppRatingSheet` (a `StatefulWidget`, no Riverpod, no Dio, no app providers):
  - params: `title`, `subtitle`, `allowComment` (default false), `maxCommentLength` (default
    280), `submitLabel` (default `Submit rating`), `skipLabel` (default `Not now`), `busy`,
    `errorText`, `initialScore` (default 0), `onSubmit(int score, String comment)`, `onSkip`.
  - one star row, `ValueKey<String>('rating-star-$value')` for values 1..5 (preserves the
    rider's existing test keys), plus a shared `Key('rate-star-$star')` alias or migrate the
    driver keys; `_score` is internal. Star colors are **unselected grey / selected amber**
    (locked 2026-10-08).
  - a `Submit` button enabled only for `1..5` and not `busy` (mirrors `rate_sheet.dart:46`);
    an optional comment field; an inline error line; a skip action.
  - a `showAppRatingSheet(BuildContext)` helper mirroring `showRateSheet`'s ergonomics
    (`rate_sheet.dart:8-15`), with keyboard padding
    `EdgeInsets.only(bottom: MediaQuery.viewInsets.bottom)` (`rate_sheet.dart:85-89`).
- **Locked 2026-10-08: both apps use one bottom sheet** (`showAppRatingSheet`); do not add a
  rider-only `AppRatingDialog`.
- Keep shared free of app wiring (the `[nav]` invariant): no route table, no `go_router`, no
  rating providers.

### 2. Rider adoption (behavior preserved)

In `rating_prompt_dialog.dart`, replace the bespoke `AlertDialog` body with the shared bottom
sheet (`showAppRatingSheet`), wired to the existing notifier:

- `onSubmit: (score, comment) async { final outcome = await ref.read(rideDetailProvider.notifier).rateRide(rideId, score, comment: comment); ... }`
  — keep the `failed` → hold-open and success/alreadyRated → pop `RatingOutcome` contract
  (`rating_prompt_dialog.dart:27-37`).
- `busy: ref.watch(rideDetailProvider).isRating`, `errorText: state.error`
  (`:41-42,70-76`).
- Keep `_promptRating`'s gate unchanged (`active_ride_screen.dart:352-369`).
- `allowComment: true` (locked 2026-10-08): the rider gains the optional comment for driver
  parity; the payload changes from `comment: ''` (`ride_provider.dart:188`) to a real string and
  the backend accepts both.

### 3. Driver adoption (behavior preserved)

Rewrite `driver_app/lib/features/rides/presentation/rate_sheet.dart` as a thin wrapper over the
shared widget, preserving:

- `showRateSheet(context, ref, {required rideId})` signature and both call sites
  (`trip_screen.dart:239`, `rides_history_screen.dart:249`);
- `onSubmit` → `ridesRepositoryProvider.rateRide(rideId, score, comment)` then
  `ratedRidesProvider.notifier.markRated(rideId)` and pop (`rate_sheet.dart:55-67`);
- `ArgumentError` → "Pick between 1 and 5 stars." and generic failure → "Could not send your
  rating. Please try again." (`:68-80`), now passed as `errorText`.

### 4. Reuse, not a parallel copy

- Add the shared file to the barrel; import it directly from
  `package:ride_hailing_shared/ride_hailing_shared.dart` — do **not** mint an app shim
  (AGENTS.md convention).
- No networking or state moves into `shared/`; the endpoint and `RatingStatus` logic stay per
  app.

## Invariants

- **API contract unchanged.** `POST /rides/{id}/rate` and `POST /driver/rides/{id}/rate` keep
  `{score, comment}`; 1..5 range; 409 means already-rated/success.
- **`RatingStatus` logic unchanged.** `riderRideRatingStatusProvider` /
  `RideDetailState.canRate` and the driver's `ratedRidesProvider` / `ratedRideStatusProvider`
  remain the only prompt gates; the shared widget never decides whether to rate.
- **One submit path per app.** The shared widget calls the app callback; the app's notifier
  keeps its double-submit and already-rated guards (`ride_provider.dart:187-232`).
- **Re-export-shim rule.** The widget is shared and imported from the barrel; no app files are
  moved into `shared/`; the two app-local `RateSheet`/`RatingPromptDialog` bodies are
  re-authored, not relocated.
- **Preserve test keys** (`rating-star-*`, `rate-comment`, `rate-submit`, `rate-skip`,
  `rate-error`) or migrate the tests deliberately.
- **Accessibility.** Star targets keep a tooltip/label (`'$star star(s)'`,
  `rate_sheet.dart:126`); buttons stay labeled.

## Out of scope

- The rate endpoints and any server change.
- The rating-status/seed providers or their bounds (`ride_provider.dart:262-380`,
  `rated_rides_provider.dart`).
- Tipping (`POST /rides/:id/tip` is STUB).
- Adding a **rider history rating entry** — the rider history tile has none today
  (`history_screen.dart:109-181`); if the human wants one, it is a new feature on top of this
  unification, not part of it.
- Redesigning the star visuals beyond parity (that belongs to the `[design]` plan).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

- New `shared/test/rating/app_rating_sheet_test.dart`: star selection, submit enabled/disabled
  on `busy`, comment capture, error text, skip, `1..5` guard.
- Rider `rider_app/test/features/home/presentation/active_ride_screen_test.dart`: the existing
  completion-rating cases (`:620-754`) must stay green — 5★ POST body, skip, already-rated
  suppression, and the "rating one ride does not suppress the next" case. Assert the POST body
  is still `{score, comment}`.
- Driver `driver_app/test/features/rides/presentation/rate_sheet_test.dart`, plus the trip and
  history rating cases (`trip_screen_test.dart`, `rides_history_screen_test.dart`), must stay
  green through the wrapper.
- `melos run analyze` clean on both apps + shared.

## Cross-domain notes

- **API: none.** Contract unchanged.
- **Shared:** new `shared/lib/src/rating/app_rating_sheet.dart` + one barrel export. Shared
  stays provider/network-free.
- **Driver (`driver_app_plans`):** the driver half needs `driver-planner` coordination. Options:
  (a) this plan owns the shared widget and the rider adoption; a `driver_app_plans`
  counterpart (owned by `driver-planner`) rewrites `RateSheet` on top of it; or (b) this plan
  lands both wrappers. Recommended: (a), with the shared widget landing first inside this plan
  so the driver counterpart is an independent follow-up. Flag the `rate_sheet_test.dart` key
  contract so the driver change does not break it.
- **`[design]` tokens/components (landed — `STATUS.md` → Landed `[design]`):** the shared rating
  widget should consume the now-landed tokens/components (buttons, colors, radii); use
  `AppSpacing`/`AppColors`/`AppRadii` from the start.
- **STATUS rows to update on landing:** add a `### [rating]` Landed entry (shared widget +
  rider and driver adoption, with `file:line`); remove this plan's row and delete this file.
  No new known-bug row (this is a refactor, not a behavior fix).

## Locked product decisions (2026-10-08 — product owner)

1. **Comment field on the rider** — allow the optional comment (driver parity); the endpoint already
   accepts it, so `allowComment: true`.
2. **Presentation** — one bottom sheet for both apps (no rider-only dialog variant).
3. **Star color** — unselected grey, selected amber.
4. **Rider history rating entry** — stays out of scope (none exists today).
