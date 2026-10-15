-- 024_driver_earnings.up.sql
--
-- Driver earnings ledger (api_plans/[payout]_driver_earnings_and_withdraw.md).
-- The ledger IS the wallet: there is no balance column anywhere. Available
-- balance is SUM(amount_cents) over the rows the summary query deems available
-- (see internal/repository/earnings_repo.go), so credit and debit can never
-- drift apart from a cached total. Amounts are integer cents — credits are
-- positive, debits negative; the float64 ride fare is converted ONCE at credit
-- time. `status` on a withdrawal debit is 'pending' by design: a withdrawal is
-- a RECORDED LEDGER DEBIT, not a bank transfer (no external payout provider
-- exists in this plan); an ops/provider step later moves 'pending' -> 'paid'.

CREATE TABLE driver_earnings (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    driver_id       UUID        NOT NULL REFERENCES drivers(user_id),
    ride_id         UUID        REFERENCES rides(id),
    kind            TEXT        NOT NULL CHECK (kind IN ('ride_earning','tip','adjustment','withdrawal')),
    amount_cents    BIGINT      NOT NULL CHECK (amount_cents <> 0),   -- credit +, debit -
    status          TEXT        NOT NULL DEFAULT 'available'
                                CHECK (status IN ('available','pending','paid','failed','reversed')),
    currency        TEXT        NOT NULL DEFAULT 'USD',
    idempotency_key TEXT        NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_driver_earnings_driver ON driver_earnings(driver_id, status, created_at);
CREATE UNIQUE INDEX idx_driver_earnings_ride_earning ON driver_earnings(ride_id)
    WHERE kind = 'ride_earning';   -- double-credit guard

-- Withdrawal idempotency at the DATABASE level (an addition to the plan's
-- base schema, not a change to it): the Idempotency-Key middleware replays a
-- stored response, but a key that reaches CreateWithdrawal twice anyway (e.g.
-- with the middleware disabled in a db-less harness, or a store outage) must
-- never double-debit. The repository checks this row inside the per-driver
-- advisory lock; the unique index makes the guarantee survive even that check
-- racing itself.
CREATE UNIQUE INDEX idx_driver_earnings_withdrawal_key
    ON driver_earnings(driver_id, idempotency_key)
    WHERE kind = 'withdrawal' AND idempotency_key <> '';
