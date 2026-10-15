//go:build integration

package repository

// DB-backed proofs for the driver earnings ledger (api_plans/
// [payout]_driver_earnings_and_withdraw.md). What a mock cannot prove lives
// here: the real CHECK/unique constraints of migration 024, the
// advisory-locked balance re-check under genuine multi-connection contention,
// and the month-bucket SQL running against a real Postgres.
//
// Two connection strategies, deliberately:
//
//   - TestEarningsRepoIntegration follows the suite convention (TEMP table +
//     SetMaxOpenConns(1)); everything is sequential and one connection sees
//     the TEMP table.
//   - TestEarningsRepoConcurrentWithdrawal CANNOT use that convention: with a
//     single pooled connection the pool serialises the goroutines before any
//     advisory lock is ever taken, so the test would prove nothing. It runs a
//     per-test SCHEMA through the search_path startup GUC instead, so a
//     non-TEMP table is visible on every pooled connection and the lock is
//     actually contended.

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

// Ledger fixture UUIDs: fixed, valid, and reserved for this file so a stray
// leak (there should be none — the primary suite's table is TEMP) cannot
// collide with dev rows.
const (
	earningsITDriver = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	earningsITRide   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
)

// TestEarningsRepoIntegration runs the repository against migration 024's
// real constraints (as shadowed by the TEMP DDL in testdb) and pins the
// summary semantics the HTTP contract depends on.
func TestEarningsRepoIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1) // TEMP tables must stay visible to every repo query
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS driver_earnings") })
	createDriverEarningsTable(t, db)

	repo := NewEarningsRepo(db, "USD")

	// 1. A driver with no rows gets a ZEROED summary, never ErrNotFound.
	s, err := repo.GetEarningsSummary(earningsITDriver)
	if err != nil {
		t.Fatalf("empty summary: %v", err)
	}
	if s.AvailableCents != 0 || s.LifetimeCents != 0 || s.CompletedTrips != 0 {
		t.Errorf("empty summary = %+v, want zeros", s)
	}
	if s.Currency != "USD" {
		t.Errorf("currency = %q, want USD", s.Currency)
	}
	if len(s.Months) != 0 {
		t.Errorf("months = %+v, want empty", s.Months)
	}

	// 2. A credit lands and aggregates; completed_trips counts ride_earning.
	if err := repo.CreditRideEarning(earningsITDriver, earningsITRide, 5000); err != nil {
		t.Fatalf("credit: %v", err)
	}
	s, err = repo.GetEarningsSummary(earningsITDriver)
	if err != nil {
		t.Fatalf("summary after credit: %v", err)
	}
	if s.AvailableCents != 5000 || s.LifetimeCents != 5000 || s.MonthTotalCents != 5000 {
		t.Errorf("after credit: available=%d lifetime=%d month_total=%d, want 5000 each",
			s.AvailableCents, s.LifetimeCents, s.MonthTotalCents)
	}
	if s.CompletedTrips != 1 || s.MonthTrips != 1 {
		t.Errorf("trips = %d/%d, want 1/1", s.CompletedTrips, s.MonthTrips)
	}

	// 3. The partial unique index makes a DUPLICATE credit a no-op (the
	// exactly-once credit for one ride).
	if err := repo.CreditRideEarning(earningsITDriver, earningsITRide, 5000); err != nil {
		t.Fatalf("duplicate credit must be a no-op, got error: %v", err)
	}
	s, _ = repo.GetEarningsSummary(earningsITDriver)
	if s.LifetimeCents != 5000 {
		t.Errorf("lifetime after duplicate credit = %d, want 5000", s.LifetimeCents)
	}

	// 4. A non-positive credit is a no-op (the CHECK forbids zero).
	if err := repo.CreditRideEarning(earningsITDriver, "cccccccc-cccc-cccc-cccc-cccccccccccc", 0); err != nil {
		t.Errorf("zero credit must be a no-op, got error: %v", err)
	}

	// 5. A withdrawal is a pending NEGATIVE debit; the summary agrees.
	wd, s, err := repo.CreateWithdrawal(earningsITDriver, 2000, "it-key-1")
	if err != nil {
		t.Fatalf("withdrawal: %v", err)
	}
	if wd.Kind != "withdrawal" || wd.Status != "pending" || wd.AmountCents != -2000 {
		t.Errorf("withdrawal = kind %s / status %s / amount %d, want withdrawal / pending / -2000",
			wd.Kind, wd.Status, wd.AmountCents)
	}
	if wd.Currency != "USD" {
		t.Errorf("withdrawal currency = %q, want USD", wd.Currency)
	}
	if s.AvailableCents != 3000 || s.WithdrawnCents != 2000 {
		t.Errorf("after withdrawal: available=%d withdrawn=%d, want 3000/2000",
			s.AvailableCents, s.WithdrawnCents)
	}
	if s.LifetimeCents != 5000 {
		t.Errorf("withdrawal must not touch lifetime, got %d", s.LifetimeCents)
	}

	// 6. Replaying the Idempotency-Key returns the FIRST withdrawal — same id,
	// no second debit.
	wd2, s2, err := repo.CreateWithdrawal(earningsITDriver, 2000, "it-key-1")
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if wd2.ID != wd.ID {
		t.Errorf("replay id = %s, want the original %s", wd2.ID, wd.ID)
	}
	if s2.AvailableCents != 3000 || s2.WithdrawnCents != 2000 {
		t.Errorf("replay debited again: available=%d withdrawn=%d, want 3000/2000",
			s2.AvailableCents, s2.WithdrawnCents)
	}

	// 7. Over-balance is ErrConflict (the handler's 409), not a generic 500.
	if _, _, err := repo.CreateWithdrawal(earningsITDriver, 100000, "it-key-2"); !errors.Is(err, ErrConflict) {
		t.Errorf("over-balance error = %v, want errors.Is(err, ErrConflict)", err)
	}

	// 8. The withdrawal-key unique index is the DB backstop: a direct
	// duplicate insert (bypassing the repo's in-lock check) must be refused.
	if _, err := db.Exec(`
		INSERT INTO driver_earnings (driver_id, kind, amount_cents, status, idempotency_key)
		VALUES ($1, 'withdrawal', -100, 'pending', 'it-key-1')`, earningsITDriver); err == nil {
		t.Error("duplicate (driver_id, idempotency_key) withdrawal insert must violate the unique index")
	}

	// 9. Month buckets are UTC 'YYYY-MM', newest first, and exclude debits.
	// Backdate an adjustment into the previous month.
	prevMonth := time.Now().UTC().AddDate(0, -1, 0).Format("2006-01-02")
	mustExec(t, db, `
		INSERT INTO driver_earnings (driver_id, kind, amount_cents, status, created_at, updated_at)
		VALUES ($1, 'adjustment', 777, 'available', $2::date + interval '12 hours', NOW())`,
		earningsITDriver, prevMonth)

	s, err = repo.GetEarningsSummary(earningsITDriver)
	if err != nil {
		t.Fatalf("summary with two months: %v", err)
	}
	if len(s.Months) != 2 {
		t.Fatalf("months = %+v, want 2 buckets", s.Months)
	}
	thisMonth := time.Now().UTC().Format("2006-01")
	if s.Months[0].Month != thisMonth || s.Months[1].Month != prevMonth[:7] {
		t.Errorf("months order = %s, %s; want %s (current) first", s.Months[0].Month, s.Months[1].Month, thisMonth)
	}
	if s.Months[1].TotalCents != 777 {
		t.Errorf("previous month total = %d, want 777 (debits must not enter months)", s.Months[1].TotalCents)
	}
	if s.MonthTotalCents != 5000 || s.MonthTrips != 1 {
		t.Errorf("current month = %d/%d, want 5000/1 (the adjustment is in the other bucket)",
			s.MonthTotalCents, s.MonthTrips)
	}
	if s.LifetimeCents != 5777 {
		t.Errorf("lifetime = %d, want 5777 (credits only: 5000+777)", s.LifetimeCents)
	}
}

