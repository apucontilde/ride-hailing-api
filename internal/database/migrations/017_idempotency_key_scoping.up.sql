-- 017_idempotency_key_scoping.up.sql
-- Two idempotency bugs (api_plans/STATUS.md known bugs #17/#18):
--
-- #17  A replay was always written as JSON, so a non-JSON response (e.g.
--      Content-Type: text/plain) came back JSON-quoted. Faithful replay needs
--      the original Content-Type, recorded here per stored response. The body
--      column stays JSONB; the middleware unwraps the JSON-string form the
--      body takes for non-JSON content types when it replays.
--
-- #18  `key` was a bare PRIMARY KEY, so it was not user-scoped: two users
--      reusing the same key collided, and the second user's insert was dropped
--      by ON CONFLICT DO NOTHING, silently disabling idempotency for them.
--      Replace the global PK with UNIQUE(key, user_id) after deterministically
--      resolving any pre-existing (key, user_id) duplicates.
--
-- Append-only and re-runnable: every statement is guarded or idempotent, so an
-- interrupted multi-statement exec (migrate.go is non-atomic) re-converges.
-- Do NOT wrap in BEGIN.

-- A response stored before this migration was always replayed as JSON, so that
-- is the honest default for the historical rows.
ALTER TABLE idempotency_keys
    ADD COLUMN IF NOT EXISTS response_content_type TEXT;

UPDATE idempotency_keys
   SET response_content_type = 'application/json'
 WHERE response_content_type IS NULL;

ALTER TABLE idempotency_keys
    ALTER COLUMN response_content_type SET NOT NULL;

-- Drop the global key PK first: it is the thing that makes two users collide,
-- and dropping it also un-blocks the duplicate resolution below.
ALTER TABLE idempotency_keys
    DROP CONSTRAINT IF EXISTS idempotency_keys_pkey;

-- Resolve (key, user_id) duplicates deterministically, keeping the earliest
-- created_at and breaking ties by physical row order (ctid). On the original
-- schema `key` was globally unique, so this matches nothing; it matters for a
-- volume where the PK was already dropped, and it makes re-running safe.
DELETE FROM idempotency_keys doomed
USING idempotency_keys keep
WHERE doomed.key = keep.key
  AND doomed.user_id = keep.user_id
  AND (doomed.created_at > keep.created_at
       OR (doomed.created_at = keep.created_at AND doomed.ctid > keep.ctid));

ALTER TABLE idempotency_keys
    ALTER COLUMN key SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'idempotency_keys'::regclass
          AND conname = 'idempotency_keys_key_user_id_key'
    ) THEN
        ALTER TABLE idempotency_keys
            ADD CONSTRAINT idempotency_keys_key_user_id_key UNIQUE (key, user_id);
    END IF;
END $$;

COMMENT ON COLUMN idempotency_keys.response_content_type IS
    'Content-Type the handler wrote, replayed verbatim (bug #17). application/json for pre-017 rows.';
