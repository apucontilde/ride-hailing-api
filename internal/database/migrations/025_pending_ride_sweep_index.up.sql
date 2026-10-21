-- api_plans/[rides]_orphaned_pending_expiry.md D8: bound the pending-only
-- sweep and read guard (`status = 'pending' AND created_at < cutoff`).
-- Correctness does not depend on this index; it keeps both queries bounded.
-- Documentation only; the runner executes *.up.sql.
CREATE INDEX IF NOT EXISTS idx_rides_pending_created
    ON rides (created_at)
    WHERE status = 'pending';
