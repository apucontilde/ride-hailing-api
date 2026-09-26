# Stage 01 — Error taxonomy in `internal/repository`

**Goal:** the repository layer stops inventing prose and starts returning *classifiable* errors,
so that stage 02 can decide 404-vs-500 without string matching, and so that a missing row is
distinguishable from a dead database.

**This stage changes nothing a user can see.** No response body, no status code, no log line
changes. That is deliberate: it is the smallest change that makes stage 02 mechanical instead of
clever. If you are looking for the register screen to read better after this stage, it will not —
that is stage 02 and 03.

## Why the repository layer is where this starts

The handler cannot classify what it is given. Today `UserRepo.FindByEmail` returns
`fmt.Errorf("user not found: %w", err)` (`user_repo.go:56`), which is equally true for:

- no such row → the user mistyped, or the resource does not exist → **404**
- `dial tcp 127.0.0.1:5432: connect: connection refused` → **we** are broken → **500**

Both arrive as the same shape. `AuthService.Login` resolves the ambiguity by throwing it away
(`service/auth.go:68` returns `errors.New("invalid credentials")` for anything), which is how a
database outage became a 401 in production.

There are **33** `errors.New` / `fmt.Errorf` sites in `internal/repository`'s six non-test files
and **zero** sentinel errors except `ErrDatasourceUnavailable` (`datasource.go:28`) — which is
the one that is already handled properly, by `service/navigation.go:141`. That single
`errors.Is(err, repository.ErrDatasourceUnavailable)` is the *only* error classification in the
entire non-test codebase. This stage generalises it.

## Step 1 — `internal/repository/errors.go` (new file)

```go
package repository

import (
	"database/sql"
	"errors"
	"fmt"

	"github.com/lib/pq"
)

// Error taxonomy. Handlers classify with errors.Is and choose a status code and
// a public message; the cause is always preserved so ErrorLogger can print it.
//
// These are the only two client-actionable outcomes a repository can report.
// Everything else is an internal failure and must reach a handler as an error
// that is NOT ErrNotFound/ErrConflict, so it becomes a 500.
var (
	// ErrNotFound: no such row, or no row the caller is allowed to see.
	ErrNotFound = errors.New("not found")

	// ErrConflict: a uniqueness or state conflict the caller could resolve —
	// duplicate email/phone, a ride already accepted, a stale state machine.
	ErrConflict = errors.New("conflict")
)

// Postgres SQLSTATEs worth telling apart. Anything else is internal: a
// connection failure must never be reported to a user as a conflict.
const (
	sqlStateUniqueViolation     = "23505"
	sqlStateForeignKeyViolation = "23503"
	sqlStateCheckViolation      = "23514"
)

// wrapDB classifies err and prefixes op for the log line.
//
// The taxonomy sentinel and the original cause are both wrapped with %w so
// that BOTH errors.Is(err, repository.ErrNotFound) and
// errors.Is(err, sql.ErrNoRows) are true. Go 1.20+ accepts multiple %w verbs
// and this module is `go 1.25.0`, so a caller can keep testing the driver error
// directly while the handler tests the taxonomy.
//
// `op` is for humans reading the log line, never for the client: keep it a
// short verb-noun ("load user by email") and do not put user input in it.
func wrapDB(op string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%s: %w: %w", op, ErrNotFound, err)
	}
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		switch pqErr.Code {
		case sqlStateUniqueViolation, sqlStateForeignKeyViolation, sqlStateCheckViolation:
			return fmt.Errorf("%s: %w: %w", op, ErrConflict, err)
		}
	}
	return fmt.Errorf("%s: %w", op, err)
}
```

**Why `pq.Error` and not a string match on the message.** `lib/pq` is the driver
(`internal/database/postgres.go:9`, `repository/datasource.go:16`) and is a direct dependency, so
`pq.Error` is importable in non-test code. Its `Code` field is the SQLSTATE. The repo has
**zero** SQLSTATE inspection today, which is exactly why a duplicate email and a dead socket are
indistinguishable. Matching on the message text instead would be locale- and version-dependent.

**Why co-wrap with two `%w`.** `places_repo.go:62` compares `err == sql.ErrNoRows` today. If
`wrapDB` replaced that cause instead of adding to it, that check silently stops working. Co-
wrapping keeps every existing test and any future driver-level assertion valid while adding the
taxonomy on top. Single-`%w` would be the tidier-looking choice and is a trap.

**Do not** add `ErrInvalid`/`ErrUnauthorized` in this stage. Nothing in the repository layer
distinguishes them today, and inventing sentinels with no caller is how a taxonomy rots.

## Step 2 — route every repository error through `wrapDB`

33 sites across 6 non-test files. The table below covers the 23 `fmt.Errorf` sites that
`wrapDB` absorbs; the 19 bare `return err` sites are in "Also fix" further down.

