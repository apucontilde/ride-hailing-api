---
tag: auth
depends_on: []
status: open
---

# Web session token contract — server-side record + guardrails

> **Decision: no API code change is required for this work.** The rider-web
> session-persistence bug (on refresh, the app re-asks for login) is being fixed
> **Flutter-only**. This file is not an implementation plan; it is the record of the
> server contract the client relies on, the client obligations that contract implies, and
> the guardrails that keep the contract stable while the fix lands. Kept `open` so the
> contract stays tracked and re-audited, even though the server half is documentary.
>
> Cross-domain: the client-side fix belongs in `rider_app_plans/` (owned by
> `rider-planner`). This file does **not** `depends_on` a Flutter file — apps live in
> their own domain directories.

## Why this file exists

The investigation concluded the server already exposes everything a durable web session
needs. The failure is client-side: the web build is not persisting/exchanging the refresh
token correctly across reloads. Recording the contract here (a) makes the "no API change"
decision explicit, (b) enumerates exactly what the client must do, and (c) prevents a
future server change from silently breaking the client fix.

## Verified server contract

All line numbers verified against the tree at the time of writing (2026-10-06).

### Endpoints

- `POST /api/v1/auth/login` — public; returns `{access_token, refresh_token, user}` —
  `internal/router/router.go:179`, `internal/handler/auth.go:103-128` (response body
  `:119-127`); service `internal/service/auth.go:91-118`.
- `POST /api/v1/auth/refresh` — public (general rate limit only, **no auth middleware and no
  idempotency middleware**) — `internal/router/router.go:180`; handler
  `internal/handler/auth.go:142-162`. Body is `{"refresh_token": "..."}`, field
  `binding:"required"` (`internal/handler/auth.go:12-14`).
- `POST /api/v1/auth/logout` — requires `Authorization: Bearer <access_token>` and revokes
  the refresh token in the body — route `internal/router/router.go:181`; handler
  `internal/handler/auth.go:177-189`; service `internal/service/auth.go:156-164`.
- Access token is sent as `Authorization: Bearer <access_token>`
  (`RIDER_API_GUIDE.md:9`); the CORS config explicitly allows that header
  (`internal/router/router.go:126`).

### Token TTLs

- Access token: `JWT_ACCESS_TTL`, default **15m** — `internal/config/config.go:195` (struct
  field `:23`); applied at `internal/service/auth.go:205`.
- Refresh token: `JWT_REFRESH_TTL`, default **720h (30 days)** —
  `internal/config/config.go:196` (struct field `:24`); applied at
  `internal/service/auth.go:223`.
- Both are server env knobs; neither is exposed to or controllable by the client.

### Refresh token format, rotation, and revocation

- The refresh token is **opaque random** (32 random bytes, hex-encoded to 64 chars), not a
  JWT (`internal/service/auth.go:215`, `generateRandomToken` `:232-238`). Only its
  **SHA-256 hash** is stored
  (`internal/service/auth.go:222`, `hashToken` at `:319-322`); the plaintext is never
  persisted. Table shape `refresh_tokens` (`token_hash`, `expires_at`, `revoked`) —
  `internal/database/migrations/003_create_auth_tokens.up.sql:1-8`.
- **`/auth/refresh` rotates**: it mints a **new access token and a new refresh token** and
  returns both — `internal/service/auth.go:120-153`; response body
  `internal/handler/auth.go:158-161`. Documented in `RIDER_API_GUIDE.md:59`.
- **The old refresh token IS revoked on rotation** — `internal/service/auth.go:140`
  (`RevokeRefreshToken(stored.ID)`), before the new pair is generated at `:144-151`. The
  lookup excludes revoked rows (`internal/repository/user_repo.go:142`,
  `... AND revoked = FALSE ...`), so replaying the pre-rotation token fails. Proven by
  `tests/auth_test.go:115-153` (new access token differs at `:145`; the old refresh token
  now answers `401` at `:149-152`).
- **Logout revokes only the refresh token** (`internal/repository/user_repo.go:149-152`;
  proven by `tests/auth_test.go:256-282`). The already-issued **access token stays valid
  until its `exp`** — there is no access-token denylist and access validation is stateless
  JWT HS256 with an `exp` claim (`internal/service/auth.go:166-183,200-213`). A web client
  must therefore also drop the access token locally on logout; the server cannot invalidate
  it.
- **Revocation fails closed**: if the old refresh token cannot be revoked, no new pair is
  minted and the request is a `5xx`, not a success — `internal/service/auth.go:140-142`
  (wrapped `ErrTokenRevoke`), mapped to `500 INTERNAL` at `internal/handler/auth.go:154`.
- **Rotation is not token-family / reuse detection**: a reused (already-rotated) token is
  simply "not found" → `401`; there is no cascade revoking the rest of a token family. The
  contract is single-token linear rotation, nothing stronger.

### Failure semantics the server currently emits (definitive vs transient)

- **401 is definitive**: genuinely missing / invalid / expired access token
  (`internal/middleware/auth.go:27-31` missing; `:34-40` invalid/expired) or an unusable
  refresh token (unknown, expired, or revoked) — `internal/service/auth.go:122-133`,
  mapped at `internal/handler/auth.go:150-152`.
- **422 is a client bug**: a missing/malformed `refresh_token` body is `422 VALIDATION_ERROR`
  via `bindJSON` (`internal/handler/auth.go:12-14`; `internal/handler/respond.go`).
