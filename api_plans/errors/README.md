# api_plans/errors — error contract (repository taxonomy → HTTP → client)

Make every API failure land in exactly one of three places, and never zero:

| where | what it is | who reads it |
|---|---|---|
| HTTP body | a **stable, user-facing** sentence + a machine code | the Flutter apps, rendered on-screen |
| server log | the real cause, with the request id | whoever is debugging |
| nowhere | the internals — table names, SQLSTATEs, driver text, Go field names | nobody |

This is a **sub-series** of `api_plans/`, split into 3 small stages. It is orthogonal to the
region series (plans 01–07) and to `elevation/`: it changes **what the API says when it
fails**, not routing, not the data model, not the endpoint contract.

## The problem, measured

The API has no error contract. It has 62 habits. Counted, not estimated:

- **62** ad-hoc `gin.H{"error": gin.H{...}}` response sites across 6 handler files. The
  `ErrorResponse` / `ErrorDetail` envelope types exist at `internal/handler/responses.go:6-14`
  and are **never used** — dead types, aspirational names.
- **47** of those sites are in `auth.go` (17), `ride.go` (14), `geo.go` (10), `driver.go` (3),
  `rider.go` (3) and call `c.Error(...)` **zero** times.
- `internal/middleware/error_logger.go:17` is registered globally (`router.go:61`) and logs
  *only* `c.Errors`. Its own doc comment states the intended rule: *"Handlers keep returning a
  stable public message to the client; this prints the raw error with its request context."*
  **`platform.go` is the only file that obeys** (17 `c.Error` sites, each with rich context).
  For the other five files the cause is therefore **nowhere** — not in the body (a generic
  string) and not in the log. `internal/handler` contains **0** `log.` calls.
- The 3 sites that *do* leak internals on a 500 are `ride.go:83`, `ride.go:176` and
  `platform.go:412`, all `"message": err.Error()`.
- `errors.Is` appears in exactly **2** non-test places in the whole codebase, and only **one** of
  them classifies an error: `service/navigation.go:141` (routing). The other is a filesystem
  existence check in `internal/database/seed_places.go:54`. `sql.ErrNoRows` is checked **once**
  anywhere (`places_repo.go:62`) and with `==`, not `errors.Is`.
- **Zero** `pq.Error` / SQLSTATE inspection anywhere, so a unique violation is
  indistinguishable from a dropped connection.

### Three concrete failures this produces today

1. **A Postgres outage becomes a 401 on every login.** `UserRepo.FindByEmail` wraps *every*
   error as `user not found: %w` (`repository/user_repo.go:56`) — a missing row and a refused
   connection look identical. `AuthService.Login` then maps *any* error from it to
   `errors.New("invalid credentials")` (`service/auth.go:68`). So "the database is down" and
   "you typed the wrong password" are the same 401 with the same sentence. Nobody can tell
   them apart from the outside, and the log is empty.
2. **A duplicate email leaks the schema.** `Register` maps *every* error to
   `409 CONFLICT` with `err.Error()` in the body (`handler/auth.go:73`). Against a real
   Postgres that is `pq: duplicate key value violates unique constraint "users_email_key"`.
   > The friendly text that was seen on the register screen in the e2e probe
   > (`failed to create user: user with email … already exists`) is
   > **`tests/testutil/mock_repos.go:46`, a mock string.** The real API has never said it.
