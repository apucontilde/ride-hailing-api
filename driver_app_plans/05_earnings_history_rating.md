# Plan 05 — Ride history + client-side earnings + rating (US-D10, D11)

> **Status: 🔴 NOT STARTED** (re-audited 2026-09-25). Nothing in this plan landed.
> Concretely, none of these exist:
> - `RidesRepository.history()` / `rateRide()` — absent; the repository has only
>   `fetchRide`, `acceptRideHttp` and `currentRide` (plans 03/04).
> - `features/rides/providers/history_provider.dart` — file does not exist (no
>   `historyProvider`, no `earningsProvider`, no month bucketing, no pagination).
> - `features/rides/presentation/rate_sheet.dart` — file does not exist; no
>   `ratedRideIds` tracking anywhere.
> - `features/rides/presentation/rides_history_screen.dart` is still the
>   **placeholder**: a `Scaffold` with the text "Your ride history and earnings
>   arrive with the earnings & history plan (driver_app_plans/05)". It calls
>   nothing. `GET /driver/rides/history` and `POST /driver/rides/:id/rate` are
>   declared in `endpoints.dart` and never invoked.
> - No tests for any of it.
> This is the largest single gap in the driver app: US-D10 (rate the rider) and
> US-D11 (history/earnings) are entirely absent from the running app, and it also
> blocks the post-trip rating prompt on the trip screen — plan 04 landed the trip
> journey but deliberately left rating out, since it is this plan's surface.

Give drivers their completed-rides history with **derived earnings**
(the `GET /driver/me/earnings` endpoint is a backend STUB — compute from history,
never build UI on the stub), and let them rate the rider after each completed trip.

## Facts (re-audited)

- **History:** `GET /driver/rides/history?limit=&offset=` (`internal/handler/ride.go:151`);
  returns `{"rides":[...],"total":N}` where each ride is the full Ride JSON
  (plan 00/README model). `limit/offset` pagination confirmed.
- **Earnings:** `GET /driver/me/earnings` and
  `POST /driver/earnings/withdraw` are **STUBBED** (`internal/handler/platform.go`).
  Rider rule applies: never build UI on a stub. So earnings = client-side sum over
  history: `total_fare` accumulates; show "This period/months" buckets grouped by
  `completed_at`; withdraw stays hidden. If the backend ever ships real earnings,
  swap the provider source — keep the same display contract.
- **Rating:** `POST /driver/rides/:id/rate` body `{"rating":1..5,"comment":"..."}`
  (`internal/handler/ride.go:258`). Only after `completed`; returns the created
  rating. The driver's own `rating_summary` (avg/count) is already on the profile
  from `GET /driver/me` — display it on the home/profile screens.

## Work

1. `lib/features/rides/data/rides_repository.dart` (extend plan 03's):
   - `Future<List<Ride>> history({int limit=20, int offset=0})` →
     `GET /driver/rides/history`.
   - `Future<void> rateRide({required String rideId, required int rating,
     String? comment})` → `POST /driver/rides/:id/rate`.
2. `lib/features/rides/providers/history_provider.dart` (new):
   - `FutureProvider.family<HistoryPage, int page>` + a `HistoryNotifier` that
     appends pages (infinite scroll via `limit/offset`), dedupes rides by id,
     stops when `total` reached, and supports pull-to-refresh.
   - `earningsProvider`: derived `FutureProvider` summing `total_fare` over the
     loaded history filtered by `completed_at` (group by month bucket) — lives in
     the same file, reads `historyProvider`.
3. `lib/features/rides/presentation/rides_history_screen.dart` (new):
   - List tiles: pickup → dropoff, `total_fare`, date from `completed_at`,
     status chip (only show completed/relevant ones; cancelled rides greyed with
     `cancelled_by`).
   - Loading + empty state ("No trips yet"); pull-to-refresh; infinite scroll.
   - Header card with **derived earnings this month** (read `earningsProvider`)
     + disclaimer "Based on completed trips".
   - Entry point: home app bar icon and/or profile.
4. `lib/features/rides/presentation/rate_sheet.dart` (new):
   - After `currentRide.status == completed` and not yet rated (track in a
     `Set<String> ratedRideIds` on the ride state notifier or a `ratedProvider`),
     prompt at end of trip navigation (plan 04 post-screen): 1–5 stars tap-to-set
     + optional `comment` + **Submit**.
   - Double-submit guard (disable while in flight); failure keeps the sheet open
     with an inline error, no silent loss.
   - After submit success: "Thanks! Rate earned" + close.

## Tests

- `test/features/rides/data/rides_repository_test.dart`: history parses + passes
  limit/offset; rate body `rating/comment` correct.
- `test/features/rides/providers/history_provider_test.dart`: pagination appends,
  dedupe by id, `total` stop condition; `earningsProvider` sums `total_fare` by
  month bucket (fixture with 2 rides in one month, 1 in another → 2 buckets).
- `test/features/rides/presentation/rate_sheet_test.dart`: tapping 5 stars +
  submit calls rate once; double-tap prevented; failure shows inline error and
  keeps sheet.

## Acceptance

- History loads with pagination and refresh; earnings numbers always equal the
  sum of listed completed rides.
- No UI reaches the STUB earnings/withdraw endpoints.
- Every completed trip can be rated exactly once (double-submit impossible).

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: complete 2–3 trips → history lists them; earnings header matches the sum;
rate one → rider profile shows the new rating.