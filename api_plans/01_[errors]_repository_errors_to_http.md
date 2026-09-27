---
tag: errors
depends_on: ["[errors]_error_taxonomy_in_repositories.md"]
status: open
---

# Stage 01 — Repository errors to an HTTP contract

> **Numbering note.** This chain was renumbered so that its head is unnumbered — a `NN_`
> prefix is earned only by a `depends_on` that names an *open* plan
> (`.opencode/skills/plan-management/SKILL.md`). **Filenames and `depends_on` are
> authoritative.** Body prose below may still say "stage N" in the
> pre-renumbering scheme, where old stage 01 = the unnumbered head `[errors]_error_taxonomy_in_repositories.md`, old 02 = `01_[errors]_repository_errors_to_http.md`, old 03 = `02_[errors]_validation_and_client_contract.md`.
> Translating that prose is a tracked follow-up; do not renumber it piecemeal.


**Goal:** every failure answers in exactly one of two shapes — a **user-actionable** one (4xx with
a specific, stable sentence) or an **ours** one (5xx with a fixed sentence and the cause in the
log). No third shape, where the body carries Go and Postgres internals.

This is the stage where the register screen stops being able to show
`pq: duplicate key value violates unique constraint "users_email_key"`, and where a database
outage stops masquerading as "invalid credentials".

Depends on stage 01 (the taxonomy). Do not start without it — this stage is a lookup table over
`repository.ErrNotFound` / `ErrConflict`, and with stage 01 absent there is nothing to look up.

## Read this first — part of this stage's goal landed by accident

A golangci-lint cleanup (uncommitted at time of writing) already did the *narrow* half of this
stage, without the helper and without stage 01. Ten write-failure sites that used to answer
`201`/`200`/`204` as if the write had succeeded now answer `500`:

| site | operation |
| --- | --- |
| `internal/handler/driver.go:41` | `Register` — `UpdateUser` |
| `internal/handler/driver.go:51` | `Register` — `CreateDriver` |
| `internal/handler/driver.go:101` | `UpdateProfile` — `UpdateDriver` |
| `internal/handler/driver.go:129` | `UpdateStatus` — `UpdateDriver` |
| `internal/handler/rider.go:80` | `UpdateProfile` — `UpdateRider` |
| `internal/handler/rider.go:88` | `UpdateProfile` — `UpdateUser` (phone) |
| `internal/handler/rider.go:118` | `UpdateStatus` — `UpdateRider` |
| `internal/handler/rider.go:136` | `DeleteAccount` — `SoftDeleteUser` |
| `internal/handler/geo.go:104` | `UpdateDriverLocationBatch` — the per-item `UpsertDriverPosition` loop |
| `internal/handler/geo.go:132` | `UpdateRiderLocation` — `UpsertRiderPosition` |

Consequences for this stage:

1. **Do not redo them, and do not undo them.** They already use the exact shape this stage
   decides on — the hand-rolled `gin.H{"error": gin.H{"code": "INTERNAL", …}}` envelope and an
   operation-specific sentence (`"failed to update driver profile"`). Convert the construction to
   `fail(...)` and add the cause; that is the whole remaining job for these ten.
2. **`geo.go:104` is a loop.** One bad item aborts the batch and returns 500 for the whole request;
   items already written stay written. That is the right call (a silent partial 204 was the bug)
   but say so in the `@Failure` annotation rather than leaving it implicit.
