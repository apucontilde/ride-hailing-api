---
tag: errors
depends_on: []
status: open
---

# [errors] Idempotency JSON replay is not byte-faithful

Closes `api_plans/STATUS.md` known bug **#22** (the residual after bug #17). The non-JSON
branch is already byte-faithful and DB-proven; the JSON / empty-content-type branch is not.

## Current state (verified 2026-10-04)

`internal/middleware/idempotency.go`:

- `replayableBody` (`:238-261`):
  - an **empty capture** becomes literal `null` for every content type (`:242-244`);
  - the **JSON / empty content-type** branch `bytes.TrimSpace`s the captured body (`:249`)
    and stores the trimmed document (or a JSON-string encoding of it if invalid);
  - the **non-JSON** branch JSON-string-encodes the exact captured bytes (`:256-260`).
- `replayBody` (`:284-295`): JSON / empty content-type returns the JSONB body as-is
  (`:288-290`); non-JSON unwraps the JSON string (`:292-294`).
- The non-JSON path is byte-faithful, proven through **real Postgres** by
  `TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres`
  (`internal/middleware/idempotency_integration_test.go:26-91`): plain text, a JSON string
  literal, whitespace-only, empty, and HTML-significant bytes all round-trip exactly.

Residual defects in the JSON / empty-CT branch:

1. **Whitespace is trimmed.** `bytes.TrimSpace(captured)` (`:249`) drops a trailing newline
   and any surrounding whitespace before storage.
2. **Empty body replays as `null`.** An empty capture is stored as `null` (`:242-244`); for a
   JSON content type `replayBody` returns that body verbatim (`:288-290`), so the replay
   writes the four bytes `null` instead of nothing.
3. **JSONB canonicalises JSON anyway.** Even without `TrimSpace`, the body is stored as a
   JSON *document* in the `response_body JSONB` column
   (`internal/database/migrations/007_create_misc.up.sql:70-76`), which does not preserve
   whitespace or key order. Exact-byte JSON replay is therefore **impossible** while the
   JSON body is stored as a JSON document — this is the load-bearing fact the fix must
   confront, not paper over.
4. **Empty content-type with a non-JSON body replays JSON-quoted.** `contentType == ""` is
   routed to the JSON branch (`:245`, `:288`), so a non-JSON body under a missing
   `Content-Type` is stored JSON-string-encoded and replayed with its quotes intact.

Reachability in production:

- Idempotency is constructed at `internal/router/router.go:153` and mounted **only** on
  `POST /api/v1/rides` (`internal/router/router.go:232`); `CreateRide` always writes compact
  JSON via `c.JSON` (`internal/handler/ride.go:172`), so the **non-JSON branch is
  unreachable in production** and the JSON trim/empty path is reachable in principle but not
  triggered by the current handler.
- **False citation to fix in code:** the doc comment at `internal/middleware/idempotency.go:236`
  says the mount is `internal/router/router.go:173`; the actual mount is `:232`. (Bug #22 in
  STATUS.md already cites `:232` correctly. This is a Go comment, so it is a hand-off to the
  implementer, not an edit made by this plan.)

## Scope

1. **Make JSON-CT replay byte-faithful.** Because JSONB normalises JSON, the only way to
   preserve exact bytes is to stop storing the JSON body as a JSON document. Design:
   JSON-string-encode the exact captured bytes for **every** content type (the trick already
   used for non-JSON) and unwrap on replay uniformly. Drop `bytes.TrimSpace` and the
   `json.Valid` branch entirely. This preserves key order, whitespace and numeric formatting.
   - **Back-compat:** the table has **no TTL** (`idempotency_keys` has no `expires_at`;
     `007_create_misc.up.sql:70-76`), so pre-change rows persist. `replayBody` must keep the
     current fallback: if `json.Unmarshal(body, &s)` fails (an old raw-JSON row), return
     `body` as today. Document that a pre-change JSON row replays JSONB-canonicalised —
     acceptable, since JSON clients parse it.
   - **Alternative if the storage-shape change is judged too invasive:** accept JSONB
     canonicalisation for JSON, remove only `TrimSpace`, and explicitly document that
     exact-byte JSON replay is not achievable through the JSONB column. Pick one and record
     the decision; do not leave it implicit.
2. **Decide/document empty-body semantics.** Store the empty string (it satisfies the
   `NOT NULL` constraint just as `null` does) and replay **zero bytes** for every content
   type; retire the `null` sentinel and the `null`→empty special case.
3. **Keep the non-JSON path correct.** Its exact-byte guarantee and
   `TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres` must stay green.

**Is it worth doing now?** The non-JSON branch is unreachable in production and the JSON trim
is latent (no current handler emits surrounding whitespace). The change is nevertheless small,
makes the middleware's contract uniform and fully testable, and fixes the real
`null`-for-empty replay. **Recommendation: do it as correctness insurance, low priority** — it
is not rider-visible. Do not silently drop it: if deferred, keep bug #22 open with this plan
as owner.

## Invariants carried in

- Idempotency is a **best-effort replay cache**: a store failure never changes the client's
  response (`internal/middleware/idempotency.go:203-215`).
- Only `200`/`201` are stored; an unreadable or implausible stored row re-runs the handler
  (`:139-176`).
- A replay echoes the **original** `Content-Type` (`:172-173`, `:269-277`).
- Success paths and status codes are unchanged; `POST /rides` clients see identical bytes.
- Mocks move in lockstep — the store seam (`idempotencyStore`, `:23-31`) and its fake must
  keep exercising the branches the production store can take.

## Verification

```bash
make test
gofmt -w internal/middleware/idempotency.go internal/middleware/idempotency_integration_test.go
go vet ./...
make lint
make test-integration   # real-Postgres JSON round-trip
```

Tests to add (extend `internal/middleware/idempotency_integration_test.go` or add a sibling):

- JSON CT, compact body (`application/json; charset=utf-8`, `{"ride":{...}}`) → exact bytes
  back.
- JSON CT with a **trailing newline and surrounding spaces** → exact bytes back (the current
  `TrimSpace` bug).
- JSON CT with an **empty body** → **zero bytes** back (the current `null` bug).
- An **old-shape raw-JSON row** (inserted directly as a JSON document) → the fallback returns
  it rather than failing.
- The existing non-JSON cases stay green.

## Cross-domain notes

- No Flutter change. `POST /api/v1/rides` always emits compact JSON, which round-trips
  identically under the new storage shape, so the app is unaffected.
