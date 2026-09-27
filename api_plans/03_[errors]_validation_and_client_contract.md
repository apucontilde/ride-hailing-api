---
tag: errors
depends_on: ["02_[errors]_repository_errors_to_http.md"]
status: open
---

# Stage 03 — Validation text and the client contract

**Goal:** a malformed request produces a sentence a person can act on ("Pickup latitude is
required"), not a Go validator trace. And the envelope becomes a **documented** contract rather
than six files' private habit.

This is the most cosmetic stage. Nothing here fixes a wrong status code or a swallowed
diagnostic. Do it last, and it can stop at any point without the series being incomplete.

Depends on stage 02 — it replaces `fail(...)` calls that stage 02 introduced.

## The problem, precisely

**All 22** `c.ShouldBindJSON` sites respond with `err.Error()` verbatim. Verified by scanning
every binder site and its following 8 lines: 22 leaking, 0 clean.

- 9 in `auth.go` — `registerRequest`, `loginRequest`, `refreshRequest`, `logoutRequest`,
  `forgotPasswordRequest`, `resetPasswordRequest`, `verifyCodeRequest`, `socialLoginRequest`
- 3 each in `geo.go` (`locationUpdate`), `platform.go`, `ride.go` (`rideRequest`)
- 2 each in `driver.go`, `rider.go`

gin delegates to go-playground/validator, whose `ValidationErrors.Error()` for one field is:

```
Key: 'registerRequest.Email' Error:Field validation for 'Email' failed on the 'email' tag
```

On the rider's register form, in San José, a user who types a bad address sees the name of a Go
struct, the name of a Go field, and the name of a validation tag. It is not a security leak —
there is nothing secret in it — but it is the API telling the user about its own implementation
while asking them to fix their typing.

The other ~10 `VALIDATION_ERROR` sites validate query parameters by hand and already return
clean sentences (`"invalid lat"`, `"lat/lng out of range"`, `"invalid vehicle_type"`). **Do not
touch their text.** They are the model.

## Step 1 — `bindJSON` in `internal/handler/respond.go`

```go
// fieldName maps a JSON key to the words a user should see.
//
// The struct's Go field name is deliberately NOT used: "PickupLat" is an
// implementation detail, and the validator's default message prints it.
var fieldName = map[string]string{
	"email":        "Email",
	"phone":        "Phone",
	"password":     "Password",
	"first_name":   "First name",
	"last_name":    "Last name",
	"pickup_lat":   "Pickup latitude",
	"pickup_lng":   "Pickup longitude",
	"dropoff_lat":  "Drop-off latitude",
	"dropoff_lng":  "Drop-off longitude",
	"vehicle_type": "Vehicle type",
	"lat":          "Latitude",
	"lng":          "Longitude",
	"heading":      "Heading",
	"speed":        "Speed",
	"code":         "Code",
}

// bindJSON decodes and validates a body, reporting failures as a public
// sentence. Returns false when it has already written the response.
//
// The raw validator error is attached to the context (log), never returned.
// logCtx is prepended to the logged cause; pass "" to log it bare, or the
// "[sos] validation error (user=…)" shape that platform.go already uses and
// that makes its log lines worth reading.
func bindJSON(c *gin.Context, obj any, logCtx string) bool {
	err := c.ShouldBindJSON(obj)
	if err == nil {
		return true
	}

	if logCtx != "" {
		_ = c.Error(fmt.Errorf("%s: %w", logCtx, err))
	} else {
		_ = c.Error(err)
	}

	var verrs validator.ValidationErrors
	if errors.As(err, &verrs) && len(verrs) > 0 {
		names := make([]string, 0, len(verrs))
		for _, fe := range verrs {
			if n, ok := fieldName[fe.Field()]; ok {
				names = append(names, n)
			} else {
				names = append(names, fe.Field())
			}
		}
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR",
			"Invalid "+strings.Join(names, ", "), nil)
		return false
	}

	// Not a validation failure: malformed JSON, or a wrong content type. The
	// detail is in the log; the user needs to know only that the body could
	// not be read.
	fail(c, http.StatusBadRequest, "BAD_REQUEST", "Malformed request body", nil)
	return false
}
```

Requires `github.com/go-playground/validator/v10` — already present as
`github.com/go-playground/validator/v10 v10.30.1 // indirect`, so promote it in `go.mod` (it
moves out of the `// indirect` block; that is the only `go.mod` change in the whole series and it
adds no new module).

> **Why `logCtx` is a parameter and not left to the caller.** The three `platform.go` binder
> sites already build their own context *and* attach it (`platform.go:55`, `:86`, `:109`):
> `_ = c.Error(fmt.Errorf("[sos] validation error (user=%v): %w", userID, err))`. If `bindJSON`
> returns only a `bool`, `err` falls out of scope at the call site and that context is
> unrecoverable — a regression in log quality, which is the opposite of this stage's purpose. If
> instead `bindJSON` attaches unconditionally *and* the call site attaches too, every one of
> those three sites logs its cause twice. Taking the prefix as a parameter is the shape that
> attaches exactly once and keeps the endpoint name:
>
> ```go
> if !bindJSON(c, &req, fmt.Sprintf("[sos] validation error (user=%v)", userID)) {
> 	return
> }
> ```
>
> The other 19 sites pass `""`.

**Design choices worth defending:**

- **`nil` cause on the `fail` calls.** The cause was already attached above with
  `c.Error(err)`. Passing it again would log it twice.
- **`"Invalid " + names` rather than a sentence per field.** A list is honest and stays short.
  A per-field message map (`{"pickup_lat": "must be between -90 and 90"}`) is nicer, and is the
  obvious next step — but it changes the wire shape, and this series has decided (README, "what
  this does not do") not to grow a structured error payload. Ship the list.
- **Unknown field names pass through unchanged.** A key not in the map degrades to
  `fe.Field()`, which is the JSON key as tagged, not the Go field name. Better than a blank, and
  it never invents a wrong label.
- **`len(verrs) > 0` guard.** `errors.As` can succeed on an empty slice for some validator
  versions; without the guard the code would answer "Invalid " with an empty list.

Then rewrite the 19 non-`platform.go` sites as:

```go
if !bindJSON(c, &req, "") {
    return
}
```

and the 3 `platform.go` sites as shown in the note above.

`platform.go`'s 3 sites need care: they build a `c.Error` context string that includes the
endpoint name (`[sos] validation error (user=%v)`), which `bindJSON` cannot know. After
converting them, add the context explicitly:

```go
if !bindJSON(c, &req) {
    _ = c.Error(fmt.Errorf("[sos] validation error (user=%v)", userID))
    return
}
```

## Step 2 — align the swagger annotations with the code

The annotations already *describe* the contract this series implements; the code just never
matched. `auth.go:59` says `@Failure 409 {object} ErrorResponse "Account already exists"`. After
stage 02, that is true. Check the rest of the `@Failure` lines and make each one name the
sentence the handler now returns. Cheap, and it is where a future reader looks first.

Regenerate if the repo has a swagger target; if not, this is a hand-edit of comments only.

## Step 3 — document the envelope in `RIDER_API_GUIDE.md`

Add a short "Errors" section. The clients already depend on all of it; none of it is written
down:

1. Every non-2xx body is `{"error": {"code": <CODE>, "message": <string>}}`.
2. `message` is **user-facing** and safe to render verbatim. It never contains SQL, driver text,
   Go identifiers, or internal hints. This is the guarantee stage 01 + 02 + 03 exist to provide,
   and it is the sentence `shared/lib/src/api/api_exceptions.dart` depends on.
3. The code vocabulary, with what each means for a client:
   `VALIDATION_ERROR` (422, fix the request) · `BAD_REQUEST` (400, unparseable body) ·
   `UNAUTHORIZED` (401) · `NOT_FOUND` (404) · `CONFLICT` (409, e.g. email taken) ·
   `INTERNAL` (500, ours; the rider app's straight-line fallback triggers here and only here).
4. 4xx means *the caller can fix it by changing something*; 5xx means *we are broken*. A client
   must not retry a 4xx and must not treat a 5xx as final. Spell out the corollary, because the
   code violates it right now: **a backend failure is never a 4xx.**
   `POST /auth/refresh` and `POST /auth/reset-password` answer 401/400 with the wrapped
   `*pq.Error` in `message` when revocation fails (`internal/handler/auth.go:157-161`, `:259-263`;
   service at `internal/service/auth.go:111,257`). Documenting the rule is what makes stage 02's
   fix of those two sites a contract change rather than a preference.
5. Routing's 200 + `is_estimate: true` is **not** an error (api_plans/STATUS.md). Note it here so
   nobody "normalises" it into one.
6. A write that fails answers 5xx, never the endpoint's success code — including the batch
   location endpoint, where one rejected item fails the whole request
   (`internal/handler/geo.go:104`).
7. Audit rows (`ride_events`) and the idempotency store are **best-effort and invisible**: they
   are written after the authoritative row commits, a failure is logged, and the response is
   unchanged (`internal/service/ride.go:63,112,156`, `internal/middleware/idempotency.go:47,60`).
   A client must not treat a missing audit row as a failed operation.

## Step 4 — turn the probe into a regression check

`e2e/scripts/probe-register-error.mjs` currently prints the on-screen text after a duplicate-email
submit and prints `OK`/`FAIL` based on whether Dio's raw text leaked. It is a probe, not a test:
nothing fails the build.

Make it assert the **server's** contribution too, and make it exit non-zero on failure. The check
it should grow, run against the real register form in Edge:

- the on-screen text contains the deliberate duplicate sentence from stage 02
- the on-screen text does **not** contain `pq:`, `duplicate key`, `users_email_key`, `This
  exception was thrown`, or `Key: '` (the validator signature)
- the response body's `error.message` is under ~80 characters

That last one is a cheap, blunt tripwire for the whole series: every leak this series fixes
produces a long message. It needs no allowlist and cannot rot.

Better still, promote the assertions into `e2e/specs/` as a real spec so `npx playwright test`
owns them, and keep the script for "print whatever is on screen" debugging — that is what it is
genuinely good at, and `e2e/scripts/probe-rider.mjs` already fills that role.

## Tests

`internal/handler/respond_test.go` additions, table-driven:

- `bindJSON` on a body with a missing required field → 422, `VALIDATION_ERROR`, and the message
  names the **public** label (`"Email"`), and does **not** contain `registerRequest`, `Email'`,
  `binding`, or `required`.
- unknown/untagged field → message contains the JSON key, and the test asserts the Go struct name
  does not appear.
- malformed JSON (truncated, wrong content type) → 400 `BAD_REQUEST`, `"Malformed request body"`,
  cause attached to `c.Errors`.
- valid body → returns true and writes nothing.
- **the regression assertion for the whole stage**: for every one of the 22 request structs, a
  body that trips each binding tag, asserting the response body contains no `.` , no `'`, and no
  `tag` — i.e. no validator internals. Table-driven over the structs so a new endpoint inherits
  the check.

## Pitfalls

1. **`fail(c, …, nil)` after `bindJSON` already attached** logs the cause twice. `bindJSON`
   attaches exactly once, itself, with the caller's `logCtx` prefix — so every `fail` inside it
   passes `nil`. Do not also attach at the call site.
2. **Promoting `go-playground/validator/v10` from indirect to direct** is a `go.mod` change. It is
   the only one in the series; it adds no new module.
3. **`validator.ValidationErrors` can be an empty slice** after a successful `errors.As` in some
   versions. Guard `len(verrs) > 0` or the API answers `"Invalid "` on a non-validation error.
4. **Do not restructure the wire shape here.** `{field, message}` lists, error arrays, and
   machine-readable field paths are all tempting and all out of scope (README, "what this does
   not do"). A client-visible shape change needs its own plan and its own version negotiation.
5. **Do not touch the hand-written query-parameter sentences.** They are already right, and they
   are the 200 `/navigation/route` → 422 contract the AGENTS.md documents.
6. **`fieldName` is a maintenance list.** A new request field silently degrades to the raw JSON
   key, which is acceptable but visible. When adding a request struct, add its labels in the same
   edit; note it in the struct's godoc.
7. **`RIDER_API_GUIDE.md` is also the source for the agents.** Documenting the envelope there
   means the next agent reading the guide gets the contract instead of rediscovering that 71
   sites hand-roll it.

## Verification

```bash
make test && go test -count=1 ./...
gofmt -w internal/handler/respond.go internal/handler/*.go
go vet ./...
```

Static gates:

```bash
# no binder site leaks the validator any more
grep -rn -A8 "ShouldBindJSON" internal/handler/ | grep "err.Error()"   # -> 0
# and none of them hand-rolls the envelope any more
grep -rn "ShouldBindJSON" internal/handler/ | wc -l                     # -> 22
grep -rn "gin.H{\"error\": gin.H" internal/handler/ | wc -l             # -> 0
# every request field has a public label
grep -rn "binding:" internal/handler/ | wc -l                           # -> compare with len(fieldName)
```

Live, with the DB up:

```bash
# missing field: names the field a user can see
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"phone":"+15550000004","password":"SecurePass1"}'
#   -> 422 {"error":{"code":"VALIDATION_ERROR","message":"Invalid Email"}}
#   -> must NOT contain "registerRequest" or "binding"

# malformed JSON
curl -s -X POST localhost:8080/api/v1/auth/login -H 'Content-Type: application/json' -d '{'
#   -> 400 {"error":{"code":"BAD_REQUEST","message":"Malformed request body"}}

# the routing 422 contract is untouched
curl -s -o /dev/null -w '%{http_code}\n' \
  "localhost:8080/api/v1/navigation/route?from_lat=9.93&to_lat=9.94" -H "Authorization: Bearer $T"
#   -> 422, unchanged
```

Browser:

```bash
cd e2e && npm run build:apps
npx playwright test                                  # 2 passed
node scripts/probe-register-error.mjs               # friendly sentence, no internals
```

And the client side, because that is where these strings are read: `melos run analyze` and
`melos run test` must stay green. No Dart change is expected in this stage — the client already
renders whatever `error.message` contains. If a Dart change *is* needed, that is a sign the
server contract moved rather than the client's understanding of it.

## Rollout note

Fully user-visible (badly-worded errors become readable ones) and wire-compatible apart from
`message` text. No migration, no flag. The blast radius is the widest-reading stage in the series
and the narrowest in risk: 22 sites, one helper, one `go.mod` promotion, and a doc section.
