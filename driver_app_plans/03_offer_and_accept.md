# Plan 03 — Offer dialog + accept / decline (US-D5, D6)

> **Status: ✅ LANDED** (re-audited 2026-09-25). **Offers never reached the driver
> until 2026-09-25 — see "The dropped-offer bug" below.** `features/rides/data/rides_repository.dart`
> (`fetchRide` via `GET /driver/rides/:id`, `acceptRideHttp` mapping 409 →
> `OfferExpiredException`), `features/rides/presentation/offer_sheet.dart` (5 s detail
> fetch with timeout, 30→0 countdown, Accept = WS-first with HTTP fallback,
> Decline = WS-only, disabled at 0, single-offer policy in `RideStateNotifier`),
> and the `home_screen.dart` wiring that opens the sheet. Tests:
> `rides_repository_test.dart` + `offer_sheet_test.dart`, green.
> **Note:** the sheet shows `total_fare` + pickup/dropoff but **not** the
> base/surge breakdown the plan asked for — the backend `Ride` JSON has the fields,
> so this is presentation-only, not a contract gap.
> ⚠️ This repository file was untracked until 2026-09-25: a bare `data/` rule in
> `.gitignore` matched `features/rides/data/`, so the layer was missing from a
> fresh clone. `.gitignore` is now root-anchored and the file is committed.

Turn the `ride.offer` event into a real decision surface: fetch ride detail, show
fare/pickup/dropoff, count down the 30 s window, accept (WS first, HTTP fallback)
or decline (WS only).

## Facts (re-audited)

- **Offer arrives as** `{"type":"ride.offer","data":{"ride_id":"..."}}` — only the
  id (`internal/service/dispatch.go:114-117`). The dialog must therefore fetch
  detail via `GET /driver/rides/:id` (`internal/handler/ride.go:130`).
- **Countdown:** server expires the offer after 30 s and auto-moves on
  (`dispatch.go:122`); show a matching countdown and disable both buttons at 0.
- **Accept (WS, primary):** send `{"type":"ride.accept","data":{"ride_id":"..."}}`
  (nested — plan 01) → `HandleAccept` fires the offer channel
  (`dispatch.go:127-136`); the server later broadcasts `ride.updated` with the
  accepted ride. If the WS is dead the accept silently does nothing, so the dialog
  ALSO has an **HTTP fallback**: `POST /driver/rides/:id/accept` returns
  **409** when there is no active offer / ride already taken
  (`internal/handler/ride.go:305`, conflict at `dispatch.go:153-155`) — that 409
  is *normal* ("offer lost"), show "Trip no longer available".
- **Decline (WS only):** `{"type":"ride.decline","data":{"ride_id":"..."}}` —
  fire-and-forget, no HTTP endpoint exists.
- **Ride JSON** (`Ride` model from plan 01/README): includes `pickup_lat/lng/address`,
  `dropoff_lat/lng/address`, `vehicle_type`, `base_fare, distance_fare, time_fare,
  surge_multiplier, total_fare`, timestamps. Fare is server-computed — display
  `total_fare` and let the user dig into the breakdown.

## Work

1. `lib/features/rides/data/rides_repository.dart` (new):
   - `Future<Ride> fetchRide(String id)` → `GET /driver/rides/:id`, returns
     `Ride.fromJson`.
   - `Future<void> acceptRideHttp(String id)` → `POST /driver/rides/:id/accept`;
     **409 → throw `OfferExpiredException`** (existing `api_exceptions.dart`).
