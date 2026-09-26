# Stage 02 — Repository errors to an HTTP contract

**Goal:** every failure answers in exactly one of two shapes — a **user-actionable** one (4xx with
a specific, stable sentence) or an **ours** one (5xx with a fixed sentence and the cause in the
log). No third shape, where the body carries Go and Postgres internals.

This is the stage where the register screen stops being able to show
`pq: duplicate key value violates unique constraint "users_email_key"`, and where a database
outage stops masquerading as "invalid credentials".

Depends on stage 01 (the taxonomy). Do not start without it — this stage is a lookup table over
`repository.ErrNotFound` / `ErrConflict`, and with stage 01 absent there is nothing to look up.

## The rule the repo already wrote down

`internal/middleware/error_logger.go:9-16`:

> Handlers keep returning a stable public message to the client; this prints the raw error with
> its request context.

Registered globally at `router.go:61`. `platform.go` is the only file that follows it (17
`c.Error` sites, each carrying request context — `[places] autocomplete query failed: %w`,
`[navigation] route failed from=(%.5f,%.5f) …`). The other five files call `c.Error` **zero**
times across 47 error sites. This stage makes them obey, and does it through one helper so it
cannot drift again.

## Step 1 — `internal/handler/respond.go` (new file)

```go
package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/repository"
)

// fail writes the standard error envelope and attaches cause to the request so
// middleware.ErrorLogger prints it with the request id.
//
// `message` is PUBLIC: it is rendered verbatim on a Flutter form. Never pass
// err.Error() here for anything derived from a database, a driver, or an
// internal invariant. `cause` is the opposite: always pass the real error, and
// never nil when one exists — the log is the only place the detail belongs.
func fail(c *gin.Context, status int, code, message string, cause error) {
	if cause != nil {
		_ = c.Error(cause)
	}
	c.AbortWithStatusJSON(status, ErrorResponse{
		Error: ErrorDetail{Code: code, Message: message},
	})
}

// respondRepo classifies a repository/service error and writes the response.
//
// notFound and conflict are the two public sentences for the client-actionable
// cases. Everything else — a dropped connection, a SQLSTATE nobody modelled, a
// bug — is a 500 with one fixed sentence, and its cause goes to the log.
//
// The asymmetry is the point. Guessing wrong in the *user-actionable* direction
// (500 for a typo) is recoverable: they retry. Guessing wrong in the other
// direction (4xx for an outage) is not: the Flutter apps only fall back to a
// straight line on a 500, and a 4xx tells them the user did something wrong.
func respondRepo(c *gin.Context, err error, notFound, conflict string) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		fail(c, http.StatusNotFound, "NOT_FOUND", notFound, err)
	case errors.Is(err, repository.ErrConflict):
		fail(c, http.StatusConflict, "CONFLICT", conflict, err)
	default:
		fail(c, http.StatusInternalServerError, "INTERNAL", "internal error", err)
	}
}
```

**Use the existing types.** `ErrorResponse` / `ErrorDetail` at `responses.go:6-14` are currently
dead. This is their first caller. That is deliberate: the envelope shape
(`{"error":{"code":…,"message":…}}`) is already what all 62 sites emit by hand, what
`shared/lib/src/api/api_client.dart:92` parses, and what the swagger `@Failure` annotations
document. Only the construction becomes shared — **the wire format does not change.**

**`AbortWithStatusJSON`, not `JSON`.** The existing sites use `c.JSON(...)` followed by `return`,
which is correct but easy to get wrong when a handler grows a second exit. `Abort` also stops any
later middleware from writing. This is a behaviour change for handlers that accidentally relied
on continuing; there are none today (all 62 sites return immediately), so it is a no-op in
practice.

**Codes are reused, never invented.** `NOT_FOUND`, `CONFLICT`, `INTERNAL` are already in the
live vocabulary. `respondRepo` introduces no new code — it applies the existing six more
consistently.

## Step 2 — instrument the five uninstrumented handler files

The mechanical rule, per site:

- **Service/repository failure** → `respondRepo(c, err, "<public not-found>", "<public conflict>")`.
- **Client input failure** (bad JSON, bad field, bad query param) → `fail(c, 422 or 400,
  "VALIDATION_ERROR" or "BAD_REQUEST", "<public sentence>", err)`. The `err` goes to the log
  only; the 22 `ShouldBindJSON` sites are stage 03, so for this stage pass a stable sentence and
  keep the cause attached. The ~10 hand-written query-parameter validations already have clean
  sentences (`"invalid lat"`, `"lat/lng out of range"`); leave their text alone, just attach the
  cause.
- **Anything that used `err.Error()` in a body** → delete the leak. Three sites today:
  `ride.go:83`, `ride.go:176`, `platform.go:412`.
