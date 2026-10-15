---
tag: payout
depends_on: ["api_plans/[payout]_driver_earnings_and_withdraw.md"]
status: open
---

# Driver earnings + withdraw UI (driver bug #5)

> **Status: OPEN (authored 2026-10-15). Driver half of the `[payout]` chain.**
>
> **Numbering rationale (why `01_`):** this plan is **dependent**. Its `depends_on` names
> another *open* plan file — `api_plans/[payout]_driver_earnings_and_withdraw.md` (the chain
> head, `status: open`, `api_plans/STATUS.md:489`) — not landed capability. Per
> `.opencode/skills/plan-management/SKILL.md`, a non-empty `depends_on` naming an open plan is
> exactly what earns the `NN_` prefix; a plan whose prerequisite is already landed stays
> unnumbered. Numbering restarts per tag, so this is stage `01` of the `[payout]` chain; the
> cross-domain api plan is the unnumbered head.

## ⛔ Do NOT implement the UI before the API plan lands

Today both endpoints are `StubPayment` stubs and answer a **fake success**:

- `GET /driver/me/earnings` → `internal/router/router.go:223` → `platformHandler.StubPayment`.
- `POST /driver/earnings/withdraw` → `internal/router/router.go:308` → `platformHandler.StubPayment`.
- `StubPayment` answers `200 {"status":"stub","message":"Payment integration pending"}`
  (`internal/handler/platform.go:637-641`).

A client that called withdraw today would believe money moved. The authoritative skip list
(`driver_app_plans/STATUS.md` → Skip list) marks both rows "Backend STUB — client-side derived",
and the domain invariant is **never build UI on a backend STUB**. So this plan is blocked until
`api_plans/[payout]_driver_earnings_and_withdraw.md` lands and the two routes stop pointing at
`StubPayment`. (Line-number correction for the record: the brief for this plan cited
`router.go:221-222`; that range is `GET/PUT /driver/me/vehicle`. The earnings routes are `:223`
and `:308`, matching the skip-list citation.)

## Canonical API contract — adopted verbatim from the api plan

Everything below is **copied from** `api_plans/[payout]_driver_earnings_and_withdraw.md`
(§4, §5, §"Decisions to record"); it is the canonical source and is **not redefined here**. Do
not change it in this plan; if the api plan changes, this plan follows.

### `GET /driver/me/earnings` (Bearer, driver)

```json
{"earnings":{
   "available_cents":12000,"pending_cents":0,"withdrawn_cents":5000,"lifetime_cents":17000,
   "currency":"USD",
   "month_total_cents":4500,"month_trips":3,"completed_trips":11,
   "months":[{"month":"2026-09","total_cents":4500,"trips":3}]
}}
```

