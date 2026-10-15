package repository

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

// EarningsRepository is the driver earnings ledger (api_plans/
// [payout]_driver_earnings_and_withdraw.md). Money writes here are NEVER
// best-effort: a failed credit or withdrawal is an error the caller must turn
// into a 5xx (api_plans/STATUS.md Invariants — a failed write never answers
// success). Mocks in tests/testutil move in lockstep with this interface.
type EarningsRepository interface {
	// CreditRideEarning inserts a ride_earning credit for a completed ride.
	// The partial unique index on ride_id (kind='ride_earning') makes a retry
	// a NO-OP rather than a double credit. A non-positive amountCents is
	// likewise a no-op: the ledger CHECK forbids zero, and there is nothing to
	// credit.
	CreditRideEarning(driverID, rideID string, amountCents int64) error
	// GetEarningsSummary aggregates the driver's ledger. A driver with no
	// rows gets a ZEROED summary, never ErrNotFound — "no earnings yet" is a
	// valid state, not a missing resource.
	GetEarningsSummary(driverID string) (*model.EarningsSummary, error)
	// CreateWithdrawal records a pending withdrawal debit inside a
	// transaction serialised per driver (pg_advisory_xact_lock), re-checking
	// the available balance INSIDE the lock so concurrent withdrawals cannot
	// overdraw. amountCents > available is ErrConflict ("insufficient
	// balance"). A non-empty idempotencyKey that already created a withdrawal
	// returns that first row (and no second debit), so a replayed
	// Idempotency-Key is safe even with the replay middleware disabled.
	CreateWithdrawal(driverID string, amountCents int64, idempotencyKey string) (*model.DriverEarning, *model.EarningsSummary, error)
}

var _ EarningsRepository = (*EarningsRepo)(nil)

// EarningsRepo is the Postgres implementation.
type EarningsRepo struct {
	db *sqlx.DB
	// currency is stamped on every row this repo writes (PAYOUT_CURRENCY) and
	// echoed on the summary; the ledger holds one currency by design.
	currency string
}

// NewEarningsRepo builds the ledger store. An empty currency falls back to
// "USD" — the same documented default PAYOUT_CURRENCY ships with.
func NewEarningsRepo(db *sqlx.DB, currency string) *EarningsRepo {
	if currency == "" {
		currency = "USD"
	}
	return &EarningsRepo{db: db, currency: currency}
}

const earningColumns = `id, driver_id, ride_id, kind, amount_cents, status,
	currency, idempotency_key, created_at, updated_at`

// withdrawalCountedExpr is the ONE predicate that decides which withdrawal
// debits occupy balance. Both availableBalanceExpr and the summary's
// withdrawn_cents use it verbatim, so the balance and the reported withdrawn
// total can never disagree.
//
// The invariant (api_plans/STATUS.md [payout]):
//
//	available = lifetime_cents − withdrawn_total
//
// where withdrawn_total counts every withdrawal the money has actually left
// for — status 'pending' (requested, reserved) AND 'paid' (settled). This is
// the double-payout guard: when ops moves a withdrawal pending → paid, the
// debit MUST keep reducing the balance; if it dropped out of the sum, the
// balance would inflate back to full and the same earnings could be withdrawn
// twice. A 'failed' or 'reversed' withdrawal never left (or was returned to)
// the driver, so it is excluded and the balance is restored automatically.
const withdrawalCountedExpr = `kind = 'withdrawal' AND status IN ('pending','paid')`

// availableBalanceExpr is THE definition of the withdrawable balance, used by
// both the summary and the in-lock re-check so they cannot drift: available
// credits plus every counted withdrawal debit (withdrawalCountedExpr — the
// debits are negative, so they reduce the balance).
const availableBalanceExpr = `COALESCE(SUM(amount_cents) FILTER (
	WHERE status = 'available' OR (` + withdrawalCountedExpr + `)), 0)`

func (r *EarningsRepo) CreditRideEarning(driverID, rideID string, amountCents int64) error {
	if amountCents <= 0 {
		// Nothing to credit (zero fare, or a fully-commissioned ride): the
		// ledger CHECK forbids amount_cents = 0, and inventing a row would be
		// fabricating money.
		return nil
	}
	_, err := r.db.Exec(`
		INSERT INTO driver_earnings (driver_id, ride_id, kind, amount_cents, status, currency)
		VALUES ($1, $2, 'ride_earning', $3, 'available', $4)
		ON CONFLICT (ride_id) WHERE kind = 'ride_earning' DO NOTHING`,
		driverID, rideID, amountCents, r.currency)
	if err != nil {
		return wrapDB("credit ride earning", err)
	}
	return nil
}

func (r *EarningsRepo) GetEarningsSummary(driverID string) (*model.EarningsSummary, error) {
	return r.summary(r.db, driverID, time.Now().UTC())
}

// querier is the read seam shared by the standalone summary and the one read
// inside the withdrawal transaction, so both run the identical SQL.
type querier interface {
	Get(dest any, query string, args ...any) error
	Select(dest any, query string, args ...any) error
}