- **Anything that returned a generic string with no cause** → keep the string, **add the cause**.
  `geo.go:56` ("failed to update location"), `geo.go:170` ("failed to query drivers"),
  `geo.go:214`/`263` ("failed to query places"), `platform.go:322` ("failed to compute
  estimate"), `platform.go:366` ("failed to calculate route"), `auth.go:190` ("logout failed"),
  `auth.go:221` ("failed to process request"). This is the "deletes the only trace" failure mode
  in series invariant 5 — each of these needs a `_ = c.Error(err)` in the same edit.

Per-file guidance:

**`auth.go` (17 sites).** The important ones:

- `Register` (`:73`) — currently `409 CONFLICT` + `err.Error()` for *everything*. Becomes
  `respondRepo(c, err, "account not found", "<duplicate sentence>")`. A database failure during
  registration becomes a **500**, not a 409. The `@Failure 409 … "Account already exists"`
  annotation at `:59` becomes true instead of aspirational.
  > **Decide the duplicate sentence deliberately.** The friendly text
  > `user with email … already exists` exists only in `tests/testutil/mock_repos.go:46`. The real
  > repository will say only `ErrConflict`. Options: `"that email is already registered"` (no
  > echo), or `"email already registered"`. Echoing the address is not a leak — it is the user's
  > own input — but it makes the sentence long and the address is already in the field above the
  > message. Prefer not echoing.
- `Login` (`:116`) — currently `401 UNAUTHORIZED` for *everything*, which is how a database
  outage became a 401. `AuthService.Login` returns a bare `errors.New("invalid credentials")`
  (`service/auth.go:68` and `:76`) and deliberately erases the distinction, so **the handler
  cannot fix this alone.** Either:
  1. change `service/auth.go:68` to pass the repository error through (widest blast radius: the
     service's own tests assert on `"invalid credentials"`), or
  2. have `Login` return a sentinel — `var ErrInvalidCredentials = errors.New("invalid
     credentials")` in the service — and have the handler map it to 401 while anything else
     falls through to 500.
  
  **Option 2 is the right size for this stage.** It is one new exported sentinel in
  `internal/service/auth.go`, the two `errors.New("invalid credentials")` call sites (`:68`,
  `:76`) changed to wrap it, and the handler does
  `if errors.Is(err, service.ErrInvalidCredentials) { 401 } else { respondRepo(...) }`. The public
  sentence stays byte-identical. Verified: **no test asserts on the `"invalid credentials"`
  string** — 6 tests assert a 401 *status* on auth paths, and none inspects the body text — so
  this change moves no existing assertion.
- `RefreshAccessToken` (`:148`/`:156`) — same treatment: `"invalid or expired refresh token"`
  stays the 401 sentence; a repository failure becomes a 500.

**`ride.go` (14 sites).** `CreateRide` at `:83` dumps the ride/fare/nav error into the body of a
**rider-facing** request — the most visible remaining leak. `ListRides` at `:176` is the same
shape on a paged read. Both become `respondRepo`. Note the rider app's fallback: it draws a
straight line **only on a 500**, and a genuine nav/native-engine failure *should* be a 500, so
this change must not accidentally turn an outage into a 4xx.

**`geo.go` (10 sites).** `GetNearbyDrivers` (`:170`) and the places handlers return generic
sentences with no cause. `GetDriverLocation` already returns a clean 404 (`:190`). The batch
endpoint's validation errors (`:88-…`) are query-param failures — stage 03 territory, keep the
shape, attach the cause.

**`driver.go` / `rider.go` (3 sites each).** Both have a hand-rolled `404` with a hardcoded
sentence (`:63`, `:45`) that ignores the error entirely. Route through `respondRepo` so the
sentence is consistent and the cause is attached. The `ShouldBindJSON` sites (`:83`/`:109`,
`:69`/`:102`) are stage 03.

**`platform.go` (14 sites).** Already correct. Convert the construction to `fail(...)` for
consistency, **keeping each `c.Error` context string** — `[places] autocomplete query failed` is
exactly the request context that makes a log line useful, and losing it in a refactor would be a
regression. The one leak here is `platform.go:412` (`"message": err.Error()`), which becomes
`fail(c, 500, "INTERNAL", "failed to calculate route", err)`.

## Step 3 — the status-code corrections

The misclassifications this fixes, all of which currently make an outage look like a user error:

| endpoint | today | after | why |
|---|---|---|---|
| `POST /auth/register` | 409 for any failure | 409 only for `ErrConflict`, else 500 | a 409 tells the app the account exists; on an outage the app retries a register and the user sees a nonsense conflict |
| `POST /auth/login` | 401 for any failure | 401 only for `ErrInvalidCredentials`, else 500 | the core of series failure #1 |
| `POST /rides` | 500 + leaked internals | 500 + fixed sentence, cause logged | keeps the rider's straight-line fallback working, stops the leak |
| `GET /driver/rides` | 500 + leaked internals | same | idem |
| `GET /rider/me`, `GET /driver/me` | 404 always | 404 only for `ErrNotFound`, else 500 | a 500 here is a signal; a 404 is a dead end |

**Invariant check — do not "improve" the 500s to 4xx.** Series invariant 2: the rider app falls
back to a straight line only on a 500. A misclassified 4xx on `/navigation/route` or
`/estimates/*` silently removes that fallback. And invariant 3: no-coverage and unreachable
datasource stay **200 + `is_estimate`**, which `service/navigation.go:141` already does with
`errors.Is(rerr, repository.ErrDatasourceUnavailable)`. Leave it alone; it is the best-behaved
error path in the codebase and the model for the rest.

## Tests

New `internal/handler/respond_test.go`, table-driven, with a fake `gin` context:

- `wrapDB`-produced `ErrNotFound` → 404 + `NOT_FOUND` + the not-found sentence, and the cause is
  in `c.Errors`.
- `ErrConflict` → 409 + `CONFLICT` + the conflict sentence.
- an unclassified error (`errors.New("boom")`, and a `*pq.Error` with an unmodelled SQLSTATE) →
  500 + `INTERNAL` + `"internal error"`, cause attached.
- **the regression test for invariant 5**: the 500 body must not contain the cause's text. Assert
  `not(contains(body, "boom"))` and `contains(c.Errors[0].Error(), "boom")`. This is the test that
  makes "log it, don't return it" enforceable rather than aspirational.
- `fail` with `cause == nil` does not append to `c.Errors` (no `nil` entries).
- the envelope is exactly `{"error":{"code":…,"message":…}}` — the clients parse it.

Extend the existing handler tests rather than writing new files per endpoint: for each of the
five files, one test that the error path returns the right status and that the body carries no
internals.

A **table of every `gin.H{"error"` site and its post-change form** is worth keeping in the diff
description. 62 sites is reviewable as a table and not as 62 individual judgements.

## Pitfalls

1. **Do not pass `err.Error()` to `fail`.** That is the bug being fixed; writing the helper and
   then calling it with the cause re-introduces it in a more central place.
2. **Do not drop the `c.Error` context strings in `platform.go`.** They are the reason those log
   lines are useful.
3. **Do not add a new code string.** The clients, the swagger annotations, and
   `_messageFromData` already know six. If a case seems to need a seventh, it probably needs a
   different status code instead.
4. **Changing `Login`'s internals is the riskiest edit in the stage.** The service deliberately
   returns one message for "no such user" and "wrong password" — that is correct security
   practice (user enumeration). The fix is to keep the *public* message identical and only make
   the *internal* distinction, via `ErrInvalidCredentials`. Any change that makes login reveal
   whether an account exists is a regression, not an improvement.
5. **`AbortWithStatusJSON` changes flow.** If a handler currently continues after a
   `c.JSON` error write (none do, but check), the abort will now stop it. That is the intent.
6. **A 500 body change is visible to the Flutter apps**, because `apiErrorMessage` now shows the
   server's message. That is the point, but it means the e2e probe's expectations may move. Run
   it.

## Verification

```bash
make test && go test -count=1 ./...
gofmt -w internal/handler/respond.go internal/handler/*.go internal/service/auth.go
go vet ./...
```

Static gates (must all come back empty after the change):

```bash
# 1. no internals in any response body
grep -rn '"message": err.Error()' internal/handler/          # -> 0
grep -rn 'Message: *err.Error()' internal/handler/            # -> 0

# 2. no uninstrumented error site left
grep -c 'c.Error(' internal/handler/*.go
# auth.go, ride.go, geo.go, driver.go, rider.go must all be > 0

# 3. the dead envelope types are now used
grep -rn 'ErrorResponse{' internal/handler/                   # -> > 0

# 4. no handler still hand-builds the envelope
grep -rn 'gin.H{"error": gin.H' internal/handler/ | wc -l    # -> 0
```

Live, with the DB up:

```bash
# 1. duplicate email: 409, human sentence, no schema in the body
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"stage02@example.com","phone":"+15550000003","password":"SecurePass1"}'
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"stage02@example.com","phone":"+15550000003","password":"SecurePass1"}'
#   -> {"error":{"code":"CONFLICT","message":"that email is already registered"}}
#   -> the log must contain the pq.Error with Code 23505

# 2. THE headline assertion: an outage is a 500, not a 401
docker compose stop ride-hailing-db
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"stage02@example.com","password":"SecurePass1"}'
#   -> 500, and the log has the connection error
docker compose start ride-hailing-db

# 3. wrong password is still a plain 401 (no user enumeration)
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.com","password":"wrong"}'
#   -> 401
```

And the browser, because the client now renders these sentences:

```bash
cd e2e && npm run build:apps && node scripts/probe-register-error.mjs   # friendly, no "pq:"
cd e2e && npx playwright test                                      # 2 passed
```

The probe output changes here for the first time in a good way: it should stop printing
`failed to create user: …` (a service-layer prefix that exists only because the mock's error was
being forwarded verbatim) and print the new deliberate sentence instead.

## Rollout note

No migration, no flag, no wire-format change. But this stage **does** change status codes on
failure paths, and the Flutter apps branch on status. Before landing, check the two consumers
that care:

- `shared/lib/src/api/api_exceptions.dart` `mapStatusCodeToException` — a new 500 on a path that
  used to 401/409 changes which exception the apps throw. That is handled, but read it.
- The rider app's straight-line fallback (500-only, series invariant 2). Any 4xx introduced here
  on a routing/estimate path removes it. There should be none; verify rather than assume.
