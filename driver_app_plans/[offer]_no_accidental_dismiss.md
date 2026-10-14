---
tag: offer
depends_on: ["landed [offer] offer sheet + accept/decline (driver_app_plans/STATUS.md)"]
status: open
---

# [offer] Offer sheet dismisses only via an explicit Pass / Accept

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification). Android/iOS back-gesture behavior is **UNVERIFIABLE in this WSL tree**;
> close on a device (steps under Verification).

## Goal

A live ride offer must be dismissible only by the explicit **Pass** (reject) or **Accept** action —
never by tapping the scrim, swiping the sheet down, or an accidental system back gesture. Expiry is
the one non-action exit, and it must be an explicit tap too, so the driver never loses a live offer
by accident and is never trapped without an exit.

## Current state (verified)

- The offer is presented by `showModalBottomSheet` with the Flutter defaults (`isDismissible: true`,
  `enableDrag: true`) — `driver_app/lib/features/home/presentation/home_screen.dart:99-103`. A barrier
  tap or a drag-down already discards the sheet while the offer is live.
- `OfferSheet` returns a bare `AppBottomSheet` (a `Container`,
  `shared/lib/src/components/app_bottom_sheet.dart:10-51`) with **no** `PopScope`, so the system back
  gesture pops the modal route directly.
- Accept is `_accept()` (`driver_app/lib/features/rides/presentation/offer_sheet.dart:90-116`); reject
  is `_decline()` (`:118-123`); the 30 s countdown / `_expired` logic is `_startCountdown()`
  (`:73-88`). The footer `'Leaving the sheet lets the server expiry handle it.'` (`:226-229`)
  documents the current, unwanted behavior.
- Server semantics: the WS `decline` only signals the dispatch offer channel `false`
  (`internal/service/dispatch.go:257-264` → `recordSkip(..., skipDriverDeclined)`), i.e. the ride is
  **passed to the next driver**, not cancelled. The 30 s window is `offerTimeout`
  (`internal/service/dispatch.go:239`) and is mirrored by `RideStateNotifier.offerTimeout`
  (`driver_app/lib/core/ride/ride_state_notifier.dart:43,121-126`).

## Dismissal contract (decided)

1. **Live (`!_expired`)** — `isDismissible: false`, `enableDrag: false`, plus a
   `PopScope(canPop: false)` wrapping the sheet. The only exits are **Accept** and **Pass**.
2. **Reject is "Pass"** — relabel the secondary button `Decline` → `Pass` to match the server
   semantics (skip, not cancel); `_decline()` behavior is otherwise unchanged.
3. **Expired** — keep the sheet open (so the "Offer expired" feedback is visible) and replace the two
   action buttons with a single explicit **Dismiss** button; barrier/drag/back stay blocked. There is
   no live offer to lose, and there is still an explicit exit.
4. **Offer ceases to exist** — if the held offer id changes to a different id, or clears (accepted
   elsewhere / withdrawn), the sheet closes itself. That is the offer ending, not an accidental
   dismissal, and it prevents a stale sheet from stacking under a later offer.
5. Do **not** add a drag handle to this sheet (`AppSheetHandle` is deliberately absent today).

## Scope (app-only)

- `driver_app/lib/features/home/presentation/home_screen.dart:99-103` — pass `isDismissible: false`,
  `enableDrag: false` to `showModalBottomSheet`.
- `driver_app/lib/features/rides/presentation/offer_sheet.dart` — wrap the returned `AppBottomSheet`
  in `PopScope(canPop: false, ...)`; relabel the reject button; add the expired-state `Dismiss`
  button that pops; delete the "Leaving the sheet…" caption; observe the held offer id so the sheet
  closes when the presented offer is no longer the held one.
- No `shared/` change: `AppBottomSheet`/`AppButton` already support this. Do not touch them.

## Tests to add/change

- `driver_app/test/features/home/presentation/home_screen_test.dart` (production call site): with an
  offer on screen, tap the barrier and call `tester.binding.handlePopRoute()`; assert `OfferSheet`
  stays mounted; tap the explicit Pass and assert it closes.
- `driver_app/test/features/rides/presentation/offer_sheet_test.dart`:
  - `'Decline'` finders → `'Pass'` (countdown test `:116-144`, decline test `:205-220`).
  - back is blocked while live (`PopScope`), sheet still mounted.
  - expiry shows a single `Dismiss` and only `Dismiss` closes it.
- `driver_app/test/support/sheet_harness.dart`: add optional `isDismissible`/`enableDrag` so the offer
  suite can mirror the production options (the rate sheet keeps the defaults).

## Cross-domain

- None. The WS decline/pass and the 30 s window already exist. The skip-list's mis-wired HTTP
  `POST /driver/rides/:id/decline` (`driver_app_plans/STATUS.md` → Skip list) is untouched — the app
  keeps using the WS path.

## Open inputs

- Whether the expired sheet should auto-close instead of showing `Dismiss` — recommended: explicit
  `Dismiss` (keeps the timer feedback and the explicit-only rule). Resolve with product if desired.
- Pass-button copy ("Pass" vs "Pass on this ride") — cosmetic; pick one and test it.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

On an Android/iOS host: trigger a live offer, then (a) tap the scrim, (b) swipe down, (c) press the
system back button — all must leave the offer up; tap Pass to close. **UNVERIFIABLE in this WSL tree.**
