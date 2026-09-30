---
tag: errors
depends_on: []
status: open
---

# Idempotent replay returns the real response body, not `{}`

Latent bug found while writing `[errors]_idempotency_middleware_tests.md`: `idempotency.go` stores
`json.Marshal(gin.H{})` — literally `{}` — as `response_body`, regardless of what the handler
actually wrote. A replayed request therefore returns the correct **status** but an empty **body**.
For a create-ride response that means the client gets `200`/`201` with no ride payload, which is
worse than no idempotency at all (it looks like success with missing data).

**Read first:**

- `internal/middleware/idempotency.go:53-63` — the store path; `:54` is the `{}` marshalling.
- `internal/middleware/idempotency.go:16-26,41-48` — `loadStoredResponse` + the replay path.
- `internal/database/migrations/007_create_misc.up.sql:70-76` — `response_body JSONB NOT NULL`.
- `api_plans/[errors]_idempotency_middleware_tests.md` — the sibling test-only plan (introduces the
  fake-store test seam this fix should test through).

## Gap (verified)

`responseBody, _ := json.Marshal(gin.H{})` is a constant. Nothing captures `c.Writer`'s output, so
the stored `response_body` can never match the handler's response. The replay branch
(`c.AbortWithStatusJSON(status, body)`) faithfully replays the wrong (empty) body.

## Work

1. Capture the real response body in the middleware. The cleanest seam: wrap `c.Writer` in a
   `gin.ResponseWriter` that tees `Write` into a `bytes.Buffer` (set before `c.Next()`, read
   after), then store `buffer.Bytes()` (a JSON object in every current 2xx handler). Store `NULL`
   or skip storage if the buffer is empty and the column cannot take `{}`-free empties.
2. Keep the write path guarded by the same 200/201 condition and the best-effort logging
   (`INSERT` failure must never change the response).
3. Tests (extend `internal/middleware/idempotency_test.go` from the sibling plan, or add here if
   that is not yet landed):
   - first request stores a body equal to the handler's actual JSON;
   - a replay with the same key returns that exact body and status, and the handler does not run;
   - a non-JSON/empty body is handled without a failed `INSERT` changing the response.

## Tests

- The replay-body-equality test above, via the fake-store seam.

## Accept

- A replayed request returns the original response body, not `{}`.
- Store failures stay best-effort (logged, response unchanged).

## Verify

```bash
go test -count=1 ./internal/middleware/
make test && make lint
make test-integration   # idempotent create-ride replay, needs docker compose
```