// TestEarningsRepoPaidWithdrawalKeepsBalanceReduced is the DB-backed half of
// the double-payout guard (api_plans/[payout]). After ops settles a pending
// withdrawal with a raw status UPDATE, availableBalanceExpr and withdrawn_cents
// — both keyed to withdrawalCountedExpr — must still count the debit. Remove
// 'paid' from that predicate and this test goes RED: available inflates back to
// the full credit (10000), because the settled debit drops out of the sum.
//
// The 'reversed' leg pins the complement: a withdrawal that is returned to the
// driver restores the balance automatically.
func TestEarningsRepoPaidWithdrawalKeepsBalanceReduced(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1) // TEMP tables must stay visible to every repo query
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS driver_earnings") })
	createDriverEarningsTable(t, db)

	repo := NewEarningsRepo(db, "USD")

	if err := repo.CreditRideEarning(earningsITDriver, earningsITRide, 10000); err != nil {
		t.Fatalf("credit: %v", err)
	}
	_, s, err := repo.CreateWithdrawal(earningsITDriver, 4000, "paid-it-key")
	if err != nil {
		t.Fatalf("withdrawal: %v", err)
	}
	if s.AvailableCents != 6000 || s.WithdrawnCents != 4000 {
		t.Fatalf("pending: available=%d withdrawn=%d, want 6000/4000", s.AvailableCents, s.WithdrawnCents)
	}

	// Ops settles the withdrawal out of band.
	mustExec(t, db, `UPDATE driver_earnings SET status = 'paid' WHERE idempotency_key = $1`, "paid-it-key")

	s, err = repo.GetEarningsSummary(earningsITDriver)
	if err != nil {
		t.Fatalf("summary after paid: %v", err)
	}
	if s.AvailableCents != 6000 {
		t.Errorf("available after paid = %d, want 6000 (a settled debit must keep reducing the balance)", s.AvailableCents)
	}
	if s.WithdrawnCents != 4000 {
		t.Errorf("withdrawn after paid = %d, want 4000", s.WithdrawnCents)
	}
	if s.LifetimeCents != 10000 {
		t.Errorf("lifetime after paid = %d, want 10000 (settling never touches credits)", s.LifetimeCents)
	}

	// A reversed withdrawal never left the driver: the balance comes back.
	mustExec(t, db, `UPDATE driver_earnings SET status = 'reversed' WHERE idempotency_key = $1`, "paid-it-key")
	s, err = repo.GetEarningsSummary(earningsITDriver)
	if err != nil {
		t.Fatalf("summary after reversed: %v", err)
	}
	if s.AvailableCents != 10000 || s.WithdrawnCents != 0 {
		t.Errorf("after reversed: available=%d withdrawn=%d, want 10000/0",
			s.AvailableCents, s.WithdrawnCents)
	}
}