- **5xx is transient**: any backend failure (including a failed revocation) is `500 INTERNAL`
  with an attached cause, never a `401` — `internal/handler/auth.go:154` (refresh),
  `:111-116` (`login`), sentinels `internal/service/auth.go:36,42,48`. This is the landed
  `[errors]` policy: a login/refresh outage answers `500`, never `401`
  (`api_plans/STATUS.md:140-144`).
- **No idempotency on refresh** (`internal/router/router.go:180`): if the client sends a
  refresh, the server rotates and **the response is lost to a timeout**, the stored refresh
  token is now dead server-side. The client's next attempt with the old token is a genuine
  `401`, forcing re-login. This is the sharpest reason the client must single-flight refresh
  and must not treat a timeout as "not yet rotated".

### CORS

- `AllowAllOrigins: true` — `internal/router/router.go:124` (inside the config at `:123-128`).
  `AllowCredentials` is **not set** (default false).
- Consequence: `Access-Control-Allow-Origin: *` is emitted. Browsers refuse to send/receive
  cookies on a credentialed cross-origin request when the origin is `*`, and no
  `Access-Control-Allow-Credentials: true` is present. **httpOnly-cookie sessions are
  therefore impossible on this config without a real server change** (see Future option).
  Bearer tokens in the `Authorization` header work because that header is explicitly allowed
  (`:126`), which is why the Flutter-only Bearer fix is viable.

## Client obligations implied by the contract

The server half is complete; these are what the client must do (for `rider-planner` to own):

1. **Cold start exchanges, not re-logins.** On boot, if the stored access token is
   missing/expired, call `POST /auth/refresh` with the persisted refresh token before
   declaring the session dead. Only a definitive `401` from refresh means "re-login".
2. **Persist the rotated refresh token atomically.** `/auth/refresh` returns a **new**
   `refresh_token` every time and immediately revokes the old one
   (`internal/service/auth.go:140-151`). The client must overwrite its stored refresh token
   with the response value in the same durable step that signs in the new access token. A
   crash/close between "sent" and "persisted" leaves a dead token.
3. **Single-flight refresh.** Refresh has no idempotency guard (`router.go:180`) and rotates
   on every accepted call. Concurrent refreshes (multiple tabs / parallel 401 retries) race:
   only one wins, the rest get `401` on a now-rotated token. Serialize refreshes behind one
   in-flight future and queue retries behind it.
4. **Distinguish definitive from transient.** `401` = drop the session and re-login. `5xx`,
   timeout, or no network = **keep** the stored tokens and retry later; do **not** log out.
   Logging out on a transient failure is the bug class this plan exists to prevent.
5. **TTL expectations.** 15m access means a refresh roughly every 15 minutes; the 30-day
   refresh is the real session lifetime. Proactively refresh before an access token expires
   (rather than only reacting to a 401) to keep the UX seamless. Do not assume the server
   will extend the refresh TTL per use — it is a fixed window from mint.
6. **Logout.** Call `POST /auth/logout` with the refresh token (auth header required), then
   drop both tokens locally; the access token cannot be server-revoked.
7. **Longer access TTL is not a fix.** Raising `JWT_ACCESS_TTL` only reduces refresh
   frequency; a client that fails to persist the refresh token still re-logins, and a longer
   stateless access token widens the window in which a leaked token cannot be revoked. Treat
   it as an optional mitigation only, never a substitute for (1)–(4).

## Security posture (accepted for this fix)

- Web storage of the refresh token is **not XSS-proof**. `flutter_secure_storage` on web
  encrypts values but keeps the key in `localStorage` (JS-readable, not httpOnly), so any
  same-origin script execution can exfiltrate the token. On mobile the same API uses
  Keychain/Keystore and is materially stronger.
- This is an **accepted trade-off** of the Flutter-only Bearer fix, not a server defect.
  Revisit only alongside the cookie option below.

## Guardrails — do not break the client fix

- Keep Bearer auth on `POST /auth/refresh`/`login` working; do **not** require cookies.
- Keep `401` reserved for a genuinely unusable token. An outage must stay `5xx` (never a
  `4xx`), per the `[errors]` invariant and `api_plans/STATUS.md:519`.
- Keep rotation on every refresh and either keep `refresh_tokens.revoked` semantics or ship
  a client migration first; switching to non-rotating refresh tokens without one would be a
  silent contract change.
- Do not enable credentialed CORS casually; `AllowAllOrigins` + credentials is invalid, so
  it requires replacing `*` with an explicit allowlist.
- Keep the refresh response body keys (`access_token`, `refresh_token`) unchanged — the
  guide (`RIDER_API_GUIDE.md:59,88-92`) and the client bind them verbatim.

## Future option (explicitly NOT this work): httpOnly cookie session

An httpOnly, Secure, SameSite cookie carrying the refresh token would remove it from JS
reach and blunt the XSS exposure above. It is **out of scope** here because it needs a real
server change: the CORS config must stop allowing `*` for credentialed requests, an origin
allowlist must be introduced, CSRF protection added, and both login/refresh/logout revisited
to set/clear cookies. Recorded as a future hardening option, not a requirement of the
web-session fix.

## Verification

- Contract is asserted by `tests/auth_test.go:115-153` (rotation + old token revoked) and
  `tests/auth_test.go:256-282` (logout revokes).
- TTL defaults/knobs: `internal/config/config.go:195-196`.
- `make test` stays green (no code change is part of this plan).