| file:line | current | becomes |
|---|---|---|
| `user_repo.go:56`, `:65` | `user not found: %w` | `wrapDB("load user by email"/"load user by id", err)` |
| `user_repo.go:91` | `rider not found: %w` | `wrapDB("load rider", err)` |
| `user_repo.go:116` | `driver not found: %w` | `wrapDB("load driver", err)` |
| `user_repo.go:146` | `refresh token not found: %w` | `wrapDB("load refresh token", err)` |
| `user_repo.go:168` | `password reset token not found: %w` | `wrapDB("load password reset token", err)` |
| `ride_repo.go:52` | `ride not found: %w` | `wrapDB("load ride", err)` |
| `ride_repo.go:64`, `:76` | `no active ride: %w` | `wrapDB("load active ride", err)` |
| `ride_repo.go:155` | `ride already accepted or not found` | `fmt.Errorf("accept ride: %w: %w", ErrConflict, sql.ErrNoRows)` — see note |
| `ride_repo.go:172` | `vehicle not found: %w` | `wrapDB("load vehicle", err)` |
| `geo_repo.go:84` | `failed to find nearby drivers: %w` | `wrapDB("find nearby drivers", err)` |
| `geo_repo.go:101` | `driver location not found: %w` | `wrapDB("load driver location", err)` |
| `geo_repo.go:120` | `failed to count nearby drivers: %w` | `wrapDB("count nearby drivers", err)` |
| `places_repo.go:43` | `failed to find nearby places: %w` | `wrapDB("find nearby places", err)` |
| `places_repo.go:66` | `failed to reverse geocode: %w` | `wrapDB("reverse geocode", err)` |
| `places_repo.go:74` | `failed to count places: %w` | `wrapDB("count places", err)` |
| `places_repo.go:116` | `failed to bulk insert places: %w` | `wrapDB("bulk insert places", err)` |
| `navigation_repo.go:112` | `failed to load routing regions: %w` | `wrapDB("load routing regions", err)` |
| `navigation_repo.go:390`, `:406` | `failed to load road network vertices/edges: %w` | `wrapDB("load road network vertices"/"…edges", err)` |
| `navigation_repo.go:428`, `:445` | same, per region | `wrapDB(…, err)` — keep the region in `op` or the `%w` tail, but **never** in a message the client will see |

**Note on `ride_repo.go:155`.** It is the one deliberate `ErrConflict` that is not a driver
error: a conditional `UPDATE … WHERE status='pending'` that affected 0 rows means either "someone
else took it" or "no such ride", and the caller must not be able to tell. It has no underlying
`sql.ErrNoRows` to classify, so it needs the sentinel explicitly. Co-wrap `sql.ErrNoRows` so that
"not found" remains answerable by a caller that asks the other question.

**Leave these alone.** They are not driver errors and stage 02 already has a rule for each:

- `datasource.go:28,215,227,240,295,302` — the datasource family, already sentinel-driven.
- `navigation_repo.go:257,335` — "road network not imported: run scripts/…". This is an
  **operator** message and belongs in the log, not in a 500 body. api_plans/05/06 guarantee the
  endpoint degrades to a 200 estimate rather than erroring, so these strings should never reach
  a client. Do not reclassify them; do not delete them.
- `navigation_repo.go:503` (`route references unknown node %d`) and `pgrouting_repo.go:180`
  (`invalid region id %q`) — internal invariants. Wrap, classify as internal, and let the log
  carry the number.

### Also fix, in the same commit: the 19 bare `return err` sites

These are the quiet ones. They look harmless — the caller gets a real error — but an
**unwrapped** `*pq.Error` cannot be classified, so each one silently keeps returning 500 for
cases that should be a 409 or a 404, and each one leaks raw driver text into the log-only path
with no `op` to say which query failed.

| file:line | function | `op` to use |
|---|---|---|
| `user_repo.go:76` | `UpdateUser` | `update user` |
| `user_repo.go:84` | `CreateRider` | `create rider` |
| `user_repo.go:101` | `UpdateRider` | `update rider` |
| `user_repo.go:109` | `CreateDriver` | `create driver` |
| `user_repo.go:126` | `UpdateDriver` | `update driver` |
| `user_repo.go:131` | `SoftDeleteUser` | `soft delete user` |
| `user_repo.go:139` | `CreateRefreshToken` | `create refresh token` |
| `user_repo.go:153` | `RevokeRefreshToken` | `revoke refresh token` |
| `user_repo.go:161` | `CreatePasswordResetToken` | `create password reset token` |
| `user_repo.go:175` | `RevokePasswordResetToken` | `revoke password reset token` |
| `user_repo.go:180` | `RevokeUserPasswordResetTokens` | `revoke user password reset tokens` |
| `geo_repo.go:46` | `UpsertDriverPosition` | `upsert driver position` |
| `geo_repo.go:58` | `UpsertRiderPosition` | `upsert rider position` |
| `geo_repo.go:129` | `MarkStaleDriversOffline` | `mark stale drivers offline` |
| `ride_repo.go:139` | `UpdateRideStatus` | `update ride status` |
| `ride_repo.go:148`, `:152` | `AssignDriver` (Exec, RowsAffected) | `assign driver` |
| `ride_repo.go:165` | `CreateEvent` | `create ride event` |
| `ride_repo.go:182` | `CreateRating` | `create rating` |

