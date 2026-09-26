# Plan 07 — Safety/support (ack-only), skip list, and backend follow-ups

> **Status: 🟠 SKIP LIST ONLY** (re-audited 2026-09-25). The skip list below was
> re-verified against `internal/router/router.go` and is still accurate: never
> build a real surface on a backend STUB. Nothing else landed —
> `features/safety/{safety_screen,safety_repository}.dart` do not exist, so
> `POST /sos` and `POST /feedback` are declared in `endpoints.dart` and never
> called (US-12 stays ack-only-missing). This is the cheapest remaining win on
> the board: two small files and a dialog.
> ⚠️ A real SOS needs the missing push-delivery/alert pipeline; per the rider app
> rule (SAF-1) an ack-only SOS is acceptable **only** if the UI says so plainly.

Close the loop on the remaining driver-facing API surface and, importantly,
**write down what we deliberately don't build** and why. This is the "adopt
everything the API `already` offers" sweep that 01–06 don't cover.

## Facts (re-audited)

- **Ack-only endpoints (harmless, tiny):**
  - `POST /api/v1/sos` — body `{"lat":..,"lng":..}` → `{"status":"ok"}`
    (emergency ack; no follow-up action server-side).
  - `POST /api/v1/feedback` — body `{"type":"app_issue","message":"..."}` → ack.
  Both are smoke-grade: fire-and-forget with a success SnackBar, no retry loop.
- **Skip list** (each with the repo-wise reason, from `USER_STORIES.md` Part B +
  `DRIVER_APP_PLAN.md` §2.2):
  | Endpoint | Reason to skip / gate |
  |---|---|
  | `GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents` | Backend STUB — gated in plan 06 |
  | `GET /driver/me/earnings`, `POST /driver/earnings/withdraw` | Backend STUB — client-side derived in plan 05 |
  | `GET /driver/ratings` | Stub + profile already carries `rating_summary` |
  | `GET /driver/rides/queue` | Stub; offer push covers live demand |
  | `GET /driver/rides/:id/rider` | Stub — real info arrives via `ride.updated` |
  | `POST /driver/rides/:id/decline` (HTTP) | No server route; WS decline is the only channel |
  | `POST /driver/rides/:id/notify-arrival` | Stub — the arrival status transition already notifies the rider |
  | Rider-side features (rides create, favorite places, payments, receipts, tip, promos, reviews of driver seen ahead) | Out of the driver's domain — the API's correct consumer is `rider_app` |
  | Social login, verify-email/phone | `PARTIAL`/stub on backend; skip until backend completes |

- **Backend follow-ups worth a ticket** (not app work):
  1. Implement `GET /driver/me/earnings` (aggregate `completed_at`, `total_fare`)
     so plan 05 can swap the derived sum for the real one.
  2. Decide the WS `decline` response: today it's silent (no `ride.decline-ack`);
     the app relies on the local state change + server 30 s expiry.
  3. `photo_url` avatar: no upload endpoint exists; consider `PUT /driver/me/photo`
     (multipart) and thread it through plan 06.
  4. `requested_at`→offer latency: app is fine, but worth logging server-side.
  5. `GET /driver/rides/queue`: defer feature until real demand queueing exists.

## Work

1. `sharing` is **not** a driver feature yet (rider_app uses `share_plus` for
   receipts). Leave `share_plus` in pubspec (harness can't trim deps safely);
   note it as unused-but-retained for rider parity.
2. `lib/features/safety/presentation/safety_screen.dart` (new, small):
   - "Emergency SOS" button → `POST /sos` with last known position
     (plan 02 location) → SnackBar ack.
   - "Send feedback" → dialog → `POST /feedback` (type `app_issue`) → SnackBar.
   - Entry tile from settings screen.
3. `lib/features/safety/data/safety_repository.dart` (new): the two fire-and-forget
   calls via `ApiClient`; errors only surface as a snackbar (never block).
4. Add `requested_at`/sos/feedback endpoints to `lib/core/api/endpoints.dart`
   (sos + feedback belong on the API base; verify grouping against
   `geo/handler` mounting — both live under `/api/v1`).

## Tests

- `test/features/safety/presentation/safety_screen_test.dart`: SOS button sends
  body with coords, shows ack snackbar; failure shows error snackbar; feedback
  dialog posts `app_issue` and closes on success.
- `test/core/api/api_client_test.dart` (extend): `POST /sos` and `POST /feedback`
  hit the right URLs with the right request bodies.

## Acceptance

- No UI ever reaches a skipped STUB endpoint.
- SOS + feedback are available but non-blocking (snackbar-level ack).
- The skip list is the single source of truth for "why isn't X in the driver
  app?" — point reviewers at `driver_app_plans/07_safety_support_skip.md`.

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: tap SOS → server logs the request; send feedback → ack snackbar appears.