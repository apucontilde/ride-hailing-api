-- 017_idempotency_key_scoping.down.sql
-- Documentation only: the runner executes only *.up.sql (migrate.go).
--
-- Reverting #18 cannot restore every row: the global `key` PK is what the
-- composite constraint replaced, and two users may now hold the same key. Keep
-- the earliest row per key and drop the rest before restoring the PK.

ALTER TABLE idempotency_keys
    DROP CONSTRAINT IF EXISTS idempotency_keys_key_user_id_key;

DELETE FROM idempotency_keys doomed
USING idempotency_keys keep
WHERE doomed.key = keep.key
  AND (doomed.created_at > keep.created_at
       OR (doomed.created_at = keep.created_at AND doomed.ctid > keep.ctid));

ALTER TABLE idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (key);

ALTER TABLE idempotency_keys
    DROP COLUMN IF EXISTS response_content_type;
