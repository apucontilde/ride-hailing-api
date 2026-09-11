# 08 — Fix ride creation end-to-end (Chrome/web + no-driver flows)

**Status:** ☐ pending — bug report: `rider_app/` cannot create a ride against the API when run on **Chrome/web**; and created rides hang forever on "Finding your driver...". Backend is healthy (verified live at `8a3a13f`: login → `GET /estimates/price` → `POST /rides` → `201 {"ride":{...}}`). All root causes below are app-side or web-transport-side.

**Read first:** `rider_app/lib/core/network/websocket_service.dart`, `rider_app/lib/core/api/api_client.dart`, `rider_app/lib/features/home/data/home_provider.dart`, `rider_app/lib/features/home/presentation/driver_matching_screen.dart`, `rider_app/lib/features/home/data/ride_status_provider.dart`, `internal/middleware/auth.go`, `internal/router/router.go`, `internal/service/dispatch.go`.

---

## Root causes (evidence-backed)

1. **WS transport is VM-only → no events on web.** `websocket_service.dart:3` imports `package:web_socket_channel/io.dart` (`IOWebSocketChannel`, a `dart:io` wrapper) and passes an `Authorization` header (`websocket_service.dart:35`). On Chrome/web `dart:io WebSocket` is unsupported → `connect()` throws → 5 s reconnect loop. `ride.updated` / `driver.location` never arrive, so the matching screen can confirm-ride and then spin forever even when a driver accepts. **Browsers also cannot set WS request headers**, so the token cannot travel via `Authorization` on web.
2. **Server `/ws` only accepts a Bearer header.** `internal/middleware/auth.go:16` (`AuthRequired`) never falls back to a query token, so a web WS connection gets `401`/upgrade failure. REST routes keep header-only auth; only `/ws` needs a query-token fallback.
3. **CORS blocks `POST /rides` on web.** The app sends the custom `Idempotency-Key` header (`home_provider.dart:127`). `internal/router/router.go:46` `AllowHeaders` is `Origin,Content-Type,Accept,Authorization` and does **not** include `Idempotency-Key`. Reproduced: `OPTIONS /api/v1/rides` with `Access-Control-Request-Headers: content-type,authorization,idempotency-key` returns `Access-Control-Allow-Headers: Origin,Content-Type,Accept,Authorization` → browser rejects the preflight → the ride POST never reaches the server.
4. **`no_driver_available` is invisible to the rider.** Backend flips the ride to `no_driver_available` without pushing any event (`internal/service/dispatch.go:59,78`); the app's `_statusFromBackend` (`ride_status_provider.dart:119`) drops unknown statuses and the app never polls `GET /rides/current`. In the current env no driver is online, so *every* created ride goes `no_driver_available` and the rider stares at "Finding your driver..." forever.
5. **API errors are swallowed with a stuck spinner.** `api_client.dart:37` `_createErrorInterceptor` does `throw mapStatusCodeToException(...)` (a non-Dio `ApiException`); `home_provider.dart:135` `createRide` catches **only** `on DioException` → on any API error the exception escapes `_createRide` (`home_screen.dart:459` has no try/catch), `isLoading` is never reset, and no message is shown.
6. **No 401 auto-refresh (AC-3).** Access JWT is 15 min (`JWT_ACCESS_TTL`). After expiry the estimates/ride calls 401 → user sees the raw snackbar `Error fetching estimates: UnauthorizedException(401): invalid or expired token`.
7. **Idempotency + cancel gaps (LC-0/LC-1).** `createRide` mints a new key per call, so a repeated attempt creates a duplicate ride. The matching screen ✕ only pops the route (`driver_matching_screen.dart:28`) — the pending ride stays on the backend and each retry stacks more phantom pending rides.

---

## Changes

### Backend (Go — small, no feature build-out)