`datasource.go:293` is the 20th bare `return err` and stays with the datasource family.

**`ride_repo.go:148`/`:152` need a closer look than the rest.** `AssignDriver` is the one place
in the repository where "0 rows affected" is a *business* outcome rather than a driver error, and
it is already handled explicitly at `:154` (the `rows == 0` → conflict case in the table above).
The two bare returns are genuine driver failures and `wrapDB` them normally. Do not merge them
into the `rows == 0` branch; that branch is a race, not an error, and the two must stay
distinguishable.

**`MarkStaleDriversOffline` (`geo_repo.go:125`) is dead code** — nothing calls it. Wrap it with
the rest for consistency, but do not treat it as a live path, and do not spend this stage
wiring it up. (Worth a separate note: dispatch's 30-second freshness rule
(`repository/geo_repo.go:73`) makes this redundant anyway.)

## Step 3 — the mocks move in lockstep (**not optional**)

`tests/testutil/mock_repos.go` has **21** hand-rolled error strings and **zero** sentinels. This
is the single most important step in the stage, because **a missed mock fails silently**: the
test suite stays green while asserting behaviour that cannot happen in production.

That is precisely how the dropped-offer bug survived a green Go suite for its whole life —
`FabricateNearbyDriver` fabricated a `simulated-driver` whenever nobody was online, so dispatch
"always worked".

Replace, in the same commit:

| line | current | becomes |
|---|---|---|
| 46 | `fmt.Errorf("user with email %s already exists", u.Email)` | `fmt.Errorf("create user: %w: %w", repository.ErrConflict, errDuplicateEmail)` — or simply `fmt.Errorf("create user: %w", repository.ErrConflict)` |
| 69, 73, 84, 95, 185 | `fmt.Errorf("user not found")` | `fmt.Errorf("load user: %w", repository.ErrNotFound)` |
| 121, 132 | `rider not found` | `fmt.Errorf("load rider: %w", repository.ErrNotFound)` |
| 161, 172 | `driver not found` | `fmt.Errorf("load driver: %w", repository.ErrNotFound)` |
| 207 | `refresh token not found` | `fmt.Errorf("load refresh token: %w", repository.ErrNotFound)` |
| 243 | `password reset token not found` | `fmt.Errorf("load password reset token: %w", repository.ErrNotFound)` |
| 313, 415, 444 | `ride not found` | `fmt.Errorf("load ride: %w", repository.ErrNotFound)` |
| 332, 350 | `no active ride` | `fmt.Errorf("load active ride: %w", repository.ErrNotFound)` |
| 447 | `ride is not pending` | `fmt.Errorf("update ride status: %w", repository.ErrConflict)` |
| 637 | `driver location not found` | `fmt.Errorf("load driver location: %w", repository.ErrNotFound)` |

**Lines 210 and 246 are not a string problem — they are a divergence.** The mock returns
`"refresh token expired"` (`:210`) and `"password reset token expired"` (`:246`) *from the
repository*. Production never does that: `UserRepo.FindRefreshTokenByHash` returns the row, and
`service/auth.go:98` checks `time.Now().After(stored.ExpiresAt)` in the **service**. So the mock
is testing a code path that cannot run, and the service's own expiry branch is exercised by no
test that uses the mock.

Fix by making the mock behave like the repository: return the token model with a **past
`ExpiresAt`** and let `AuthService` reject it. That makes the service's real branch the thing
under test, and it means the mock no longer needs an error string at these two lines at all.
(Do not "fix" it the other way round by teaching the repository to reject expiry — that would
move a business rule down a layer.)

Check `tests/testutil` imports `internal/repository` — if it currently does not, that import is
the clearest signal that the mock layer was built to avoid the real one.

**`mock_repos.go:46` deserves a second look.** Its message,
`user with email %s already exists`, is the friendly text that the e2e probe printed — and it
exists *only in the mock*. Once the real repository classifies `23505` as `ErrConflict`, the
public sentence for a duplicate email has to be decided deliberately in stage 02, not inherited
from a test double. Decide whether to echo the address at all (it is the user's own input, so it
is not a leak, but it does make the message long).

## Step 4 — tests

New `internal/repository/errors_test.go`, table-driven, next to the code (repo convention):