- The envelope key is **`earnings`** (the api plan's shape). The plan brief paraphrased it as
  `{"summary":{...}}`; that is **not** the contract — parse `earnings`.
- `available_cents` is the withdrawable amount. A driver with no earnings gets a **zeroed**
  summary, not a 404.
- All money fields are **integer cents** (`*_cents`).
- `currency` is the ledger's single ISO-4217 code (api `PAYOUT_CURRENCY`, default `USD`).

### `POST /driver/earnings/withdraw` (Bearer, driver, `Idempotency-Key`)

- Request body: `{"amount_cents": N}` (integer cents).
- Validation: `N > 0` **and** `N >= PAYOUT_MIN_WITHDRAW_CENTS` → else **422 `VALIDATION_ERROR`**.
- Balance: `N <= available` → else **409 `CONFLICT`**, message "insufficient balance".
- Success → `200 {"withdrawal":{...},"earnings":{...updated summary, same shape as above...}}`.
- The `withdrawal` object is a `driver_earnings` ledger row (schema in the api plan) with
  `status: "pending"`. **A withdrawal is a recorded ledger debit, not a bank transfer** — there
  is no external payout provider in this plan, and the API is honest about it via `status`.
- A DB failure is **500 `INTERNAL`**; the write is **not** best-effort (a failed money write
  never answers success).
- Idempotent: a retried `Idempotency-Key` replays the first withdrawal and does **not**
  double-debit.

### Error envelope

`{"error":{"code":...,"message":...}}` (`internal/handler/respond.go`); `message` is public and
is rendered verbatim. Do not invent a second error shape.

## Money-unit boundary (explicit rule)

- The ride JSON boundary is **major units** (`TotalFare` dollars) and the shared
  `formatMoney(double, {String? currency})` takes **major units** —
  `shared/lib/src/utils/money.dart:12`.
- The **earnings endpoints are the exception**: they carry **integer cents**
  (`available_cents`, `month_total_cents`, …). Convert once, at render only:
  `formatMoney(cents / 100, currency: summary.currency)`, via a driver-local
  `formatCents(int cents, {String? currency})` in `features/payout/model/driver_earnings.dart`.
  Never treat a `_cents` value as dollars and never `toStringAsFixed` money by hand.
- `currency` is always the server's; a null/empty code renders bare (no `$` invented), exactly
  as `formatMoney` already behaves.

## Deliverables

### 1. New feature folder `driver_app/lib/features/payout/`

Mirrors the `features/safety/` (`data/` + `presentation/`) and `features/rides/`
(`data/` + `providers/` + `model/`) layouts. No shims.

- **`model/driver_earnings.dart`**
  - `DriverEarningsSummary.fromJson` — cents `int` fields `availableCents`, `pendingCents`,
    `withdrawnCents`, `lifetimeCents`, `monthTotalCents`, `monthTrips`, `completedTrips`;
    `String? currency` (blank → `null`); `List<DriverEarningsMonth> months`.
  - `DriverEarningsMonth.fromJson` — parses the server's `"YYYY-MM"` `month` string into a
    `DateTime`, keeps `totalCents`/`trips`, and exposes the existing `label` formatter
    (`September 2026`) so the card's month rows are unchanged.
  - A lenient `DriverWithdrawal` (or just read `withdrawal.status`) — only `status` and
    `amountCents` are relied on; unknown/missing keys must not throw.
  - Driver-local `formatCents`.
- **`data/payout_repository.dart`**
  - `PayoutRepository` constructed with the shared `ApiClient` (same seam as
    `RidesRepository`, `driver_app/lib/features/rides/data/rides_repository.dart:312`); **no
    second HTTP client**.
  - `Future<DriverEarningsSummary> fetchEarnings()` → `GET ApiEndpoints.driverEarnings`.
  - `Future<DriverEarningsSummary> requestWithdrawal({required int amountCents, required String
    idempotencyKey})` → `POST ApiEndpoints.driverEarningsWithdraw`,
    `data: {'amount_cents': amountCents}`,
    `options: Options(headers: {'Idempotency-Key': idempotencyKey})`, returns the updated
    `earnings` summary and surfaces the `withdrawal` status.
  - Both endpoints are already declared — `driver_app/lib/core/api/endpoints.dart:23,25`
    (`driverEarnings`, `driverEarningsWithdraw`) — so no endpoint registry change.
  - `payoutRepositoryProvider` wired to `apiClientProvider`.
- **`providers/payout_providers.dart`**
  - `earningsProvider` — replace the placeholder. An `AsyncNotifierProvider`
    (`EarningsNotifier`) that calls `fetchEarnings()`, is **lazy** (fetched when a watching
    screen mounts, like `ratedRidesProvider`) and non-autoDispose, exposes `refresh()`, and
    keeps a resolved value readable across a refresh (`valueOrNull`).
  - `withdrawControllerProvider` — owns submit state (`idle` / `submitting` / `submitted` /
    `error`) and the **idempotency-key lifecycle** (below). A double-tap/submit-while-in-flight
    is a no-op.
- **`presentation/withdraw_sheet.dart`**
  - `showWithdrawSheet(context, ref)` — a `showModalBottomSheet`, mirroring the landed
    `showRateSheet` pattern (`driver_app/lib/features/rides/presentation/rate_sheet.dart`).
  - Amount entry (major units in the field, converted to cents on submit), the available
    balance, min-amount and above-balance validation, a Submit button, and the pending copy
    from §4.
- **`payout_config.dart`**
  - `const int payoutMinWithdrawCents = 500;` — a **mirror** of the documented
    `PAYOUT_MIN_WITHDRAW_CENTS` default (api plan §6). It is a pre-submit hint only; the server
    is authoritative and a config divergence surfaces as its 422 `message`, rendered verbatim.
    Mark this mirror loudly and treat "expose the min in the earnings summary" as a non-blocking
    api follow-up so the mirror can be retired.

### 2. Swap `earningsProvider`'s source (the central deliverable)

`driver_app/lib/features/rides/providers/history_provider.dart` currently carries a **placeholder**
earnings model and derives it from loaded rides:

- `EarningsMonth` `:136-174`; `EarningsSummary` `:181-306` with
  `factory EarningsSummary.from(List<Ride> rides, {DateTime? now})`; `earningsProvider`
  `:307-313` = `historyProvider` rides summed client-side.
- Its own comment `:174-180` says `GET /driver/me/earnings` and
  `POST /driver/earnings/withdraw` are the future sources and to swap the provider once the
  backend ships.

**Action:** delete the placeholder block (`history_provider.dart:135-313`) and point the card at
the new endpoint-backed `earningsProvider`. `HistoryNotifier`/`historyProvider` (`:1-133`) are
untouched — history pagination stays exactly as landed.

### 3. Disposition of `EarningsSummary` / `EarningsMonth`

**Superseded and removed** (straight replacement in `driver_app/`; these are driver-app-local
files, not `shared/`, so no re-export shim is minted and the "shared may only be ADDed" rule is
not engaged). The wire model in `features/payout/model/driver_earnings.dart` replaces them.

- The server now supplies `currency`, `available_cents`, `pending_cents`, `withdrawn_cents` and
  `lifetime_cents`, so the client-side sum, the `completed`-only filter, the per-month bucketing,
  and bug #13's "sole currency all loaded fares agree on" derivation are all **subsumed**. The
  card renders the server's `currency` (null → bare); the client no longer derives a currency and
  can no longer encounter mixed currencies.
- Do not keep a "for reference" copy — git history is the archive.

### 4. The UI surface

- **Mount: the existing earnings card in `RidesHistoryScreen` (`/rides-history`), not a new
  drawer destination and not the settings/profile shell.**
  - The drawer already labels this section **"Ride history & earnings"**
    (`driver_app/lib/features/navigation/driver_nav_items.dart:42-44`) and the earnings card is
    its money surface — the balance and the withdraw CTA belong together, next to the fares that
    produced them.
  - A dedicated `/payouts` screen is **not justified**: the api plan exposes no withdrawal-history
    endpoint (only the current summary and the one withdrawal in the withdraw response), so a
    separate screen would show a balance plus one button — no more than the card. It would also
    add a 6th top-level section and require a new shared `AppNavDestination`, which the driver
    domain does not own (shared is import-only here). If the API later adds withdrawal history,
    a `/payouts` screen becomes additive; it is out of scope now.
  - Settings/profile are app-config/identity surfaces with no money concept today; putting the
    balance there would split it from the fares.
- **Card (replaces the derived card, keeps `Key('earnings-month-total')`):**
  `Available to withdraw` (`available_cents`, the headline), `Fares this month`
  (`month_total_cents` / `month_trips`), the monthly breakdown (`months[]`, newest first), and
  the ledger legs `Pending` (`pending_cents`) / `Withdrawn` (`withdrawn_cents`) / `Lifetime`
  (`lifetime_cents`). All through `formatCents(..., currency: summary.currency)`.
- **Withdraw affordance:** a `Withdraw` button on the card (new key, e.g.
  `Key('withdraw-button')`), disabled with an explanatory caption when
  `available_cents == 0`. It opens `WithdrawSheet`.
- **Loading/error:** the card is an `AsyncValue`; loading shows a spinner (never a fabricated
  `0.00`), failure shows the shared `AppErrorRow` with retry, exactly as the history error rows
  do (`rides_history_screen.dart:82-108`).
- **Pending-status copy (must be plain):** after a successful withdraw the sheet says the
  withdrawal was **requested and is pending**, and that **no money has moved yet** — payouts are
  processed separately. Never "paid", never "sent to your bank".

### 5. 409 vs 422 in UI terms

Both arrive already typed by the landed `ApiClient` error interceptor, which maps
`{"error":{"code","message"}}` into `ConflictException` (409) / `ValidationException` (422)
carried in `DioException.error` (`shared/lib/src/api/api_client.dart:75-91`,
`shared/lib/src/api/api_exceptions.dart:66-74`). Read the message with the landed
`apiErrorMessage(e, fallback)` (`shared/lib/src/api/api_exceptions.dart:31`) — **never**
`DioException.message`.

- **422 `VALIDATION_ERROR`** — below the minimum, zero, or invalid amount. Render the server's
  `message` **inline under the amount field** and keep the entered amount so the driver can
  correct it.
- **409 `CONFLICT`** — "insufficient balance". This means the available balance moved under the
  driver; show the server's `message`, call `earningsProvider.refresh()` to re-read the balance,
  re-enable the form, and keep it distinct from a validation error.
- **Transport failure / 5xx** — generic retryable error with a Retry that reuses the **same**
  idempotency key (§6). Copy must not imply a fresh withdrawal.

### 6. Idempotency-key handling

Mirror the landed create-ride attempt-key seam
(`rider_app/lib/features/home/data/home_provider.dart:277-318,389-396`):

- Generate one key per withdrawal attempt (`<millisSinceEpoch>-<random>`; no uuid dependency)
  and reuse it for every retry of that attempt.
- Send it as `Options(headers: {'Idempotency-Key': key})` on the withdraw POST via the existing
  Dio/ApiClient — **no second HTTP client**.
- Keep the key on a **transport failure / timeout / 5xx** (ambiguous: the server may have
  written) so a retry replays instead of double-debiting.
- Clear the key and generate a new one after a **terminal 4xx (409/422)** — the server
  definitively rejected before writing — and after any **2xx**, so the next withdrawal is a new
  request.
- Tests pin this lifecycle (§7).

## Tests

New suites (mocktail + `http_mock_adapter`, mirroring `driver_app/test/core/...` and
`driver_app/test/features/safety/...`):

- `driver_app/test/features/payout/model/driver_earnings_test.dart` — `fromJson` parses cents
  ints, parses `"2026-09"`→`September 2026`, blank/absent `currency`→`null`, tolerates unknown
  keys, and `formatCents` converts cents→major exactly once.
- `driver_app/test/features/payout/data/payout_repository_test.dart` — the real repository
  through a Dio mock adapter pins `GET /api/v1/driver/me/earnings`; pins `POST
  /api/v1/driver/earnings/withdraw` with body `{"amount_cents":N}` **and** the `Idempotency-Key`
  header; parses the updated `earnings` summary; and surfaces the 409/422 typed exceptions.
- `driver_app/test/features/payout/providers/payout_providers_test.dart` — `earningsProvider`
  fetches the endpoint (asserting it does **not** read `historyProvider`), refresh replaces,
  error state resolves; key lifecycle: new key per attempt, reused on transport failure + retry,
  regenerated after 409/422 and after success.
- `driver_app/test/features/payout/presentation/withdraw_sheet_test.dart` — non-positive amount
  rejected, above-available rejected, below-min mirror rejected, valid submit posts cents + key;
  **409 path** shows insufficient-balance, refreshes earnings, keeps the form; **422 path** shows
  the server `message` inline; success shows the pending copy and the updated balance; a
  double-tap sends exactly one POST.
- **Idempotent-replay behaviour** — a retry after a transport failure sends the same
  `Idempotency-Key`; the provider test asserts the key is byte-identical across the two calls and
  changes only after terminal 4xx/2xx.

Updated/retired assertions:

- `driver_app/test/features/rides/providers/history_provider_test.dart` — **retire** the
  `group('EarningsSummary')` (`:350-554`), including the `EarningsSummary.from` cases and
  `earningsProvider sums whatever history is loaded` (`:536-553`). The history-notifier tests
  above (`:1-348`) stay. No replacement belongs here; the new model/provider tests live under
  `features/payout/`.
- `driver_app/test/features/rides/presentation/rides_history_screen_test.dart` — the earnings
  assertions (`:242-247`, `:311-318`, `:338-345`, `:369-375`) currently rely on the placeholder
  deriving earnings from the stubbed ride list. Re-point them at a mocked endpoint-backed
  `earningsProvider` (override the provider in the harness) and:
  - **flip** the "no withdraw affordance" assertion (`:315-318`) to assert the `Withdraw`
    affordance is present (that assertion currently pins the bug being fixed);
  - replace the mixed-currency-from-rides cases (`:347-377`) with the endpoint's own `currency`
    handling (a non-null code renders prefixed; a null code renders bare) — the client can no
    longer derive mixed currencies;
  - keep `Key('earnings-month-total')` semantics so the card test stays meaningful.
- The `history-refresh` / pull-to-refresh tests keep working; refresh now also refreshes
  `earningsProvider` (extend `refreshAll`, `rides_history_screen.dart:60-63`, consistently with
  today's `historyProvider` + `ratedRidesProvider` fan-out).

## Invariants

- Never build UI on a backend STUB — this plan stays blocked until the api plan lands
  (`driver_app_plans/STATUS.md` → Skip list; Invariants).
- Money is integer cents on the wire for these endpoints; every money value still renders
  through the shared `formatMoney` convention (cents converted once at the boundary). Never
  hardcode `$` and never round to whole dollars.
- The five top-level sections stay body-only under `DriverShell`; this plan adds no
  `Scaffold`/`AppBar` and no drawer destination.
- New shared symbols would be imported from the barrel; this plan needs **no** shared change
  (all models/repo/providers are driver-app-local), so `shared/` and `rider_app/` stay untouched.
- `api_plans/`, `rider_app_plans/`, and `shared/` are not edited by this plan or its landing.

## Out of scope

- Withdrawal history / a dedicated `/payouts` screen (no API endpoint).
- Real payout/bank integration, `paid`/`failed` transitions, tax/receipts (api plan → Out of
  scope).
- Any change to `GET /driver/me/earnings` or `POST /driver/earnings/withdraw` shapes — adopt the
  api plan verbatim.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK (the /mnt/i/flutter SDK has CRLF endings)
melos run analyze
melos run test
```

`make flutter-analyze` / `make flutter-test` shell out to the Windows `melos.bat` and are broken
from this WSL tree (AGENTS.md fact 1); this plan's counts must be re-derived from the tree, not
trusted from a STATUS total. A real bank/payout provider is UNVERIFIABLE here by design (there
is none).

## Housekeeping (done at authoring time)

- `driver_app_plans/STATUS.md` → Open plans gains this row (tag `payout`, depends on the open
  `api_plans/[payout]_driver_earnings_and_withdraw.md` as the blocking stage, with the `01_`
  rationale).
- Bug #5 ("No withdraw UI") **stays in Known bugs** but is marked owned by this plan; it is
  closed only when this UI lands on a real (non-stub) endpoint.