1. **CORS fix (root cause 3, critical):** `internal/router/router.go:46` — add `"Idempotency-Key"` to `AllowHeaders`. Verify: `curl -i -X OPTIONS http://localhost:8080/api/v1/rides -H 'Origin: http://localhost:5555' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type,authorization,idempotency-key'` → response lists `Idempotency-Key`.
2. **WS query-token auth (root cause 2):** in `internal/middleware/auth.go` add an `AuthRequiredWS(svc)` variant (or a parameterized `AuthRequired` with a `queryToken` flag): header token first, else `c.Query("access_token")`, else `c.Query("token")`; identical JWT validation. Mount it in `internal/router/router.go:216`: `r.GET("/ws", middleware.AuthRequiredWS(authService), wsHub.HandleWS)`. REST paths keep `AuthRequired` untouched. **Security note:** the query token appears in access logs — scrub `access_token` in `internal/middleware/debug_logger.go` (dev-only tradeoff; native apps could keep the header, web must use the query).
3. **Push `no_driver_available` (root cause 4):** in `internal/service/dispatch.go` both places that set the status (`:59` and `:78`) send the rider a `websocket.OutgoingMessage{Type: "ride.updated", Data: RideUpdateData{RideID, Status: "no_driver_available", Timestamp}}` via `s.hub.SendToUser(ride.RiderID, ...)` — mirrors `CancelRide` in `internal/service/ride.go:116`. (The app still polls as a backup per below.)
4. **Tests:** `internal/middleware/auth_test.go` (header wins; query token accepted; bad token rejected); CORS header list assert in a router test (or confirm via the curl preflight).

### App (`rider_app/`)

