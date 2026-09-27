---
tag: history
depends_on: []
status: open
---

# Real ride history

Replace the static "No rides yet" screen with a paginated history list fed by the real endpoint.

**Read first:** `rider_app/lib/features/home/presentation/history_screen.dart`,
`rider_app/lib/core/api/endpoints.dart`, `rider_app/lib/features/home/data/home_provider.dart`
(pattern for providers + error handling).

## Endpoint (real, paginated)

```http
GET /api/v1/rides/history?page=1&per_page=20
# → 200 { "rides": [ <Ride>... ], "total": <int>, "page": <int>, "per_page": <int>, "total_pages": <int> }
```
`Ride` fields to render: `pickup_address → dropoff_address`, `vehicle_type`, `status`,
`total_fare`, timestamps `requested_at`/`completed_at`. Defaults: `page=1`, `per_page=20` (max
`50`). `ridesHistory` already exists in `endpoints.dart:25` but is never called.

## Changes

1. New `features/home/data/history_provider.dart`:
   - `StateNotifier<AsyncValue<List<RideEntry>>>` (or Riverpod `FutureProvider.family` per page)
     with fields `page`, `totalPages`, `hasMore`, `isLoadingMore`, `error`.
   - `firstPage()` → `page=1`; `loadMore()` → `page+1` while `page < total_pages`.
   - Errors mapped via `mapStatusCodeToException`; empty list → empty-state (distinct from error state).
2. `history_screen.dart`: replace the placeholder body (`history_screen.dart:13`) with a
   `RefreshIndicator` + `ListView` (renders the fields above) + infinite-scroll trigger (scroll
   near bottom → `loadMore()`), pull-to-refresh resets to page 1. Keep explicit error + empty states.
3. Wire the History tab/nav entry to this provider (it should already route to `/history`).

Note: models — reuse a `RideSummary.fromJson` model in `features/home/model/` (add if none
exists); do not depend on the tracking plan's state types for the list.

## Tests — `test/features/home/data/history_provider_test.dart` + `history_screen_test.dart`

- Provider: page 1 render, `loadMore` appends, `hasMore` false at `total_pages`, error state,
  empty list.
- Screen: mock adapter returns two pages → scroll loads page 2; empty body shows empty-state text;
  error shows retry.

## Verify

```bash
make flutter-analyze
make flutter-test
```

## Acceptance

- `HistoryScreen` no longer hardcodes "No rides yet" for a populated account.
- Pagination respects backend `total_pages`; no out-of-range page requests.
