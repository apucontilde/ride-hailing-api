# Test Audit — executed report

Result of running [`TEST_AUDIT.md`](TEST_AUDIT.md) over every committed test
(excluding `e2e/`). The working tree changed mid-audit (a much larger codebase
appeared), so this was executed in two waves: wave 1 over the original snapshot,
wave 2 over the ~53 new Go and ~34 new Dart test files and the leftover `zz_`
scratch artifacts. No production code was modified.

## 1. Scope and method

| Wave | Areas | Agents |
| --- | --- | --- |
| 1 | Go `tests/` + `testutil`; Go `internal/` + `cmd/`; Dart `shared/`, `rider_app/`, `driver_app/` | 5 |
| 2 | Go `tests/`; Go `internal/repository`; Go `internal/{service,handler,config,database,middleware,router,routing,push}`; Dart `shared/`, `rider_app/`, `driver_app/` | 6 |

Every candidate was re-read against its production owner before edit; deletions
cited in a domain `STATUS.md` or plan were skipped and reported.

## 2. Deleted test files (10)

| File | Reason |
| --- | --- |
| `tests/zz_prefix_probe_test.go` | self-described temporary probe, assertion-free |
| `internal/repository/zz_prefix_probe_test.go` | temporary probe; covered by `pin_uncovered_test.go` |
| `internal/repository/zz_prefix_probe_integration_test.go` | temporary, assertion-free; covered by `pin_uncovered_integration_test.go` |
| `internal/service/zz_prefix_probe_test.go` | temporary probe; covered by `pin_uncovered_test.go:112` |
| `internal/repository/zz_sweep2_test.go` | assertion-free scratch sweep duplicating `TestElevationWeightsSweep` |
| `rider_app/test/widget_test.dart` | duplicate of `splash_screen_test.dart` |
| `rider_app/test/core/home/location_helper_test.dart` | placeholder `expect(true, isTrue)` |
| `rider_app/test/integration/auth_flow_test.dart` | mislabeled; fully faked; name over-promised 4 phases |
| `rider_app/test/core/router/app_router_test.dart` | existence-only `isA<GoRouter>`; covered by `rider_shell_test` |
| `driver_app/test/core/auth/auth_storage_test.dart` | byte-identical duplicate of the rider suite |
| `driver_app/test/widget_test.dart` | existence-only splash smoke |

## 3. Removed / condensed within files

- **Duplicates:** `TestLoginReturnsRefreshToken`, `TestRiderMeRequiresRiderRole`,
  `TestDriverAcceptRide`, `TestRideReceipt`, `TestWSDriverLocationPush`,
  `TestWSRiderReceivesStatusTransition`, `TestRateLimitHeadersPresent`,
  `TestWSRiderConnectsAuthenticated` (Go); driver/rider `device_token` "failure is
  non-fatal" duplicates; rider `location_ping` 204 duplicate; driver `api_client`
  safety-endpoints group (no production code under test); driver `nav_items`
  capability test; driver `widget_test`.
- **Consolidated:** Go `respond_test` classification table, `auth_test` middleware
  table, `routing_test` grid-vs-scan property, repository capability smokes,
  elevation table cases, benchmark builder; Dart shared nav-item parity, toggle,
  profile header/form, api-error; app-local shared-widget replays in rider/driver
  sidebar/settings/profile.
- **Fixed (not deleted):** `TestRouteZeroWeightsEqualsDistance` now uses the
  independent brute-force Dijkstra oracle; `TestAscent...`/estimate tests pin
  hardcoded oracles instead of recomputing with `routing.HaversineMeters`;
  `push_test` assertion-free case now asserts 0 deliveries; shared component/theme
  suites assert literal style/token values instead of tautologies; `AssertJSONHas`
  numeric caveat documented.
- **Race fix:** `MockRideRepo` no longer aliases the caller's `*model.Ride`, and
  `FailNext` is set through a mutex-guarded setter; `go test -race ./tests/`
  passes with 0 races.
- **New support (shared fakes):** `rider_app/test/support/fake_websocket_service.dart`,
  `driver_app/test/support/{sheet_harness,trip_fixtures}.dart`.

## 4. Retained false positives (with reason)

- **Mock-oracle `454`/`5000`** (`tests/routing_test.go`, `ride_lifecycle_test.go`):
  explicitly named as must-recheck evidence by `api_plans/[elevation]_duration_model.md`
  and `USER_STORIES.md`, so kept (comments added).
- **`zz_stage2_sweep_test.go`, `zz_asc12_bench_test.go`**: deliberately-retained
  plan evidence instruments (cited in `api_plans/STATUS.md`); the sweep has a real
  G7 assertion, the bench has no `Test` funcs.
- **`tests/testutil/mock_repos_test.go`**: documented lockstep invariant
  (`api_plans/STATUS.md`); guards a silently-invalid suite.
- **`shared/test/navigation/app_nav_item_test.dart`**: constant-restatement by
  design — the cross-app parity freeze oracle both apps depend on.

## 5. Follow-ups

1. **Stale plan counts:** `driver_app_plans/STATUS.md` still says "337 passed";
   driver is now 302. Update via the plan-management skill.
2. **Non-hermetic maps:** rider widget tests mounting `FlutterMap` hit real
   `tile.openstreetmap.org`; a shared tile seam / `HttpOverrides` would remove the
   network dependency.
3. **`fakeAsync` gaps:** `shared/test/network/websocket_service_test.dart` still
   uses fixed delays (needs a `Timer` seam in the service); driver
   `location_service_test` and `websocket_service_test` remain real-time.
4. **DDL fixture duplication** across repository integration tests — consolidate
   with a live DB available.
5. **`@visibleForTesting int get silentTicks`** now has a single asserting owner.
6. **Untested branch:** driver `deviceTokenServiceProvider` cold-start
   `fireImmediately` path (`driver_app_plans/STATUS.md` bug #12) is still untested.

## 6. Verification (final tree)

```
go build ./... ; go vet ./...                      clean
go test -count=1 ./...                             all packages ok
go test -race ./tests/                              ok (0 races)
golangci-lint run ./...                            0 issues
melos run analyze                                  driver/shared/rider SUCCESS
melos run test                                     driver 302, shared 165, rider 363 — all passed
```

Integration suites (`//go:build integration`) were compiled (`go vet -tags=integration`)
but not executed; `make test-integration` remains the DB-backed gate.
