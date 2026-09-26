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
// All three sentences are chosen by the call site, because all three are
// PUBLIC and rendered verbatim on a Flutter form. Pass the operation's own
// words for internal ("failed to load nearby drivers"), not "internal error":
// a name the user and support can act on, and it leaks nothing — the
// operation is not a secret, the driver error underneath it is.
//
// The status split is the part that matters. Guessing wrong towards 5xx (a
// 500 for a typo) is recoverable: they retry. Guessing wrong towards 4xx is
// not: the rider app draws a straight line on EVERY error status
// (home_screen.dart:127), so a 4xx-for-an-outage silently renders a
// confident road-less route instead of showing anything is wrong.
func respondRepo(c *gin.Context, err error, notFound, conflict, internal string) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		fail(c, http.StatusNotFound, "NOT_FOUND", notFound, err)
	case errors.Is(err, repository.ErrConflict):
		fail(c, http.StatusConflict, "CONFLICT", conflict, err)
	default:
		fail(c, http.StatusInternalServerError, "INTERNAL", internal, err)
	}
}
```

> **Decision recorded: 5xx bodies stay operation-specific.** The three options were (a)
> operation-specific, (b) `"internal error"` plus a `request_id` for support to grep, (c) flat
> `"internal error"`. (a) won because it is strictly more informative at zero leakage cost — the
> existing 8 `INTERNAL` sites already use this vocabulary (`"failed to update location"`,
> `"failed to query drivers"`, `"failed to compute estimate"`), so choosing it *shrinks* this
> stage's diff instead of growing it.
>
> (b) remains available and is cheap if it is ever wanted: `ErrorLogger` calls
> `ensureRequestID(c)` before `c.Next()` (`middleware/error_logger.go:21`), so
> `c.GetString("request_id")` works in any handler. Note the `X-Request-ID` *header* is not
> usable from a browser — `router.go:57` exposes only `Content-Length` via CORS — so an id shown
> to a user would have to go in the body.
>
> Consequence for review: the 3 real leaks (`ride.go:83`, `ride.go:176`, `platform.go:412`) get
> the *operation* sentence, and the 8 already-correct sites keep theirs. Nothing in the codebase
> ends up saying `"internal error"`, so the uniform-looking generic string never appears and
> cannot become a habit.

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

- **Service/repository failure** → `respondRepo(c, err, "<public not-found>", "<public
  conflict>", "<public internal>")`. All three are yours to write; see the decision note above
  on keeping 5xx bodies operation-specific.
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
  `respondRepo(c, err, "account not found", "Account already exists", "failed to create
  account")`. A database failure during registration becomes a **500**, not a 409. The
  `@Failure 409 … "Account already exists"` annotation at `:59` becomes true instead of
  aspirational.
  > **Duplicate sentence: decided — `"Account already exists"`.** It is the wording the swagger
  > annotation at `auth.go:59` already promises, so docs and code agree with no new copy to
  > review. The friendly text `user with email … already exists` exists only in
  > `tests/testutil/mock_repos.go:46` and is a *mock* string, not a contract — do not adopt it.
  > Not echoing the address keeps the sentence short; the address is in the field directly above
  > the message anyway.
- `Login` (`:116`) — currently `401 UNAUTHORIZED` for *everything*, which is how a database
  outage became a 401. `AuthService.Login` returns a bare `errors.New("invalid credentials")`
  (`service/auth.go:68` and `:76`) and deliberately erases the distinction, so **the handler
  cannot fix this alone.** Either:
  1. change `service/auth.go:68` to pass the repository error through (widest blast radius: the
     service would no longer own a single stable message, and its behaviour becomes a function of
     the repository's internals), or
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
shape on a paged read. Both become `respondRepo`. A genuine nav/native-engine failure *should* be
a 5xx, and per series invariant 2 it must stay one: the rider app draws a straight line on
**every** error status, so turning a real routing failure into a 4xx would not surface an error —
it would silently render a road-less line (`home_screen.dart:127`).

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
| `POST /auth/register` | 409 for any failure | 409 (`"Account already exists"`) only for `ErrConflict`, else 500 | a 409 tells the app the account exists; on an outage the user sees a nonsense conflict, or is retried into one |
| `POST /auth/login` | 401 for any failure | 401 only for `ErrInvalidCredentials`, else 500 | the core of series failure #1: today the user is told they mistyped their password when the database is simply down, and `auth.go` logs nothing |
| `POST /rides` | 500 + leaked internals | 500 + operation sentence, cause logged | stops the leak without turning a routing failure into a client error |
| `GET /driver/rides` | 500 + leaked internals | same | idem |
| `GET /rider/me`, `GET /driver/me` | 404 always | 404 only for `ErrNotFound`, else 500 | a 500 here is a signal; a 404 is a dead end |

**Invariant check — do not "improve" a 5xx into a 4xx.** Series invariant 2: the rider app draws
a straight line on **every** error status (`home_screen.dart:127` is `error: (_, _)`), so a
misclassified 4xx on `/navigation/route` or `/estimates/*` does not remove a fallback — it
produces a *confidently wrong* one, with no error shown at all. The correct answer for an outage
is 5xx, or the 200 + `is_estimate` that invariant 3 and `service/navigation.go:141` already
produce via `errors.Is(rerr, repository.ErrDatasourceUnavailable)`. Leave that path alone; it is
the best-behaved error handling in the codebase and the model for the rest of this stage.

## Tests

New `internal/handler/respond_test.go`, table-driven, with a fake `gin` context:

- `wrapDB`-produced `ErrNotFound` → 404 + `NOT_FOUND` + the not-found sentence, and the cause is
  in `c.Errors`.
- `ErrConflict` → 409 + `CONFLICT` + the conflict sentence.
- an unclassified error (`errors.New("boom")`, and a `*pq.Error` with an unmodelled SQLSTATE) →
  500 + `INTERNAL` + **the caller's own `internal` sentence**, cause attached. Also assert the
  body carries that sentence and not a substitute, so the "operation-specific" decision cannot
  quietly decay into a shared `"internal error"` later.
- **the regression test for invariant 5**: the 500 body must not contain the cause's text. Assert
  `not(contains(body, "boom"))` and `contains(c.Errors[0].Error(), "boom")`, for each of the three
  branches. This is the test that makes "log it, don't return it" enforceable rather than
  aspirational.
- a 409 from `Register`'s conflict branch carries exactly `"Account already exists"` — the string
  `auth.go:59` documents. This pins the copy decision so a later refactor cannot quietly
  reintroduce the mock's `user with email … already exists`.
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

# 5. 5xx bodies stayed operation-specific: no site fell back to a shared string
grep -rn '"INTERNAL", *"internal error"' internal/handler/   # -> 0
```

Live, with the DB up:

```bash
# 1. duplicate email: 409, human sentence, no schema in the body
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"stage02@example.com","phone":"+15550000003","password":"SecurePass1"}'
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"stage02@example.com","phone":"+15550000003","password":"SecurePass1"}'
#   -> {"error":{"code":"CONFLICT","message":"Account already exists"}}
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
cd e2e && npm run build:apps && node scripts/probe-register-error.mjs   # "Account already exists", no "pq:"
cd e2e && npx playwright test                                      # 2 passed
```

The probe output changes here for the first time in a good way: it should stop printing
`failed to create user: …` (a service-layer prefix that exists only because the mock's error was
being forwarded verbatim) and print `Account already exists` instead — the same string
`auth.go:59` has been documenting all along.

## Rollout note

No migration, no flag, no wire-format change. But this stage **does** change status codes on
failure paths, and the Flutter apps branch on status. Before landing, check the two consumers
that care:

- `shared/lib/src/api/api_exceptions.dart` `mapStatusCodeToException` — a new 500 on a path that
  used to 401/409 changes which exception the apps throw. That is handled, but read it. Note the
  interceptor exempts `/auth/login` and `/auth/refresh` from refresh-and-retry
  (`api_client.dart:50-69`), so the login 401→500 change does **not** trigger a pointless token
  refresh; the other 401s in the API come from `AuthRequired`, which fails before the service and
  so is not outage-driven. Check rather than assume — this is the one place a status change could
  have a compounding effect.
- The rider app's straight-line fallback. It is **not** 500-only (`home_screen.dart:127` is
  `error: (_, _)`), so any 4xx introduced here on a routing/estimate path does not remove it — it
  produces a silently-wrong line. There should be no such 4xx; verify rather than assume.
