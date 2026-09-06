# 07 — SAF-1 SOS + explicit skip list + backend follow-ups

Small: wire the SOS button (with honest caveats) and document what we deliberately do NOT build.

**Read first:** `rider_app/lib/features/home/presentation/security_screen.dart`, `rider_app/lib/core/api/endpoints.dart`, plan `01-ws-contract.md`.

## SAF-1 — SOS button

```http
POST /api/v1/sos   # body {lat, lng} → 201 {message, alert:{... status:"active"}}
```
Backend reality (`handler/platform.go:50-67`): returns an ack + echoes the payload but **persists nothing and dispatches nothing** (`sos_alerts` table unused). Treat as ack-only.

1. New `features/home/data/security_provider.dart`: `sendSos()` posts last known position (`geolocator` last fix or `RideState` pickup) → `POST /sos`.
2. `security_screen.dart`: replace "coming soon" with an "Emergency" button → confirm dialog → `sendSos()` → on 201 show "Emergency alert sent — support has been notified" banner, on error show failure.
3. **In-app note (honest):** add a small caption "Note: alert acknowledgment only — backend does not yet persist or dispatch SOS alerts". Do not claim real dispatch.

## Skip list (backend still STUB — do NOT build UI)

| Area | Endpoints | Why skip |
|---|---|---|
| Payment methods | `GET/POST/DELETE /rider/payment-methods` | all STUB (`StubPayment`) — keep `PaymentScreen` placeholder |
| Tipping | `POST /rides/:id/tip` | STUB |
| Promotions | `GET /promotions`, `POST /promotions/apply` | STUB (empty list / ack) |
| Place details/geocode | `GET /places/geocode`, `GET /places/details` | STUB (`{"place":null}`) |
| Analytics | `GET /geo/isochrone`, `GET /heatmap` | STUB/placeholder |
| Devices/push | `POST /devices`, `DELETE /devices/:token` | no push pipeline |
| Feedback | `POST /feedback` | ack only |
| Social/verify | `POST /auth/social`, `verify-email`, `verify-phone` | STUB/PARTIAL (code ignored) |
| Destination change | `PUT /rides/:id/destination` | STUB (ack, no mutation) |
| Driver side | all `/driver/*` + `ride.accept`/`ride.decline` | different role/app |

## Backend follow-ups (file as issues; not app work)

1. Push `ride.updated status:"no_driver_available"` over WS (today only DB-updated) — or keep poll but call it out.
2. Keep accept-payload ETA accurate: it already routes driver→pickup, but falls back to `300` when driver location/routing is unavailable (`service/dispatch.go:160-184`) — readying the WS push data is enough, the app treats `300` as "unknown".
3. Vehicle CRUD (`GET/PUT /driver/me/vehicle`) so accepted `driver.vehicle` is not a fabricated test value.
4. `POST /sos` persistence + dispatch; `drivers.rating_summary` recalculation.

## Tests — `test/features/home/data/security_provider_test.dart` + screen

- 201 → success banner; non-2xx → failure snack; confirm dialog guards double-fire.

## Verify

```bash
cd rider_app && flutter analyze && flutter test
```

## Acceptance

- SOS button posts the real endpoint and communicates its ack-only limitation in the UI.
- No new UI was built around any skip-listed endpoint.