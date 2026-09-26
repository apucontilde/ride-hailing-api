# Plan 05 — Ride history + client-side earnings + rating (US-D10, D11)

> **Status: ✅ LANDED** (2026-09-25). The placeholder history screen is gone and
> US-D10/US-D11 are both real. Two endpoints the doc below had wrong are
> corrected in *Facts*.
>
> Landed:
> - `RidesRepository.history({page, perPage})` → `RideHistoryPage` and
>   `rateRide({rideId, score, comment})`.
> - `features/rides/providers/history_provider.dart` — `HistoryNotifier`
>   (paged, deduped by id, concurrency-collapsed, pull-to-refresh) plus
>   `earningsProvider`, a derived sum bucketed by completion month.
> - `features/rides/presentation/rides_history_screen.dart` — the real list,
>   earnings header, infinite scroll, per-trip rating action.
> - `features/rides/presentation/rate_sheet.dart` — 1–5 stars + optional
>   comment, plus `ratedRideIdsProvider` (the "already rated" guard).
> - Trip screen: the post-trip receipt now offers to rate the rider.
> - Home drawer entry point. **50 new tests** (121 → 171).
>
> Two bugs the new tests caught: the page merge **prepended** the fetched page
> instead of appending it, inverting the newest-first order (page 1 is
> newest, so an append belongs at the tail); and the tile's trailing column
> overflowed its `ListTile` slot by 8 px because a default Material button is
> 48 px tall.
>
> Deliberately **not** done: no withdraw UI (`POST /driver/earnings/withdraw`
> is a stub, and the rider rule is never to build on a stub); no live trip
> list beyond the history pages; the "already rated" set is session-local
> because the server exposes no way to read ratings back (see *Rating*).

Give drivers their completed-rides history with **derived earnings**
(the `GET /driver/me/earnings` endpoint is a backend STUB — compute from history,
never build UI on the stub), and let them rate the rider after each completed trip.

## Facts (re-audited, two corrections)

- **History:** `GET /driver/rides/history?page=&per_page=` (`internal/handler/ride.go:151`);
  returns `{"rides":[...],"total":N,"page":N,"per_page":N,"total_pages":N}` where each
  ride is the full Ride JSON. ⚠️ **Pagination is 1-based `page` + `per_page`, not
  `limit`/`offset`** — the original version of this doc had that wrong. The handler
  clamps `page >= 1` and `per_page` to 1..50 and **silently rewrites** an
  out-of-range value, so a bad one comes back as a valid-looking page instead of an
  error. Rows come from `FindRidesByDriver` (`SELECT *`, `ORDER BY created_at DESC`),
  so the fare columns are present and each later page is strictly older.
- **Earnings:** `GET /driver/me/earnings` and
  `POST /driver/earnings/withdraw` are **STUBBED** (`internal/handler/platform.go`).
  Rider rule applies: never build UI on a stub. So earnings = client-side sum over
  history: `total_fare` accumulates; show "This period/months" buckets grouped by
  `completed_at`; withdraw stays hidden. If the backend ever ships real earnings,
  swap the provider source — keep the same display contract. ⚠️ Because history is
  paginated, a derived total only ever covers the pages **loaded so far**; the card
  says so rather than implying an all-time balance.
- **Rating:** `POST /driver/rides/:id/rate` (`internal/handler/ride.go:258`).
  ⚠️ **The body field is `score`, not `rating`** — the original version of this doc
  had that wrong too. `rateRideRequest.Score` is `json:"score" binding:"required"`,
  so a `rating` key binds to zero and the server answers 400. The service
  (`internal/service/ride.go:192-206`) only range-checks the score: it never
  verifies the ride is `completed`, nor that the caller is the assigned driver, so
  the caller owns both rules. The driver's own `rating_summary` (avg/count) is
  already on the profile from `GET /driver/me` — displayed there, not duplicated here.
- **"Already rated" is unreadable.** `GET /driver/ratings` is a `StubPayment`
  (`internal/router/router.go:144`) and the ride history carries no rated-by-driver
  flag, so the app has no server-side way to know a ride was rated. The prompt is
  therefore guarded by an in-session `Set<String>`, and a relaunch forgets it.

## Work (as landed)

