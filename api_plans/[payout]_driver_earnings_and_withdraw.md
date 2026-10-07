---
tag: payout
depends_on: []
status: deferred
---

# Driver earnings ledger + `GET /driver/me/earnings` + `POST /driver/earnings/withdraw`

> **Status: 🟠 DEFERRED (2026-09-29).** The design below is settled and the decisions are recorded
> in `api_plans/STATUS.md`, but **no implementation is scheduled**. This is the server half of
> `driver_app_plans/STATUS.md` bug #6 ("No withdraw UI — `POST /driver/earnings/withdraw` is a
> stub"); bug #6 stays a kept-open, backend-blocked bug until this is picked up. Picking it up is
> gated on a product call (commission model + whether a real payout provider is ever integrated).
> Everything below is the ready-to-execute spec.

**Read first:**

- `internal/router/router.go:143` — `driver.GET("/me/earnings", platformHandler.StubPayment)`.
- `internal/router/router.go:221-222` — `r.POST("/api/v1/driver/earnings/withdraw", authMw, RequireRole("driver"), platformHandler.StubPayment)`.
- `internal/handler/platform.go:487-501` — `StubPayment`, the `200 {"status":"stub",...}` both return.
- `internal/service/ride.go:372-391` — the `completed` branch of `AdvanceStatus`; the booked fare
  snapshot (`ride.TotalFare`) is what a completion must credit. No fare is mutated here today.
- `internal/repository/ride_repo.go:13-25,22,114-167` — `RideRepository` + `UpdateRideStatus` /
  `CreateEvent` split (note: `ride_events` is deliberately best-effort — money must **not** copy
  that, see Invariants).
- `internal/service/fare.go:112` — `CalculateEstimate` now prices from the **landed** versioned,
  per-region `fare_rates` card (migration `019_region_fares.up.sql:42`, seeded by
  `make seed-fares`), which is the tariff the payout split must key off.
- `internal/model/ride.go` — `Ride` fare fields (`TotalFare float64`); `internal/model/user.go:28-38`
  — `Driver`.
