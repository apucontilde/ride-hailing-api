---
tag: errors
depends_on: []
status: open
---

# Route-outage contract regression test (5xx, never 4xx)

Pins the API half of the "confident road-less route" hazard: a failure to compute a route must
answer **5xx**, never 4xx, because both Flutter apps react to an error by drawing a fallback
line. This is the **chain head** for the cross-app route-fallback fix: the rider plan
`rider_app_plans/01_[map]_route_fallback_honesty.md` and the driver plan
`driver_app_plans/01_[trip]_route_error_surfacing.md` both `depends_on` it. This plan only freezes
the contract in a test.

**Read first:**

- `internal/handler/platform.go:397-408` (`NavigationRoute`), `:355-362` (`GeoETA`) — both already
  `fail(c, http.StatusInternalServerError, "INTERNAL", "failed to calculate route", …)`.
- `tests/navigation_test.go:12-82` — covers success and 422 only; **no** calculation-failure case.
- `tests/error_contract_test.go` — the precedent shape: `TestLoginDBOutageIs500Not401`.
- `tests/testutil/helpers.go:83-121` — `NewTestServerE` hard-wires `NewMockNavigationRepo()`.
- `tests/testutil/mock_navigation_repo.go:7-24` — `pathFunc` is unexported; there is no failing variant.
- `RIDER_API_GUIDE.md:267-270` — currently claims the fallback is "for the 500 case regardless".

## Gap (verified)

No test asserts that a route **calculation failure** is 5xx-not-4xx. `NewTestServerE` constructs
its own always-succeeding `NewMockNavigationRepo`, so a failing route cannot be injected. A
future change to `respondRepo`/`fail` could silently turn a route outage into a 4xx with the
whole suite still green.

## Work

1. `tests/testutil/mock_navigation_repo.go`: add `NewFailingNavigationRepo(err error)` that sets
   `pathFunc` to return `nil, err` (mirrors `NewStrictMockGeoRepo`).
2. `tests/testutil/helpers.go`: add `NewTestServerWithNavE(navRepo)` and
   `NewTestServerWithNav(t)`, mirroring the existing `NewStrictTestServerE`/`NewStrictTestServer`
   pair.
3. New test (in `tests/error_contract_test.go` beside the outage tests): build the server with
   `NewFailingNavigationRepo(...)`, register/login, call `GET /api/v1/navigation/route` and assert
   `500` + the house envelope `{"error":{"code":"INTERNAL","message":"failed to calculate route"}}`,
   and explicitly that the status is **not** 4xx. Optionally assert `GET /api/v1/geo/eta` too.
4. `RIDER_API_GUIDE.md:267-270`: replace the false "The Dart apps keep their own straight-line
   fallback for the 500 case regardless" with the real, post-fix behavior — both apps draw a
   **dashed grey** line for `500` **and** `is_estimate: true`, and now also render the backend
   `error.message`.
5. Drive-by stale refs — **already fixed 2026-09-29**: `internal/handler/respond.go:138`, the
   `api_plans/STATUS.md` bug #3 row and the `rider_app_plans/STATUS.md` bug #2/invariant now cite
   `home_screen.dart:157`. Nothing left to do here.

## Tests

- New Go test asserts `500` + envelope + not-4xx for a failing nav repo.

## Accept

- A navigation-repo failure answers `500 INTERNAL`, never 4xx, enforced by a test.

## Verify

```bash
make test
make lint
gofmt -w <files> && go vet ./...
```
