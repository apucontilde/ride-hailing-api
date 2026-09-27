---
tag: safety
depends_on: []
status: open
---

# Safety/support (ack-only), skip list, and backend follow-ups

> **Status: 🟠 OPEN — skip list only.** The skip list below was re-verified against
> `internal/router/router.go` and is still accurate: never build a real surface on
> a backend STUB. Nothing else landed — `features/safety/{safety_screen,
> safety_repository}.dart` do not exist, so `POST /sos` and `POST /feedback` are
> declared in `endpoints.dart` and never called (US-12 stays ack-only-missing).
> This is the cheapest remaining win on the board: two small files and a dialog.
> ⚠️ A real SOS needs the missing push-delivery/alert pipeline; per the rider app
> rule (SAF-1) an ack-only SOS is acceptable **only** if the UI says so plainly.
>
> This plan only depends on the already-landed location feed (old 02) for "last
> known position"; both prerequisite plans are in `STATUS.md`.

Close the loop on the remaining driver-facing API surface and, importantly,
**write down what we deliberately don't build** and why. This is the "adopt
everything the API `already` offers" sweep that the landed plans don't cover.

## Facts (re-audited)

- **Ack-only endpoints (harmless, tiny):**
  - `POST /api/v1/sos` — body `{"lat":..,"lng":..}` → `{"status":"ok"}`
    (emergency ack; no follow-up action server-side).
  - `POST /api/v1/feedback` — body `{"type":"app_issue","message":"..."}` → ack.
  Both are smoke-grade: fire-and-forget with a success SnackBar, no retry loop.
- **Skip list** (each with the repo-wise reason, from `USER_STORIES.md` Part B +
  `DRIVER_APP_PLAN.md` §2.2). This is the **authoritative** list — the single
  source of truth for "why isn't X in the driver app?":
  | Endpoint | Reason to skip / gate |
  |---|---|
  | `GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents` | Backend STUB — gated in `STATUS.md` `[profile]` |
  | `GET /driver/me/earnings`, `POST /driver/earnings/withdraw` | Backend STUB — client-side derived in `STATUS.md` `[history]` |
  | `GET /driver/ratings` | Stub + profile already carries `rating_summary` |
  | `GET /driver/rides/queue` | Stub; offer push covers live demand |
  | `GET /driver/rides/:id/rider` | Stub — real info arrives via `ride.updated` |
  | `POST /driver/rides/:id/decline` (HTTP) | **Route exists but is mis-wired to the wrong handler**: `internal/router/router.go:155` binds it to `platformHandler.StubPayment` (`internal/handler/platform.go:499-504`), so it answers `200 {"status":"stub","message":"Payment integration pending"}` and **records no decline** — a copy-paste bug, not a missing route. The WS `decline` channel is the only working path today; file the backend ticket (see follow-up 1) |
  | `POST /driver/rides/:id/notify-arrival` | Real but redundant handler (`internal/router/router.go:159` → `ArrivalNotification`, `internal/handler/platform.go:475-477`); the `PUT /:id/status` transition already notifies the rider, so no app UI is needed |
  | Rider-side features (rides create, favorite places, payments, receipts, tip, promos, reviews of driver seen ahead) | Out of the driver's domain — the API's correct consumer is `rider_app` |
  | Social login, verify-email/phone | `PARTIAL`/stub on backend; skip until backend completes |

- **Backend follow-ups worth a ticket** (not app work):
  1. **Re-point `POST /driver/rides/:id/decline` at a real decline handler.** It is currently
     bound to `StubPayment` (`internal/router/router.go:155`), so a client that declines over HTTP
     gets a cheerful `200 {"status":"stub","message":"Payment integration pending"}` while the
     ride silently stays offered until the 30 s expiry. Either implement the handler or return
     `501`; never leave a mutating route answering with a payment stub.
  2. Implement `GET /driver/me/earnings` (aggregate `completed_at`, `total_fare`)
     so the history card can swap the derived sum for the real one.
  3. Decide the WS `decline` response: today it's silent (no `ride.decline-ack`);
     the app relies on the local state change + server 30 s expiry.
  4. `photo_url` avatar: no upload endpoint exists; consider `PUT /driver/me/photo`
     (multipart) and thread it through the profile surface.
  5. `requested_at`→offer latency: app is fine, but worth logging server-side.
  6. `GET /driver/rides/queue`: defer feature until real demand queueing exists.

## Work

1. `sharing` is **not** a driver feature yet (rider_app uses `share_plus` for
   receipts). Leave `share_plus` in pubspec (harness can't trim deps safely);
   note it as unused-but-retained for rider parity.
2. `driver_app/lib/features/safety/presentation/safety_screen.dart` (new, small):
   - "Emergency SOS" button → `POST /sos` with last known position
     (`lastPositionProvider` from `core/location/location_service.dart:55`) →
     SnackBar ack.
   - "Send feedback" → dialog → `POST /feedback` (type `app_issue`) → SnackBar.
   - Entry tile from the settings screen. ⚠️ **Sequencing interlock, not a dependency** —
     this plan stays independent (its other three work items need nothing else), but the
     `settings_screen.dart` row is contested: `driver_app_plans/02_[nav]_driver_sidebar_adoption.md`
     collapses that file into the shared `AppSettingsScreen`. Whichever lands first, the row
     ends up as an `extraSections` entry — an `AppSettingsSection(title:, rows: [AppSettingsRow(…)])`
     — never a bespoke `Card > ListTile`:
     - nav first → add the row to `AppSettingsScreen(extraSections: …)`.
     - safety first → a plain row is fine *only if* you also note it in that plan's Risks;
       whoever lands the nav plan ports it into `extraSections`.
3. `driver_app/lib/features/safety/data/safety_repository.dart` (new): the two
   fire-and-forget calls via `ApiClient`; errors only surface as a snackbar (never
   block).
4. Add sos/feedback endpoints to `driver_app/lib/core/api/endpoints.dart`
   (both live under the API base `/api/v1`; verify grouping against the
   `geo/handler` mounting).

## Tests

- `driver_app/test/features/safety/presentation/safety_screen_test.dart`: SOS
  button sends body with coords, shows ack snackbar; failure shows error snackbar;
  feedback dialog posts `app_issue` and closes on success.
- `driver_app/test/core/api/api_client_test.dart` (extend): `POST /sos` and
  `POST /feedback` hit the right URLs with the right request bodies.

## Acceptance

- No UI ever reaches a skipped STUB endpoint.
- SOS + feedback are available but non-blocking (snackbar-level ack).
- The skip list above is the single source of truth for "why isn't X in the driver
  app?" — point reviewers at `driver_app_plans/[safety]_sos_feedback.md`.

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: tap SOS → server logs the request; send feedback → ack snackbar appears.