5. **Cross-platform WS transport (root cause 1):** `lib/core/network/websocket_service.dart`
   - Swap `import 'package:web_socket_channel/io.dart';` for `import 'package:web_socket_channel/web_socket_channel.dart';` (top-level `WebSocketChannel.connect(Uri, {protocols})` routes over `package:web_socket`, which is supported on both VM and web).
   - Build the URL with the token in the query: `$cleanBaseUrl${ApiEndpoints.ws}?access_token=$token` (browsers can't send an `Authorization` header). Keep `_handleDisconnect`, reconnect, and the auth-error branch.
   - The channel now delivers `Object?` events (text/binary); keep decoding text as `String` and ignoring non-text frames.
   - **Tests:** `test/core/network/websocket_service_test.dart` — assert the target URL contains `?access_token=`, the scheme is `ws/wss`, and a decoded `ride.updated` frame reaches `events`.
6. **Surface `no_driver_available` (root cause 4):** `lib/features/home/data/ride_status_provider.dart`
   - Add `RideStatus.noDriverAvailable`; map backend `no_driver_available` in `_statusFromBackend`.
   - (Event-shape parsing for `ride.updated` / `driver.location` is already done — plan 01.)
7. **Current-ride poll (root cause 4):** new `lib/features/home/data/current_ride_provider.dart`
   - `GET /rides/current` (`ApiEndpoints.currentRide`, already declared) every 5 s while the matching screen is visible (WS-silence fallback for `no_driver_available`, and restore after reconnect).
   - On `no_driver_available` or `cancelled` → set state `noDriverAvailable`/`cancelled`; on `accepted`+ → advance like the WS event. Cancel the timer on dispose/pause.
   - **Tests:** provider test with injected timer/clock and a mocked `GET /rides/current` (`200 {"ride":{"status":"no_driver_available"}}` → state; `200 {"ride":null}` → unchanged; `accepted` → driverApproaching).
8. **Matching screen wiring (root cause 4 + 7):** `lib/features/home/presentation/driver_matching_screen.dart`
   - Start the current-ride poll in `initState`/when mounted, stop in dispose.
   - On `noDriverAvailable` → toast ("No drivers available — try again") and `context.go('/home')`; on `cancelled` → same.
   - ✕ button → real cancel via provider (below): `POST /rides/:id/cancel` with the ride id from ride state; toast + `context.go('/home')`.
   - **Tests:** widget tests — injected `noDriverAvailable` state shows toast and navigates home; tap ✕ hits the cancel endpoint.
9. **Ride creation provider hardening (root cause 5 + 7):** `lib/features/home/data/home_provider.dart`
   - `createRide`: catch `on DioException` **and** `on ApiException`; always `state = state.copyWith(isLoading: false, ...)` in a `finally` so the button never sticks.
   - Keep one idempotency key per booking *attempt* (generate in state, reuse across retries, clear on success) — LC-0. If the replay/empty-body path returns no `ride.id`, resolve the ride via `GET /rides/current`.
   - Add `cancelRide(String rideId)` → `POST ApiEndpoints.cancelRide(rideId)`.
   - **Tests:** success state, DioException error → friendly message + `isLoading` false, ApiException error, cancel success/error, key reused on retry and cleared on success.
10. **Active ride screen (root cause 7):** `lib/features/home/presentation/active_ride_screen.dart` — replace the 1 s mock `_cancelRide` body with `cancelRide(rideId)` from the provider; keep the typed driver/location reads already wired.
11. **Error + 401 handling (root cause 5 + 6):** `lib/core/api/api_client.dart`
    - `_createErrorInterceptor`: stop `throw`ing. Attach the mapped `ApiException` to `error.error` and `handler.next(error)` so `DioException` is the sole rejection type; friendly message resolution reads `e.response`/`(e.error as ApiException?)?.message`.
    - Add a single-flight 401 interceptor (AC-3): on `401` for an authed request (never for `/auth/refresh`/`/auth/login`) → `authProvider.refreshToken()` → retry the original request once with the new bearer; on failure force logout. Guard concurrent 401s (one refresh at a time).
    - **Tests:** provider tests assert `DioException` surfaces with readable message; interceptor refresh+retry test (mock 401 then 200, single refresh for two racing requests).
12. **Endpoints/none:** `core/api/endpoints.dart` already declares everything needed; no new constants.

## Acceptance criteria

1. Chrome/web against `--dart-define=API_BASE_URL=http://localhost:8080`: login → estimates appear → Confirm creates a ride (`POST /rides` succeeds through CORS) → matching screen shows.
2. No online driver → within ~5 s the app toasts "No drivers available" and returns home cleanly (locked-in; re-selecting trips re-creates a single ride, not a pile).
3. Driver accepts (run the driver WS client or a real driver app) → app navigates to active ride and shows driver marker/ETA (no WS needed for the accept detection if the poll catches it first).
4. Expired token: create-flow auto-refreshes and succeeds without the raw `UnauthorizedException` snackbar; a failed refresh logs out.
5. Backend: `go test ./...` green; curl e2e `login → POST /rides → GET /rides/current → POST /rides/:id/cancel` all 2xx; OPTIONS preflight lists `Idempotency-Key`.
6. App: `flutter analyze` zero new issues; `flutter test` full pass.

## Verification

```bash
# backend
go test ./... && go vet ./...
curl -i -X OPTIONS http://localhost:8080/api/v1/rides \
  -H 'Origin: http://localhost:5555' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type,authorization,idempotency-key'

# app
cd rider_app
flutter pub get
flutter analyze      # zero new issues
flutter test         # full pass

# live (web)
docker compose up -d && go run ./cmd/server
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080
```

## Non-goals / notes

- Driver flows, payments/tip/promos, real ETA, receipt/rating/tip UI are outside this plan (see 03/04/06/07).
- WS event *shape* parsing is already done (plan 01); this plan fixes transport + the missing `no_driver_available` status.
- The token-in-URL WS auth is required on web only; native targets may keep the `Authorization` header if desired. Guard against token leakage in logs (scrub in `debug_logger.go`).
- Backend stubs that would block this plan: none — `POST /rides`, `GET /rides/current`, `POST /rides/:id/cancel` are real.