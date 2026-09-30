---
tag: errors
depends_on: []
status: open
---

# Unit tests for the idempotency middleware

Bug #9: `internal/middleware/idempotency.go` has **no test at all** — the package's only suite is
`auth_test.go` (`AuthRequired`/`maskQueryTokens`). The "never replay a partial read" rule and the
skip-store-on-error rule are therefore unenforced: a future edit could silently re-introduce the
`AbortWithStatusJSON(0, nil)` bug (replaying a zero status / nil body) without failing CI.

**Read first:**

- `internal/middleware/idempotency.go` — whole file. `loadStoredResponse:16-26` (both columns must
  read), `Idempotency:28-64` (`:41-48` replay-or-re-run, `:53-63` store-on-2xx only).
- `internal/middleware/auth_test.go:1-40` — the package's DB-free gin `httptest` test shape.
- `internal/middleware/` — no `idempotency_test.go` exists.

## Gap (verified)

`Idempotency` takes a concrete `*sqlx.DB`, so the middleware cannot be exercised without a live
database and the repo has no `go-sqlmock`. The rule that a partial read must **re-run** the handler
(as opposed to replaying a bogus response) is exactly the kind of branch a test must pin.

## Work

1. **Make it unit-testable without a DB.** Introduce the smallest seam that preserves behavior:
   an `idempotencyStore` interface (`Count` / `Load` / `Store`) with a `sqlIdempotencyStore` that
   wraps `*sqlx.DB`; keep the public `Idempotency(db *sqlx.DB)` constructor (defaulting to the SQL
   store) and add an unexported `idempotencyWithStore(store)` for tests. Do not change the
   `router` call site.
2. **Tests — `internal/middleware/idempotency_test.go`** (gin `httptest` + a fake store):
   - no `Idempotency-Key` / nil store → handler runs once, store untouched;
   - key present, `Count > 0`, both columns readable → replays the stored status + body and does
     **not** run the handler;
   - key present, `Count > 0`, **body read fails** → logs and re-runs the handler (the partial-read
     rule);
   - key present, `Count > 0`, **status read fails** → same;
   - handler answers 200/201 → the response is stored; handler answers 4xx/5xx → it is not;
   - store `INSERT` fails → logged, response unchanged.
3. **Scope is test-only.** The always-`{}` replay-body defect found at `idempotency.go:54` is filed
   as its own bug and fixed by `api_plans/[errors]_idempotent_replay_body.md` — do **not** fix it
   here. This plan only adds the tests; once that fix lands, its replay-body-equality test rides
   on the same fake-store seam introduced here.

## Tests

- `internal/middleware/idempotency_test.go` covering the partial-read re-run, replay, and
  store/no-store branches.

## Accept

- `go test ./internal/middleware/` runs DB-free and fails if the partial-read rule regresses.
- The replay-body bug is tracked by `[errors]_idempotent_replay_body.md`, not solved here.
- Bug #9 is closed.

## Verify

```bash
go test -count=1 ./internal/middleware/
make test && make lint
```
