-- 018_push_pipeline.up.sql
-- api_plans/[push]_delivery_pipeline.md
--
-- 1. device_tokens.token becomes GLOBALLY unique. A push token identifies a
--    device install, not a (user, device) pair: when the same device signs in
--    as a different user, the registration must MOVE to the new user. The
--    pre-existing UNIQUE(user_id, token) allowed the same token to stay active
--    for two users at once, so the old user would keep receiving the new
--    user's notifications. The repository upserts on `token` (ON CONFLICT
--    (token)) to perform the reassignment.
-- 2. feedback.type persists the client's classification (STATUS bug #20). The
--    driver safety surface sends {"type":"app_issue","message":...}; before
--    this column the kind was silently dropped.
--
-- Append-only: this migration is additive and safe on a reused volume. The
-- table had no application writer before this change, so it is empty in
-- practice; the DELETE is a defensive no-op for any volume that somehow has
-- duplicate rows (it keeps the newest row per token, id as a tie-breaker).

DELETE FROM device_tokens a
USING device_tokens b
WHERE a.token = b.token
  AND (
        a.updated_at < b.updated_at
        OR (a.updated_at = b.updated_at AND a.id < b.id)
      );

CREATE UNIQUE INDEX IF NOT EXISTS idx_device_tokens_token
    ON device_tokens(token);

ALTER TABLE feedback
    ADD COLUMN IF NOT EXISTS type TEXT NOT NULL DEFAULT '';
