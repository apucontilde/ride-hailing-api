# rider_app — Minimal Build Plans (index)

Goal: update `rider_app/` so it actually drives the current backend API (`051ecaf`) across screens. Each plan below is **self-contained and small** — sized so a fresh model context window can execute it by reading *this file only* plus the `Read first` files it names (no whole-repo exploration). Facts (endpoint payloads, current bugs, code refs) are embedded inline; the authoritative source is `USER_STORIES.md` (Appendix matrix) + `RIDER_APP_API_PLAN.md`.

## Plans

| File | Work | Depends on |
|---|---|
| `01-ws-contract.md` | WS-1: realign WS event handling to backend contract (**do first**) | none |
| `02-cancel-and-current-poll.md` | LC-1 real cancel + LC-2 `GET /rides/current` poll | 01 |
| `03-receipt-rate-tracking.md` | LC-3 ride detail + receipt + rating + LC-4 live tracking | 01 |
| `04-history.md` | LC-5 real history list | none |
| `05-idem-and-location.md` | LC-0 idempotency-key reuse + GEO-1 rider-location ping (GEO-3 keeps `nearbyDriversProvider`) | none |
| `06-auth-and-profile.md` | AC-1 forgot-password + AC-2 real profile + AC-3 401 auto-refresh | none |
| `07-sos-and-skip.md` | SAF-1 SOS + explicit skip list + backend follow-ups | 01 |
| `08-user-stories-improvements.md` | Suggested changes to `USER_STORIES.md` | none |

Expected order: 01 → [02, 03] → [04, 05, 06] → 07. Each plan has its own acceptance criteria; nothing below requires another plan to pass first except as noted.

## Facts everything relies on (re-audited at `051ecaf`)

- **Endpoint base:** `{API_BASE_URL}/api/v1`, defined in `rider_app/lib/core/api/endpoints.dart`. All protected calls send `Authorization: Bearer <access_token>`.
- **WS (receive-only for rider):** backend pushes `ride.updated` (statuses `pending/accepted/driver_arrived/in_progress/completed/cancelled`), `driver.location`, and `ride.offer` (driver-only). See `01-ws-contract.md` for exact shapes. Backend **never** pushes the app's invented `ride_matched` / `driver_moved` / `ride_arrived` / `ride_completed`.
- **Already wired correctly:** `POST /auth/register|login|logout`, `params GET /rider/me` (auth check), `GET /estimates/price`, `GET /places/autocomplete`, `POST /rides`, WS `connect`.
- **Declared-but-unused** (`endpoints.dart`): `eta`, `currentRide`, `rideById`, `cancelRide`, `rateRide`, `tipRide`, `receipt`, `driverLocation`, `paymentMethods`, `ridesHistory`, `sos`.
- **Never declared:** `PUT /geo/rider/location`, `PUT /rider/me`, `PUT /rider/me/status`.
- **Fake UI today:** ForgotPasswordScreen (fake), HistoryScreen ("No rides yet"), PaymentScreen ("coming soon"), SecurityScreen ("coming soon"), ProfileScreen (hardcoded), `ActiveRideScreen._cancelRide` (1s mock).
- **API 204 note:** `PUT /geo/rider/location` returns **204 no body** — response-parsing must not assume JSON.

## Golden rules

1. Tests: `mocktail` + `http_mock_adapter`, mirroring the existing suites in `rider_app/test/features/...` and `rider_app/test/core/...`.
2. Never build UI around a backend STUB (see skip list in `07-sos-and-skip.md`).
3. Don't remove public providers used by other screens; extend them.

## Verification (every plan)

```bash
cd rider_app
flutter pub get
flutter analyze      # zero new issues
flutter test         # full pass
```

Optional live check: `docker compose up -d` + `go run ./cmd/server`, then run the app with `--dart-define=API_BASE_URL=http://localhost:8080`.