// summary aggregates the ledger through one conditional SELECT plus a monthly
// GROUP BY. now is UTC because the month buckets are UTC: the bucket key is
// to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM') — pinned, not dependent
// on the Postgres session TimeZone — and the ledger has no region linkage to
// resolve an IANA zone.
func (r *EarningsRepo) summary(q querier, driverID string, now time.Time) (*model.EarningsSummary, error) {
	s := &model.EarningsSummary{Currency: r.currency, Months: []model.EarningsMonth{}}
	err := q.Get(s, `
		SELECT
			`+availableBalanceExpr+`                        AS available_cents,
			COALESCE(SUM(amount_cents) FILTER (
				WHERE status = 'pending' AND kind <> 'withdrawal'), 0) AS pending_cents,
			COALESCE(-SUM(amount_cents) FILTER (
				WHERE `+withdrawalCountedExpr+`), 0)               AS withdrawn_cents,
			COALESCE(SUM(amount_cents) FILTER (
				WHERE kind IN ('ride_earning','tip','adjustment')), 0) AS lifetime_cents,
			COUNT(*) FILTER (WHERE kind = 'ride_earning')   AS completed_trips
		FROM driver_earnings
		WHERE driver_id = $1`, driverID)
	if err != nil {
		return nil, wrapDB("load earnings summary", err)
	}
	if err := q.Select(&s.Months, `
		SELECT to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM') AS month,
		       SUM(amount_cents)              AS total_cents,
		       COUNT(*) FILTER (WHERE kind = 'ride_earning') AS trips
		FROM driver_earnings
		WHERE driver_id = $1 AND kind IN ('ride_earning','tip','adjustment')
		GROUP BY 1
		ORDER BY 1 DESC`, driverID); err != nil {
		return nil, wrapDB("load earnings months", err)
	}
	// The current month's totals: present in Months only when the driver has
	// credit rows this month; otherwise honest zeros.
	monthPrefix := now.Format("2006-01")
	for _, m := range s.Months {
		if m.Month == monthPrefix {
			s.MonthTotalCents = m.TotalCents
			s.MonthTrips = m.Trips
			break
		}
	}
	return s, nil
}

func (r *EarningsRepo) CreateWithdrawal(driverID string, amountCents int64, idempotencyKey string) (*model.DriverEarning, *model.EarningsSummary, error) {
	tx, err := r.db.Beginx()
	if err != nil {
		return nil, nil, wrapDB("begin withdrawal transaction", err)
	}
	defer func() { _ = tx.Rollback() }()

	// One withdrawal at a time per driver. The advisory lock is transaction-
	// scoped, so it is released on commit or rollback and needs no explicit
	// unlock; hashtextextended maps the driver UUID to a bigint key.
	if _, lerr := tx.Exec(`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, driverID); lerr != nil {
		return nil, nil, wrapDB("lock driver for withdrawal", lerr)
	}

	// Replay check INSIDE the lock: a retried Idempotency-Key must return the
	// first withdrawal and must not debit again (the unique index in migration
	// 024 is the backstop if this check ever races itself).
	if idempotencyKey != "" {
		existing := &model.DriverEarning{}
		kerr := tx.Get(existing, `
			SELECT `+earningColumns+`
			FROM driver_earnings
			WHERE driver_id = $1 AND kind = 'withdrawal' AND idempotency_key = $2
			ORDER BY created_at
			LIMIT 1`, driverID, idempotencyKey)
		switch {
		case kerr == nil:
			summary, serr := r.summary(tx, driverID, time.Now().UTC())
			if serr != nil {
				return nil, nil, serr
			}
			if cerr := tx.Commit(); cerr != nil {
				return nil, nil, wrapDB("commit withdrawal replay", cerr)
			}
			return existing, summary, nil
		case !errors.Is(kerr, sql.ErrNoRows):
			return nil, nil, wrapDB("check withdrawal idempotency key", kerr)
		}
	}

	// Re-check the balance INSIDE the lock: whatever the balance was when the
	// request started, this is the number that matters.
	var available int64
	if berr := tx.Get(&available, `
		SELECT `+availableBalanceExpr+`
		FROM driver_earnings
		WHERE driver_id = $1`, driverID); berr != nil {
		return nil, nil, wrapDB("load available balance for withdrawal", berr)
	}
	if amountCents > available {
		return nil, nil, fmt.Errorf(
			"insufficient balance: requested %d cents, available %d: %w",
			amountCents, available, ErrConflict)
	}

	withdrawal := &model.DriverEarning{}
	err = tx.Get(withdrawal, `
		INSERT INTO driver_earnings (driver_id, kind, amount_cents, status, currency, idempotency_key)
		VALUES ($1, 'withdrawal', $2, 'pending', $3, $4)
		RETURNING `+earningColumns,
		driverID, -amountCents, r.currency, idempotencyKey)
	if err != nil {
		return nil, nil, wrapDB("insert withdrawal", err)
	}

	summary, serr := r.summary(tx, driverID, time.Now().UTC())
	if serr != nil {
		return nil, nil, serr
	}
	if err := tx.Commit(); err != nil {
		return nil, nil, wrapDB("commit withdrawal", err)
	}
	return withdrawal, summary, nil
}