1. `lib/features/rides/data/rides_repository.dart` (extended):
   - `Future<RideHistoryPage> history({int page = 1, int perPage = 20})` →
     `GET /driver/rides/history`, parsing the rides plus the echoed pagination
     metadata. A response with neither rides nor metadata yields an empty page
     rather than throwing.
   - `Future<void> rateRide({required String rideId, required int score,
     String? comment})` → `POST /driver/rides/:id/rate`. The score is range-checked
     locally (an out-of-range value would only come back as a 400), and a blank
     comment is dropped instead of sent as `""`.
2. `lib/features/rides/providers/history_provider.dart` (new):
   - `HistoryNotifier` appends pages via `page`/`per_page`, dedupes by ride id
     (a ride can land on two pages when one is created mid-scroll — the
     already-loaded copy is the newer one and keeps its value *and* position),
     collapses concurrent `loadMore` calls, and supports `refresh({silent})` so
     pull-to-refresh reloads *behind* the list instead of blanking it.
   - **Exhaustion follows the page length, not `total`.** A row that loses its id
     is dropped from the list but still counts towards the server's `total`, so a
     `total`-only test would page forever.
   - `earningsProvider` sums `total_fare` over `completed` rides only (a cancelled
     trip paid nothing; one in progress has no final fare), bucketed by
     `completed_at` with `requested_at` as the fallback. `now` is injectable so
     the month boundary is testable. A null fare counts as zero rather than
     dropping the trip; a ride with no parseable date still counts towards the
     loaded total but files under no month.
3. `lib/features/rides/presentation/rides_history_screen.dart` (replaced the
   placeholder):
   - Tiles: pickup → dropoff, `total_fare`, a hand-rolled date, and a status chip
     (cancelled greyed out, no fare, "Cancelled by rider/driver").
   - Loading + "No trips yet" empty state, pull-to-refresh, infinite scroll within
     300 px of the bottom, and an end-of-list marker.
   - Header card: **fares this month** + trip count, a per-month breakdown, and the
     honest caveat that the figure covers only the loaded completed trips.
   - Entry point: the home drawer (the profile screen already linked here).
4. `lib/features/rides/presentation/rate_sheet.dart` (new):
   - 1–5 stars tap-to-set, optional 280-char comment, **Submit**. Submit stays
     disabled until a star is picked and while a request is in flight, so a
     double-tap is impossible.
   - A failure keeps the sheet open with an inline error — a silently dropped
     rating is data loss, because the server gives the driver no way to see that
     it did not land.
   - `ratedRideIdsProvider` records the ride on success, retiring the prompt in
     both the trip screen and the history list.
5. Trip screen: the post-trip receipt — where the fare is still on screen — offers
   "Rate the rider" via the sheet. It **watches** the rated set (reading it would
   not rebuild the screen, so the prompt would linger after a submit).

## Tests (as landed)

- `test/features/rides/data/rides_repository_test.dart` (12): history parsing and
  metadata, the `page`/`per_page` query (and that it is *not* `limit`/`offset`),
  the default page, an empty body, the rate body carrying `score` and the trimmed
  comment, an omitted comment, and a locally-refused out-of-range score that never
  touches the network.
- `test/features/rides/providers/history_provider_test.dart` (20): append at the
  tail with the newest-first order preserved, the boundary dedupe, exhaustion on a
  short page (and `loadMore` then being a no-op), an id-less row not paging
  forever, concurrent `loadMore` collapsing to one request, refresh replacing
  rather than appending, silent refresh keeping the list, and failures on both the
  first load and a pull-to-refresh. Plus `EarningsSummary`: month bucketing
  (2 rides in one month + 1 in another → 2 buckets, newest first), cancelled and
  in-progress exclusion, a null fare, the `requested_at` fallback, an undated ride,
  and the provider summing the loaded history.
- `test/features/rides/presentation/rate_sheet_test.dart` (10): submit disabled
  until a star is picked, the filled-star boundary, one submit with score +
  comment, the in-flight double-tap, an inline error on failure, a rejected score,
  "Not now" closing without rating, and `ratedRideIdsProvider` being set on success,
  left unset on failure, and idempotent.
- `test/features/rides/presentation/rides_history_screen_test.dart` (7): the empty
  state, the earnings card equalling the sum of the loaded completed trips, the
  month breakdown, rating offered only on completed rides and only once, the rate
  button opening the sheet and retiring itself, infinite scroll, and a load error
  that keeps the list and retries.
- `test/features/trip/presentation/trip_screen_test.dart` (+5): the post screen
  offering the prompt, opening the sheet, the prompt retiring once rated, and no
  prompt mid-trip or after a cancellation.


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