2. `lib/features/rides/presentation/offer_sheet.dart` (new):
   - Driven by `rideStateProvider.offeredRideId` (plan 01).
   - On offer: fetch detail (set a 5 s loading state vs the 30 s deadline).
   - Layout: pickup → dropoff, `total_fare`, driver-facing ETA/notes (base + surge
     breakdown from `fare` fields), **30 → 0 countdown** via a timer that
     cancels on disposal (leaving the sheet = implicit decline? — no: leaving
     silently lets the server expiry handle it; keep buttons live until 0).
   - Buttons: **Accept** (primary → `rideState.acceptOffer()`; if WS is
     disconnected, fall back to `acceptRideHttp`; on success close sheet + show
     "Trip accepted" mini-toast, on `OfferExpired` → banner "Trip no longer
     available"), **Decline** (`rideState.declineOffer()`, close sheet).
   - At countdown 0: disable both buttons, show "Offer expired".
   - Guard against re-entrancy: a second `ride.offer` while a sheet is open queues
     behind the first (single-offer policy; poll once per sheet).
3. `lib/features/home/presentation/home_screen.dart`: when
   `offeredRideId != null` and status `online`, show `showModalBottomSheet(...)`.

## Tests

- `test/features/rides/data/rides_repository_test.dart` (mocktail repo):
  fetch parses full Ride; accept maps 409 → `OfferExpiredException`.
- `test/features/rides/presentation/offer_sheet_test.dart`: renders pickup/dropoff/
  fare; countdown reaches 0 and disables buttons; accept sends WS nested accept
  when connected; WS-offline accept falls back to HTTP; 409 shows "not available";
  decline sends WS decline + closes.
- `test/core/ride/ride_state_notifier_test.dart`: add cases — accept sets
  placeholder current ride; decline clears offer; second offer while one is open
  is ignored.

## Acceptance

- Every step the driver can decide within the server's 30 s; out-of-window cases
  degrade gracefully ("Trip no longer available") and never crash.
- Accept always lands at least one path (WS or HTTP); decline is WS-only and safe
  to repeat.

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: two accounts → rider books → driver sees offer with countdown → accept →
both apps show accepted ride; decline → rider sees "no driver available".

## The dropped-offer bug (fixed 2026-09-25)

"US-D5: the driver never receives a ride offer." The backend delivered the offer
correctly all along — the **client dropped it on arrival**. Two independent
defects, both in the wiring this plan added:

1. **Stale profile cache.** `AvailabilityNotifier.toggle()` wrote the new status
   to its own `AvailabilityState` but never back into the shared
   `driverProfileProvider`, which therefore kept the value the auth bootstrap
   cached at login. The driver went online (switch checked, "You're online",
   location pushing) while `driverProfileProvider.isOnline` stayed `false`.
   `toggle()` now writes the returned profile into the cache, mirroring
   `ProfileNotifier.updateProfile`.
2. **The gate itself.** `home_screen.dart` opened the sheet only when
   `driver?.isOnline == true` — i.e. only when the *cache* agreed. Dispatch
   already offers only to drivers the server considers online, located and
   websocket-connected, so re-deriving it from a cache that can be stale, `null`
   or not-yet-loaded could only ever discard a legitimate offer. The gate is now
   the offer alone. The `_offerShown` bool is now `_offerLatch`, keyed to the
   ride id, so an offer that is withdrawn (declined, or the 30 s timer firing on
   a sheet that never appeared) releases the latch instead of shielding the
   driver from the *next* offer forever.

Symptom of (1)+(2) together: the `ride.offer` event set `offeredRideId`, the
`build` guard evaluated false, 30 s later `_onOffer`'s timer cleared the offer,
and the server logged `all drivers declined`. From the driver's seat nothing at
all happened.

Regression coverage: `driver_app/test/features/home/presentation/home_screen_test.dart`
(sheet opens with a stale `offline` profile; a later offer still opens after the
first is withdrawn), `driver_app/test/features/home/providers/availability_notifier_test.dart`
(`toggle()` updates the profile cache both ways), and end-to-end in
`e2e/specs/ride-offer.spec.ts`, which drives both real UIs in a browser.

The live walkthrough above is now automated end-to-end:

```bash
cd e2e && npm install && npm run build:apps && npm test
```