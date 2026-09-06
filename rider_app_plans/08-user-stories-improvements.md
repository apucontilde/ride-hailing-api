# 08 — Suggested changes & improvements to `USER_STORIES.md`

Proposals grounded in the rider-app audit (what the app actually does vs. what the doc claims), ranked by impact. Apply all or pick — each is an edit + a matrix-cell update.

## 1. New app-tier mark: 🟠 "wired — backend returns stub data" (split the 🟡)

Problem: today `🟡 partial` conflates two different rider-app situations:
- *call works but the backend still returns placeholder data* (no such cell today — the first appears when a plan wires a stub), and
- *app itself is half-built* (ProfileScreen hardcoded).

Proposal — add to the legend and the Appendix/Part-C cells:
| 🟠 wired–stub | The app calls the endpoint correctly; the backend still returns stub data. |
Re-tag any futures: none today (`estimates/price` is now real — verified `handler/platform.go:279` + `service/fare.go`, so it stays 🟢). Keep `🟡` for genuinely mixed apps (US-1 register-real + forgot-fake).

## 2. New stories for screens the plan actually builds

The three-axis matrix exposes gaps that are *stories worth writing* (driver-app plan has none today for these):

- **US-15 "View fare receipt after the trip"** — `GET /rides/:id/receipt` + WS `fare`; acceptance: receipt dialog numbers render from the API (built in plan `03-receipt-rate-tracking.md`).
- **US-16 "No driver available"** — separate from US-6 because the backend **does not push** this event; acceptance: the app detects it via `GET /rides/current` polling (plan `02`). API tier today: [PARTIAL] (works only via polling).
- **US-17 "Re-book from history"** — extends US-14; acceptance: tap a past trip re-fills the booking form and pre-request that the same route be reusable. API: [IMPLEMENTED] (`GET /rides/history`); client: plan `04`.

## 3. Correct story claims that don't match the WS contract

- **US-7 "Track the matched driver"**: replace "ETAs are shown" language with the honest contract — driver data arrives in the `accepted` `ride.updated` payload; live moves arrive as `driver.location`; `GET /drivers/:id/location` is the polling fallback; `driver.rating` currently parses to `0.0` so the app must fall back to "New". Acceptance: no invented keys (`driver_lat` etc.) remain.
- **US-8 "Ride in progress"**: add explicit acceptance "app renders the route polyline from `GET /navigation/route`" (currently the app never fetches it).
- **US-6 "Wait for a driver"**: add a note that WS may be silent during long searches (5 radii × 30 s) and the searching UI must not fake a timeout.

## 4. Tighten `[PARTIAL]` semantics in the header

The current legend says `[PARTIAL]` = "Works but with gaps." Add the explicit rule (already used informally): **story tags judge the backend API tier only**; the app tier is whatever the per-story `App status:` line says. This prevents someone "fixing" a PARTIAL story by changing the app when the endpoint is actually fine (e.g. US-11: API is [IMPLEMENTED] while the rider app's cancel is ❌).

## 5. Add acceptance criteria as a per-story block

Add one line per story, e.g. for US-11:
```
- **Acceptance:** pre-pickup cancel posts `POST /rides/:id/cancel`; WS `cancelled` returns the user to Home; fee never charged (backend gap).
```
Mark each acceptance with the plan task that satisfies it (WS-1, LC-1, etc.) so doc → code linkage is traceable.

## 6. Keep the matrix truthful after each plan is merged

Append to the Appendix footer a "last-applied:" line with the plan number. Suggested convention: an endpoint becomes 🟢/🟠 only when its plan merged and `flutter test` passed, otherwise keep ⚪/🟡. This keeps the doc honest between releases.

## 7. Minor copy fixes spotted during the audit

- `USER_STORIES.md` intro/Appendix: `GET /auth/refresh` rider cell says "defined, never auto-triggered" — after plan `06` lands, flip to 🟢/🟡 depending on whether the 401 interceptor retried once.
- Part A summary note "rider app actually wires ~12 endpoints" — recompute the count after each plan (plans 02–07 wire ~8 more).
- Consider a `tests:` column in each story pointing at the test file that proves it (e.g. `ride_status_provider_test.dart`) — low cost, high traceability.
- Verify-email/phone: leave [PARTIAL] but mark clearly in US-1/US-D1 that neither app calls them yet (already in the matrix; keep in sync).