3. **Validator text leaks Go identifiers.** **All 22** `c.ShouldBindJSON` sites answer a
   malformed body with `err.Error()` straight from the binder (9 in `auth.go`, 3 each in
   `geo.go`/`platform.go`/`ride.go`, 2 each in `driver.go`/`rider.go`) — verified, not assumed:
   zero of the 22 use a clean message. go-playground/validator renders
   `Key: 'registerRequest.Email' Error:Field validation for 'Email' failed on the 'email' tag` —
   the Go struct name, the Go field name, and the validation tag, on a public form. (The other
   ~10 `VALIDATION_ERROR` sites validate query parameters by hand and already return clean
   sentences like `"invalid lat"`. Those are fine and are not this series' problem.)

### The precedent already in the repo

The routing layer got this right, and did it the way this series will:

- Sentinels: `routing.ErrNoRoute` (`internal/routing/routing.go:14`),
  `repository.ErrDatasourceUnavailable` (`internal/repository/datasource.go:28`).
- Consumed with `errors.Is`, not string comparison.
- Degraded, not escalated: an unreachable datasource is a data gap *for that city*, so
  `service/navigation.go:141` returns a **200 estimate** instead of a 500.

Everything below is generalising that pattern to the rest of the API. Nothing here is a new idea
for this codebase.

## Why the Flutter apps make this urgent

`shared/lib/src/api/api_client.dart:92` (`_messageFromData`) prefers `error.message` out of the
response body, and `apiErrorMessage` (`shared/lib/src/api/api_exceptions.dart`) prefers that
mapped `ApiException` over Dio's own verbose text. The **server is the only place** the
user-visible sentence can be set: whatever lands in `message` is what renders on the form. That
was just fixed client-side (a raw `DioException.message` was being displayed verbatim); with the
client now faithfully showing the server's message, a leaky server message is a leaky UI.

## Hard invariants this series must not break

1. **Success paths and status codes for *valid* requests do not change.** Only the `message`
   string, and only the status code where a failure was misclassified as a client error. A
   request that returns 200 today returns 200 after.
2. **The rider app's straight-line fallback is contract, not behaviour.** It triggers **only** on
   a 500. So "the datasource is down → 500" must stay a 500 (or become a 200 estimate, as
   api_plans/06 already does). Never convert a genuine outage into a 4xx: a 4xx tells the app
   the user did something wrong, and the app will not fall back.
3. **`is_estimate` stays.** api_plans/05/06: no coverage or an unreachable datasource is a
   **200** with `is_estimate: true`, never a 422 and never a 500. This series must not turn a
   degraded route into an error response.
4. **The `code` vocabulary is additive only.** The six codes already emitted —
   `VALIDATION_ERROR`, `INTERNAL`, `BAD_REQUEST`, `NOT_FOUND`, `CONFLICT`, `UNAUTHORIZED` — are
   what the clients and the swagger docs already describe. Stage 2 may *apply* them more
   consistently; it must not invent new ones or rename existing ones.
5. **Causes are logged, not returned.** A stage that swaps a leaked `err.Error()` for a generic
   string **must** attach the cause with `c.Error(...)` in the same edit, or it deletes the only
   trace of the failure.
6. **Mocks move in lockstep with the repos.** See the trap below.

## Stages

| File | Work | Depends on |
|---|---|---|
| `01_error_taxonomy_in_repositories.md` | Give `internal/repository` a real error taxonomy: `ErrNotFound` / `ErrConflict` sentinels, a `wrapDB` classifier that reads `*pq.Error.SQLState`, every repo error routed through it, `sql.ErrNoRows` preserved as a co-wrapped cause. Update `tests/testutil` mocks to return the same sentinels. **No user-visible change.** | none |
| `02_repository_errors_to_http.md` | `internal/handler/respond.go`: one `ErrorResponse`-based `respond`/`respondRepo`; map taxonomy → status + code + public sentence; attach causes with `c.Error` in all five uninstrumented handler files; stop the 3 `err.Error()` leaks. Fix `Login` to stop mapping outages to "invalid credentials". | 01 |
| `03_validation_and_client_contract.md` | Replace the 22 `ShouldBindJSON` → `err.Error()` sites with a `bindJSON` that maps validator errors to public field names; align swagger `@Failure` text with reality; document the envelope in `RIDER_API_GUIDE.md`; turn `e2e/scripts/probe-register-error.mjs` into a real regression check. | 02 |

Recommended order: 01 → 02 → 03. Each lands green and can stop there; 03 is the most cosmetic.

> ## ⚠ The trap in stage 1: the mocks will keep passing and stop meaning anything
>
> `tests/testutil/mock_repos.go` returns `fmt.Errorf("user not found")` — **not**
> `sql.ErrNoRows`, and not any sentinel (all 21 sites: 46, 69, 73, 84, 95, 121, 132, 161, 172, 185,
> 207, 210, 243, 246, 313, 332, 350, 415, 444, 447, 637). If stage 1 introduces sentinels in
> `internal/repository` and forgets the mocks, **every test still passes** while testing a
> repository that cannot occur in production. That is the same trap that hid the dropped-offer
> bug: `FabricateNearbyDriver` made dispatch succeed for a driver who did not exist, so the Go
> suite was green for the entire time the app silently discarded real offers.
>
> Two of the 21 are worse than unsentineled: `:210` and `:246` have the mock's *repository*
> reject an expired token, which production never does — `service/auth.go:98` checks
> `ExpiresAt` in the service. So the service's own expiry branch is exercised by nothing.
>
> The mocks must return `repository.ErrNotFound` / `ErrConflict` in stage 1, in the same commit,
> and `:210`/`:246` must go away entirely. A test that asserts "a missing user produces 404"
> must be asserting that against the same sentinel production uses — otherwise stage 2's mapping
> is verified only by hand.

## What this series deliberately does not do

- **No structured error codes beyond the existing six.** A per-field validation payload is
  stage 3's `bindJSON` and stops at `{field, message}`; it does not grow an `errors` array.
- **No i18n.** The public sentences are English literals, same as today. Swapping them for
  message keys is a separate decision that needs a translation story first.
- **No change to `code`-to-status mapping that already works** (`platform.go`). Stage 2 is about
  the five files that never opted in.
- **No retry/backoff/circuit-breaker work.** An outage must be *reportable*, not *survivable*;
  that is api_plans/06 territory and it already landed for routing.

## Verification (every stage)

```bash
make test                       # unit tests, no DB (must stay green)
go test -count=1 ./...          # ditto, explicit
gofmt -w <files> && go vet ./...
```

New, and required by every stage:

```bash
# No handler may answer a 5xx with a cause, and none may be uninstrumented.
# (stage 2 gate — see that file for the exact command)
go test ./internal/handler/...
```

Live check with the DB up (this is the one that cannot be faked by mocks — a real duplicate
email hits a real unique index):

```bash
curl -s -X POST localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"dup@example.com","phone":"+15550000001","password":"SecurePass1"}'   # 201
curl -s -X POST localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"dup@example.com","phone":"+15550000001","password":"SecurePass1"}'   # 409, and
#   message must NOT contain "pq:", "duplicate key", or "users_email_key"
```

Stage 3 additionally runs the browser probe, which asserts the same thing through the real
register form in Edge:

```bash
cd e2e && npm run build:apps && node scripts/probe-register-error.mjs
```

## Authoritative sources

- Envelope + code vocabulary: `internal/handler/responses.go:6-14` (types), and the live
  distribution of codes across `internal/handler/*.go`.
- Logging contract: `internal/middleware/error_logger.go:9-16` (the rule to obey),
  `internal/handler/platform.go` (the file that obeys it), `router.go:61` (registration).
- In-repo precedent: `internal/routing/routing.go:14`, `internal/repository/datasource.go:28`,
  `internal/service/navigation.go:141`.
- Client consumption: `shared/lib/src/api/api_client.dart:92`,
  `shared/lib/src/api/api_exceptions.dart` (`apiErrorMessage`).
- Mock divergence: `tests/testutil/mock_repos.go` (21 hand-rolled error strings, no sentinels).