- `internal/middleware/idempotency.go` — per-user `Idempotency-Key` store, used on create-ride
  (`router.go:248`). Cross-ref `api_plans/STATUS.md` → Landed `[errors]` (bug #22) — the replay path is
  now byte-faithful; a money endpoint should not reuse a replay path that returns `{}`.
- `internal/handler/ride.go:360-374` — `TipDriver` is itself a stub, so tips are **not** a money
  source in this plan.
- `tests/testutil/` — mock repos (invariant).

## Current state (verified)

- There is **no** earnings, wallet, balance, payout or withdrawal table, model, repo or service
  anywhere in `internal/` (grep across `internal/model|service|handler|repository|migrations`).
- Completion trusts the booked fare and does not record any money movement
  (`internal/service/ride.go:175-196`).
- `StubPayment` answers a fake success on both routes, so a client that called withdraw today would
  believe money moved.

## Decisions to record (add to `api_plans/STATUS.md` under a `[payout]` decisions section)

- **Integer cents** in the ledger (`amount_cents BIGINT`), converting the `float64` ride fare once at
  credit time — no float arithmetic on money.
- **No wallet column.** Available balance is `SUM(amount_cents)` over `status='available'` ledger
  rows; the ledger is the single source of truth (no drift, no reconciliation).
- **Commission defaults to 0** in dev, configurable via `PAYOUT_COMMISSION_RATE`; a per-region /
  versioned `fare_rates` + payout split is deferred (the landed `[fare]` card is the trigger).
- **Withdrawal is a recorded ledger debit, not a bank transfer.** Status `pending` for an out-of-band
  provider/ops step; there is **no** external payout integration in this plan. The API is honest
  about this (`status: "pending"`), so the client shows "requested", not "paid".
- **Withdraw is idempotent** (`Idempotency-Key`, like create-ride).

## Scope

1. **Migration (append-only, next free number — re-check; 016 if the ratings plan lands first).**
   ```sql
   CREATE TABLE driver_earnings (
       id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
       driver_id       UUID        NOT NULL REFERENCES drivers(user_id),
       ride_id         UUID        REFERENCES rides(id),
       kind            TEXT        NOT NULL CHECK (kind IN ('ride_earning','tip','adjustment','withdrawal')),
       amount_cents    BIGINT      NOT NULL CHECK (amount_cents <> 0),   -- credit +, debit -
       status          TEXT        NOT NULL DEFAULT 'available'
                                   CHECK (status IN ('available','pending','paid','failed','reversed')),
       currency        TEXT        NOT NULL DEFAULT 'USD',
       idempotency_key TEXT        NOT NULL DEFAULT '',
       created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );
   CREATE INDEX idx_driver_earnings_driver ON driver_earnings(driver_id, status, created_at);
   CREATE UNIQUE INDEX idx_driver_earnings_ride_earning ON driver_earnings(ride_id)
       WHERE kind = 'ride_earning';   -- double-credit guard
   ```
2. **Model + repository.** `model.DriverEarning`; a new `EarningsRepository` (interface + pg impl)
   exposing `CreditRideEarning(driverID, rideID string, amountCents int64) error`,
   `GetEarningsSummary(driverID string) (*EarningsSummary, error)`, and
   `CreateWithdrawal(driverID string, amountCents int64) (*DriverEarning, *EarningsSummary, error)`.
   `CreateWithdrawal` runs in a transaction: `SELECT ... FOR UPDATE` (or `pg_advisory_xact_lock`
   on the driver) to serialise concurrent withdrawals, re-check available balance inside the lock,
   insert the debit. Register the repo in `internal/router/router.go:SetupWithRoutes` and add mocks
   to `tests/testutil/`.
3. **Credit on completion.** In `RideService.AdvanceStatus`'s `completed` branch
   (`internal/service/ride.go:175`), insert a `ride_earning` credit
   (`amount_cents = round(ride.TotalFare*100)`, net of `PAYOUT_COMMISSION_RATE`). Unlike
   `ride_events`, **a failed credit is not best-effort**: return the error so the endpoint answers
   5xx (a failed money write never answers success). The partial unique index makes a retry safe
   (an existing row is a no-op, not a double credit). `RideService` gains the earnings repo.
4. **`GET /driver/me/earnings`.** Return a summary that the app can map onto its existing display
   contract (`monthTotal`/`monthTrips`/`loadedTotal`/`completedTrips`/`months[]`):
   ```json
   {"earnings":{
      "available_cents":12000,"pending_cents":0,"withdrawn_cents":5000,"lifetime_cents":17000,
      "currency":"USD",
      "month_total_cents":4500,"month_trips":3,"completed_trips":11,
      "months":[{"month":"2026-09","total_cents":4500,"trips":3}]
   }}
   ```
   `available_cents` is the withdrawable amount; `month_total_cents`/`months` come from the ledger
   grouped by `created_at`. Implement via `SUM`/`GROUP BY` in `GetEarningsSummary`.
5. **`POST /driver/earnings/withdraw`.** Body `{"amount_cents": N}` (integer cents). Validate
   `N > 0` and `N >= PAYOUT_MIN_WITHDRAW_CENTS` → else 422 `VALIDATION_ERROR`; `N <= available`
   else 409 `CONFLICT` ("insufficient balance"); insert the `withdrawal` debit and answer
   `200 {"withdrawal":{...},"earnings":{...updated summary...}}`. Wrap the route with
   `idempotencyMw` (`internal/router/router.go:222`) so a retried `Idempotency-Key` replays instead
   of double-debiting. A DB failure is 500 `INTERNAL`.
6. **Config** (`internal/config/config.go`): `PAYOUT_COMMISSION_RATE` (default `0`),
   `PAYOUT_MIN_WITHDRAW_CENTS` (default e.g. `500`), `PAYOUT_CURRENCY` (default `USD`), parsed
   fail-closed like the elevation bools.
7. **Docs/spec.** Swagger annotations for both handlers; regenerate the spec (`cmd/openapi`). Add an
   `Earnings` section to `RIDER_API_GUIDE.md` stating plainly that withdraw records a `pending`
   debit and no money moves externally yet.
8. **Cross-app.** The driver-app withdraw UI + swapping `earningsProvider` to the endpoint is
   `driver-planner`'s follow-up (bug #6). Once landed, drop the "kept open" blocker note on bug #6
   in `driver_app_plans/STATUS.md`.

## Out of scope

- Real payout/bank/FCM integration; `paid`/`failed` transitions are an ops/provider step later.
- Tips (`TipDriver` is a stub) — `kind='tip'` exists in the schema for forward-compat but nothing
  writes it yet.
- Per-region fares, commission versioning, tax/receipt documents.

## Invariants carried in

- Migrations append-only; only `*.up.sql` runs; version = numeric prefix.
- Success paths/status codes for valid existing requests never change.
- **A failed write never answers success** — a failed earning credit or withdrawal is 5xx, and the
  cause is logged (`c.Error`). Money writes do **not** follow the best-effort `ride_events` rule.
- Money is integer cents; no float arithmetic and no `err.Error()` in a response body.
- Concurrency: two withdrawals must not overdraw (row lock / advisory lock inside the tx).
- Mocks in `tests/testutil` move in lockstep with the repository interface.

## Tests

- Integration (DB-backed):
  - Completing a ride writes exactly one `ride_earning` credit of `total_fare`; a retried completion
    does not double-credit.
  - `GET /driver/me/earnings` totals/grouping match the ledger; a driver with no earnings gets a
    zeroed summary, not a 404.
  - Withdraw: happy path debits available and returns the new summary; over-balance → 409; zero /
    below-minimum → 422; concurrent withdrawals do not overdraw.
  - Idempotent replay of the same `Idempotency-Key` returns the first withdrawal, no second debit
    (note the bug #16 dependency for a correct replayed body).
  - Completion with a failing earnings insert → 5xx, not a false `completed` 200.
- `tests/testutil` mocks implement the new repo so `make test` passes without Docker.

## Verify

```bash
make test               # unit tests, no DB (mocks)
make lint
make test-integration   # DB-backed; needs docker compose up -d
gofmt -w <files> && go vet ./...
```