3. **The reads in front of those writes are still unchecked** — `driver.go:38,96,126` and
   `rider.go:75,85,115` do `user, _ := FindByID(…)` and then mutate the result. A missing row
   nil-derefs into gin's `Recovery` and becomes an unexplained 500 instead of the 404 the endpoint
   owes. Handle them in this stage (they are `ErrNotFound`, i.e. stage 01's taxonomy) — do not
   leave them for a later pass.
4. **The no-cause `INTERNAL` list in Step 2 grew from 8 to 18.** The ten new sites are the second
   half of that list and the hardest to forget, because each is a one-line `if err != nil` that
   looks complete.
5. **The counts in this document predate that edit**: the five uninstrumented files went from 47
   to 57 error sites, `geo.go` from 10 to 12, `driver.go`/`rider.go` from 3 sites each to 7 each,
   and the whole handler package from 62 envelope sites to 71. Line numbers cited below are
   likewise pre-edit; re-derive them from the code rather than trusting them.

The same cleanup also changed two things this stage must respect rather than "fix":

- `internal/service/auth.go` now **fails closed** on revocation (`:111`, `:222`, `:257`). That is
  correct and stays. It has one bad consequence, recorded as a live regression below: `Refresh`
  and `ResetPassword` answer `401`/`400` with `err.Error()` in the body, so a database outage
  during revoke now masquerades as a bad token *and* leaks the wrapped driver text.
- Audit and idempotency rows are **best-effort** (`internal/service/ride.go:63,112,156`,
  `internal/service/dispatch.go:166`, `internal/middleware/idempotency.go:60`). They are logged,
  never returned. Step 2's mechanical rule must skip them — see the exclusion note there.

## The rule the repo already wrote down

`internal/middleware/error_logger.go:9-16`:

> Handlers keep returning a stable public message to the client; this prints the raw error with
> its request context.

Registered globally at `router.go:61`. `platform.go` is the only file that follows it (17
`c.Error` sites, each carrying request context — `[places] autocomplete query failed: %w`,
`[navigation] route failed from=(%.5f,%.5f) …`). The other five files call `c.Error` **zero**
times across 57 error sites. This stage makes them obey, and does it through one helper so it
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
> stage's diff instead of growing it. The ten write-failure sites that landed since (see "Read
> this first") chose the same vocabulary independently (`"failed to update driver profile"`,
> `"failed to deactivate account"`, …), so the decision now has 18 sites behind it and the stage
> has even less to decide.
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
(`{"error":{"code":…,"message":…}}`) is already what all 71 sites emit by hand, what
`shared/lib/src/api/api_client.dart:92` parses, and what the swagger `@Failure` annotations
document. Only the construction becomes shared — **the wire format does not change.**

**`AbortWithStatusJSON`, not `JSON`.** The existing sites use `c.JSON(...)` followed by `return`,
which is correct but easy to get wrong when a handler grows a second exit. `Abort` also stops any
later middleware from writing. This is a behaviour change for handlers that accidentally relied
on continuing; there are none today (all 71 sites return immediately), so it is a no-op in
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
  `ride.go:83`, `ride.go:176`, `platform.go:412` — plus `auth.go:159` (`Refresh`) and
  `auth.go:261` (`ResetPassword`), which are now *worse* than when this stage was written; see
  the `auth.go` guidance below.