- `wrapDB` returns `nil` for `nil` — no `nil: ` prefix bug.
- `wrapDB("op", sql.ErrNoRows)` → `errors.Is(…, ErrNotFound)` **and** `errors.Is(…, sql.ErrNoRows)`.
- `wrapDB("op", &pq.Error{Code: "23505"})` → `errors.Is(…, ErrConflict)`, and **not**
  `ErrNotFound`.
- `wrapDB("op", &pq.Error{Code: "23503"})`, `"23514"` → `ErrConflict`.
- `wrapDB("op", &pq.Error{Code: "08006"})` (connection failure) → **neither** sentinel. This is
  the regression test for failure #1 in the series README: an outage must not be classifiable as
  a client error.
- `wrapDB("op", &pq.Error{Code: "23505"})` wrapped by another `fmt.Errorf("ctx: %w", …)` still
  classifies — i.e. `errors.As` sees through intermediate wraps.
- The public `Error()` of a wrapped `23505` contains the constraint name (it must stay in the
  **log**). The point is that the log keeps the detail; stage 02 keeps it out of the body.

New assertions in the mock-facing tests: at least one test that a missing user yields
`ErrNotFound` and one that a duplicate email yields `ErrConflict`, both against the **mock**,
so the lockstep in step 3 is enforced by the suite rather than by reviewer discipline.

## Pitfalls

1. **Do not skip the mocks.** Covered above; it is the whole reason this stage can fail quietly.
2. **`err == sql.ErrNoRows` still compiles after the change** (`places_repo.go:62`) and will
   silently stop matching if you ever drop the co-wrap. Keep the co-wrap, and prefer
   `errors.Is` at that call site in the same commit.
3. **`pq.Error` is a pointer type.** `errors.As(err, &pqErr)` with `var pqErr *pq.Error`. A
   value-typed `pq.Error` variable silently never matches, and every unique violation quietly
   degrades to a 500.
4. **Wrapped-nothing changes the message.** `wrapDB` prefixes every error with `op`, so log
   lines and any test asserting on error text will change. Grep for tests matching on repository
   error strings before landing. (Today: **none** assert on repository error text — the only
   `message` assertion in `tests/` is `cross_cutting_test.go:64`, unrelated. Verify, don't
   assume.)
5. **The routing sentinel already exists.** Do not add a second "no route" sentinel or route
   `routing.ErrNoRoute` through `wrapDB`; `service/navigation.go:141` depends on it by identity
   and the api_plans/05/06 estimate contract depends on that.
6. **Do not reclassify the "road network not imported" strings.** They are operator hints whose
   visibility is a deployment concern; the endpoint contract (200 estimate) already prevents them
   from reaching a client.

## Verification

```bash
go test -count=1 ./...                 # must stay green; no DB needed
go test -count=1 ./internal/repository/...
gofmt -w internal/repository/errors.go internal/repository/*.go tests/testutil/mock_repos.go
go vet ./...
```

Grep gates (all must return nothing after the change):

```bash
# every repository error goes through the classifier: 30 fmt.Errorf sites today
grep -rn "fmt.Errorf" internal/repository/*.go | grep -v _test.go
# -> must be EXACTLY these 7, and no others:
#      datasource.go:227  datasource.go:240  datasource.go:295  datasource.go:302
#      navigation_repo.go:335   ("road network not imported for region")
#      navigation_repo.go:503   ("route references unknown node" invariant)
#      pgrouting_repo.go:180    ("invalid region id" invariant)

# no mock invents its own taxonomy any more
grep -n "errors.New\|fmt.Errorf" tests/testutil/mock_repos.go | grep -v "repository.Err"
# -> only datasource/routing sentinels, if any
```

Live, with the DB up (this is the assertion mocks cannot make — it needs a real unique index):

```bash
docker compose up -d && make run   # in another shell
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"stage01@example.com","phone":"+15550000002","password":"SecurePass1"}'
curl -s -X POST localhost:8080/api/v1/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"stage01@example.com","phone":"+15550000002","password":"SecurePass1"}'
# the second must fail with a *pq.Error in the log whose Code is 23505
```

Behavioural proof that the classification works and the old code could not:

```bash
docker compose stop ride-hailing-db     # simulate the outage of series-failure #1
curl -s -X POST localhost:8080/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"stage01@example.com","password":"SecurePass1"}'
# the service log must show a pq.Error that is NOT ErrNotFound
docker compose start ride-hailing-db
```

Stage 02 turns that last observation into a 500 instead of a 401. This stage only makes it
*visible*.

## Rollout note

Nothing here is user-visible, so there is no flag and no migration. The whole stage is
reviewable as one diff to `internal/repository/errors.go` (new), the 33 call sites, and
`tests/testutil/mock_repos.go`. If a reviewer wants to stop the series after stage 01, the
repository layer is still strictly better off: errors are classifiable and the mocks finally
agree with production.
