-- Documentation only: the runner executes *.up.sql exclusively.
DROP INDEX IF EXISTS idx_device_tokens_token;

ALTER TABLE feedback DROP COLUMN IF EXISTS type;