// TestEarningsRepoConcurrentWithdrawal hammers CreateWithdrawal from N
// goroutines on a multi-connection pool against a balance that funds only M
// of them. The invariant the advisory lock must hold: exactly M withdrawals
// succeed, the rest get ErrConflict, and the available balance is never
// negative.
func TestEarningsRepoConcurrentWithdrawal(t *testing.T) {
	setup := connectPG(t)
	schema := fmt.Sprintf("payout_it_%d", time.Now().UnixNano())
	mustExec(t, setup, "CREATE SCHEMA "+schema)
	t.Cleanup(func() {
		_, _ = setup.Exec("DROP SCHEMA IF EXISTS " + schema + " CASCADE")
	})

	// search_path (schema first for name resolution, public kept for
	// uuid_generate_v4) is a startup GUC pq sends verbatim, so EVERY pooled
	// connection resolves unqualified driver_earnings into this schema — the
	// prerequisite TEMP tables cannot give us here.
	dsn := config.Load().DatabaseURL() + "&search_path=" + schema + ",public"
	pool := connectDSN(t, dsn)
	pool.SetMaxOpenConns(8)

	createDriverEarningsSchema(t, pool)

	repo := NewEarningsRepo(pool, "USD")
	const balance, amount, workers = 1000, 500, 8 // funds exactly 2 of 8

	if err := repo.CreditRideEarning(earningsITDriver, earningsITRide, balance); err != nil {
		t.Fatalf("seed credit: %v", err)
	}

	var wg sync.WaitGroup
	results := make([]error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := repo.CreateWithdrawal(earningsITDriver, amount, fmt.Sprintf("conc-%d", i))
			results[i] = err
		}(i)
	}
	wg.Wait()

	wins := 0
	for i, err := range results {
		switch {
		case err == nil:
			wins++
		case errors.Is(err, ErrConflict):
			// loser
		default:
			t.Errorf("worker %d: unexpected error %v", i, err)
		}
	}
	if wins != balance/amount {
		t.Errorf("wins = %d, want exactly %d (balance funds that many)", wins, balance/amount)
	}

	s, err := repo.GetEarningsSummary(earningsITDriver)
	if err != nil {
		t.Fatalf("final summary: %v", err)
	}
	if s.AvailableCents < 0 {
		t.Errorf("available = %d after concurrent withdrawals, must never go negative", s.AvailableCents)
	}
	if want := int64(balance - wins*amount); s.AvailableCents != want {
		t.Errorf("available = %d, want %d", s.AvailableCents, want)
	}
	if s.WithdrawnCents != int64(wins*amount) {
		t.Errorf("withdrawn = %d, want %d", s.WithdrawnCents, wins*amount)
	}
}

// connectDSN is connectPG with an explicit DSN (the search_path suite needs
// a URL config.Load().DatabaseURL does not carry).
func connectDSN(t *testing.T, dsn string) *sqlx.DB {
	t.Helper()
	db, err := sqlx.Connect("postgres", dsn)
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// createDriverEarningsSchema is createDriverEarningsTable's non-TEMP twin for
// the search_path suite (the TEMP helper in testdb_integration_test.go is the
// single source of truth for the SHAPE; this copy only drops TEMP so the
// table survives across pooled connections — keep them in sync).
func createDriverEarningsSchema(tb testing.TB, db *sqlx.DB) {
	tb.Helper()
	mustExec(tb, db, `CREATE TABLE driver_earnings (
		id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
		driver_id       UUID        NOT NULL,
		ride_id         UUID,
		kind            TEXT        NOT NULL CHECK (kind IN ('ride_earning','tip','adjustment','withdrawal')),
		amount_cents    BIGINT      NOT NULL CHECK (amount_cents <> 0),
		status          TEXT        NOT NULL DEFAULT 'available'
		                    CHECK (status IN ('available','pending','paid','failed','reversed')),
		currency        TEXT        NOT NULL DEFAULT 'USD',
		idempotency_key TEXT        NOT NULL DEFAULT '',
		created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)
	mustExec(tb, db, `CREATE UNIQUE INDEX idx_driver_earnings_ride_earning
		ON driver_earnings(ride_id) WHERE kind = 'ride_earning'`)
	mustExec(tb, db, `CREATE UNIQUE INDEX idx_driver_earnings_withdrawal_key
		ON driver_earnings(driver_id, idempotency_key)
		WHERE kind = 'withdrawal' AND idempotency_key <> ''`)
}