- **Anything that returned a generic string with no cause** → keep the string, **add the cause**.
  `geo.go:56` ("failed to update location"), `geo.go:170` ("failed to query drivers"),
  `geo.go:214`/`263` ("failed to query places"), `platform.go:322` ("failed to compute
  estimate"), `platform.go:366` ("failed to calculate route"), `auth.go:190` ("logout failed"),
  `auth.go:221` ("failed to process request"). This is the "deletes the only trace" failure mode
  in series invariant 5 — each of these needs a `_ = c.Error(err)` in the same edit. The ten
  landed write-failure sites are the same failure mode with a shorter body: same treatment, via
  `fail(c, 500, "INTERNAL", "<the sentence it already has>", err)`.
- **Do NOT touch the best-effort rows.** These are not response sites, they are not in the
  handler package, and converting them would be a behaviour *regression*:
  `internal/service/ride.go:63,112,156` and `internal/service/dispatch.go:166`
  (`CreateEvent` — the authoritative state change has already committed, so failing the request
  would report a failure for work that succeeded), and
  `internal/middleware/idempotency.go:47,60` (an unreadable stored response and a failed INSERT).
  The landed behaviour — log the error, keep the status code the endpoint already returned — is
  the correct shape. The stage's job here is only to make sure nothing logs it twice and to note
  it in `RIDER_API_GUIDE.md` (stage 03) as deliberate rather than accidental.

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
  > **This one is now a live regression, not a hypothetical.** `AuthService.RefreshAccessToken`
  > used to swallow a `RevokeRefreshToken` failure and mint a new pair anyway; it now returns
  > `fmt.Errorf("failed to revoke refresh token: %w", …)` (`service/auth.go:111`). The handler
  > (`auth.go:157-161`) answers **401 with `err.Error()` in the body**, so a database outage
  > during revoke now presents to the client as "unauthorized" *and* leaks the wrapped
  > `*pq.Error`. That is the exact failure mode this stage exists to delete, newly introduced.
  > The same shape exists at `ResetPassword`: the service now aborts before changing the
  > password when `RevokePasswordResetToken` fails (`service/auth.go:257`) — correct — and the
  > handler answers **400 with `err.Error()`** (`auth.go:259-263`).
  >
  > Fix: give the service a second sentinel for "this token is not usable" (or reuse
  > `ErrInvalidCredentials`' shape as `ErrInvalidRefreshToken` / `ErrInvalidResetToken`) and map
  > only that to 401/400; a wrapped `*pq.Error` must fall through to `respondRepo`'s 500 branch
  > with the operation sentence. Both fail-closed service changes stay exactly as they are.

**`ride.go` (14 sites).** `CreateRide` at `:83` dumps the ride/fare/nav error into the body of a
**rider-facing** request — the most visible remaining leak. `ListRides` at `:176` is the same
shape on a paged read. Both become `respondRepo`. A genuine nav/native-engine failure *should* be
a 5xx, and per series invariant 2 it must stay one: the rider app draws a straight line on
**every** error status, so turning a real routing failure into a 4xx would not surface an error —
it would silently render a road-less line (`home_screen.dart:127`).
`CreateRide`'s dispatch goroutine now logs a dispatch failure instead of dropping it
(`ride.go:90`) — that is a `log.Printf`, not a response site, and it stays.

**`geo.go` (12 sites).** `GetNearbyDrivers` (`:170`) and the places handlers return generic
sentences with no cause. `GetDriverLocation` already returns a clean 404 (`:190`). The batch
endpoint's validation errors (`:88-…`) are query-param failures — stage 03 territory, keep the
shape, attach the cause. The two landed 500s (`UpdateDriverLocation` at `:57`, which predates the
stage, and the batch loop at `:104` plus `UpdateRiderLocation` at `:132`) already have the right
sentence; add the cause and the `geo.go` half of this stage is done.

**`driver.go` / `rider.go` (7 sites each).** Both have a hand-rolled `404` with a hardcoded
sentence (`:63`, `:45`) that ignores the error entirely. Route through `respondRepo` so the
sentence is consistent and the cause is attached. The `ShouldBindJSON` sites (`:83`/`:109`,
`:69`/`:102`) are stage 03. The remaining four sites in each file are the landed write-failure
500s: keep the status and the sentence, attach the cause, and — the part this stage should not
skip — **fix the discarded read** immediately in front of each of them (`driver.go:38,96,126`,
`rider.go:75,85,115`), which today turns a missing row into a panic-recovered 500 rather than
the 404 the endpoint documents.

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
| `POST /auth/refresh` | 401 + `err.Error()` for every service error | 401 only for an unusable/expired token, else 500 + operation sentence | **regression**: fail-closed revocation now returns a wrapped `*pq.Error`, which the handler answers as 401 with the driver text in the body |
| `POST /auth/reset-password` | 400 + `err.Error()` for every service error | 400 only for an unusable/expired token, else 500 + operation sentence | **regression**, same shape: the abort-before-password-change path leaks `*pq.Error` as a 400 |
| `PUT /driver/me/profile`, `PUT /driver/me/status`, `POST /driver/register` | 200/201 as if the write succeeded | unchanged — already 500, only the cause is missing | landed; this stage just attaches `c.Error` |
| `PUT /rider/me`, `PUT /rider/me/status`, `DELETE /rider/me`, `PUT /geo/driver/location/batch`, `PUT /geo/rider/location` | 200/204 as if the write succeeded | unchanged — already 500, only the cause is missing | landed; ditto |

**Invariant check — do not "improve" a 5xx into a 4xx.** Series invariant 2: the rider app draws
a straight line on **every** error status (`home_screen.dart:127` is `error: (_, _)`), so a
misclassified 4xx on `/navigation/route` or `/estimates/*` does not remove a fallback — it
produces a *confidently wrong* one, with no error shown at all. The correct answer for an outage
is 5xx, or the 200 + `is_estimate` that invariant 3 and `service/navigation.go:141` already
produce via `errors.Is(rerr, repository.ErrDatasourceUnavailable)`. Leave that path alone; it is
the best-behaved error handling in the codebase and the model for the rest of this stage. The
same rule applies outside routing: the two `auth.go` rows above are 4xx-for-an-outage, which is
the same defect wearing a different endpoint.

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

**The mocks have to grow before any of that is testable.** Today
`MockGeoRepo.Upsert{Driver,Rider}Position`, `MockRideRepo.CreateEvent` and all three
`MockUserRepo.Revoke*` return `nil` unconditionally (`tests/testutil/mock_repos.go:459,571,581,218,254,266`),
while the real repositories fail them on a driver error
(`internal/repository/user_repo.go:153,175,180`, `internal/repository/ride_repo.go:139`). So every
branch the lint fix introduced — the ten 500s, the three fail-closed revocations, the logged
audit rows — is currently **unreachable from `tests/`**, and no test asserts any of them. Give the
mocks a failure knob (a `FailNext`-style field per repo, or an injected error) as part of this
stage, and add one test per landed site: write error → 500, expected sentence, cause in
`c.Errors`. Stage 01's "mocks move in lockstep" rule is what makes this stage's tests possible;
it is not optional here.

A **table of every `gin.H{"error"` site and its post-change form** is worth keeping in the diff
description. 71 sites is reviewable as a table and not as 71 individual judgements.

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
7. **Do not "fix" the best-effort rows by failing them.** `CreateEvent` and the idempotency INSERT
   run *after* the authoritative write has committed; routing their error into a 500 would report
   a failed request for work that succeeded, and would make a ride un-cancellable because its
   audit row could not be written. Log-only is the correct shape there, and it is now the
   documented contract (api_plans/STATUS.md → Invariants).
8. **Do not revert the fail-closed revocation.** `AuthService` aborting when it cannot revoke
   (`service/auth.go:111,222,257`) is the fix, not the bug. The bug is the handler's status code
   and its `err.Error()` body.

## Verification

```bash
make test && go test -count=1 ./...
gofmt -w internal/handler/respond.go internal/handler/*.go internal/service/auth.go
go vet ./...
```

Static gates (must all come back empty after the change):

```bash
# 1a. no service/database internals in a 5xx or 4xx body (stage 02's own gate)
#     today: 14 sites. The three 5xx ones (ride.go:85, ride.go:185, platform.go:412)
#     plus auth.go:159 (Refresh) and auth.go:261 (ResetPassword) are the ones the
#     fail-closed change made urgent; the rest are BAD_REQUEST/CONFLICT bodies
#     carrying service text and need the same treatment.
grep -rn '"message": err.Error()' internal/handler/ | grep -v VALIDATION_ERROR   # -> 0

# 1b. the 22 validator leaks are stage 03's gate, not this stage's
grep -rn '"message": err.Error()' internal/handler/ | grep -c VALIDATION_ERROR   # -> 22
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

# 6. the best-effort rows are still best-effort (regression guard for pitfall 7)
grep -rn 'CreateEvent' internal/service/                     # -> log-only, no early return
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
