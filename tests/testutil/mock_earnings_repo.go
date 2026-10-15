package testutil

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// MockEarningsRepo is the in-memory driver earnings ledger for the db-less
// harnesses (tests/testutil, cmd/e2eserver). It mirrors
// internal/repository/earnings_repo.go's semantics exactly — including the
// per-driver serialised withdrawal, the in-lock balance re-check, the
// idempotency-key replay and the no-404 zeroed summary — so a contract test
// here means the same thing the DB-backed suite proves.
type MockEarningsRepo struct {
	mu       sync.Mutex
	rows     []model.DriverEarning
	currency string

	// failNext, when set, is returned by the next repository call (any
	// method) and then cleared — the lockstep rule that a mock must be able
	// to return the failures its production counterpart can.
	failNext error
}

func NewMockEarningsRepo() *MockEarningsRepo {
	return &MockEarningsRepo{currency: "USD"}
}

// SetFailNext makes the next repository call fail (e.g. with a database
// outage) so a handler's 5xx path is reachable without a database.
func (m *MockEarningsRepo) SetFailNext(err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.failNext = err
}

// Credit seeds or credits a ride earning through the same entry point the
// ride service uses; a duplicate rideID is a no-op, like the partial unique
// index.
func (m *MockEarningsRepo) Credit(driverID, rideID string, amountCents int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	_ = m.creditLocked(driverID, rideID, amountCents)
}

// Available is the test-facing withdrawable balance (mirrors
// availableBalanceExpr).
func (m *MockEarningsRepo) Available(driverID string) int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.availableLocked(driverID)
}

// Rows returns a copy of a driver's ledger rows, oldest first.
func (m *MockEarningsRepo) Rows(driverID string) []model.DriverEarning {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []model.DriverEarning
	for _, row := range m.rows {
		if row.DriverID == driverID {
			out = append(out, row)
		}
	}
	return out
}

func (m *MockEarningsRepo) takeFailLocked() error {
	err := m.failNext
	m.failNext = nil
	return err
}

func (m *MockEarningsRepo) creditLocked(driverID, rideID string, amountCents int64) error {
	if amountCents <= 0 {
		return nil
	}
	for _, row := range m.rows {
		if row.RideID != nil && *row.RideID == rideID && row.Kind == "ride_earning" {
			return nil // ON CONFLICT DO NOTHING
		}
	}
	now := time.Now()
	rideIDCopy := rideID
	m.rows = append(m.rows, model.DriverEarning{
		ID:          newID(),
		DriverID:    driverID,
		RideID:      &rideIDCopy,
		Kind:        "ride_earning",
		AmountCents: amountCents,
		Status:      "available",
		Currency:    m.currency,
		CreatedAt:   now,
		UpdatedAt:   now,
	})
	return nil
}

// availableLocked mirrors availableBalanceExpr / withdrawalCountedExpr
// (internal/repository/earnings_repo.go): available credits plus every
// COUNTED withdrawal debit — status pending (reserved) or paid (settled).
// The paid case is the double-payout guard: a withdrawal that ops settles
// pending → paid must keep reducing the balance.
func (m *MockEarningsRepo) availableLocked(driverID string) int64 {
	var sum int64
	for _, row := range m.rows {
		if row.DriverID != driverID {
			continue
		}
		if row.Status == "available" || (row.Kind == "withdrawal" && (row.Status == "pending" || row.Status == "paid")) {
			sum += row.AmountCents
		}
	}
	return sum
}

// SetWithdrawalStatus moves a withdrawal row to a post-settlement status
// ('paid', 'failed', 'reversed'), playing the ops/provider step
// RIDER_API_GUIDE.md documents. It is the test-facing seam the DB suite gets
// from a raw UPDATE; an unknown (driverID, idempotencyKey) pair is an error so
// a test can never silently pin the wrong row. Withdrawals created without a
// key are addressed by their id (pass the row ID as idempotencyKey).
func (m *MockEarningsRepo) SetWithdrawalStatus(driverID, key, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.rows {
		row := &m.rows[i]
		if row.DriverID != driverID || row.Kind != "withdrawal" {
			continue
		}
		if row.IdempotencyKey == key || row.ID == key {
			row.Status = status
			row.UpdatedAt = time.Now()
			return nil
		}
	}
	return fmt.Errorf("no withdrawal for driver %s with key/id %q", driverID, key)
}

func (m *MockEarningsRepo) CreditRideEarning(driverID, rideID string, amountCents int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.takeFailLocked(); err != nil {
		return fmt.Errorf("credit ride earning: %w", err)
	}
	return m.creditLocked(driverID, rideID, amountCents)
}

func (m *MockEarningsRepo) GetEarningsSummary(driverID string) (*model.EarningsSummary, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.takeFailLocked(); err != nil {
		return nil, fmt.Errorf("load earnings summary: %w", err)
	}
	return m.summaryLocked(driverID, time.Now().UTC()), nil
}

func (m *MockEarningsRepo) CreateWithdrawal(driverID string, amountCents int64, idempotencyKey string) (*model.DriverEarning, *model.EarningsSummary, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.takeFailLocked(); err != nil {
		return nil, nil, fmt.Errorf("insert withdrawal: %w", err)
	}

	// Replay: the first withdrawal for this key, no second debit.
	if idempotencyKey != "" {
		for i := range m.rows {
			row := &m.rows[i]
			if row.DriverID == driverID && row.Kind == "withdrawal" && row.IdempotencyKey == idempotencyKey {
				cp := *row
				return &cp, m.summaryLocked(driverID, time.Now().UTC()), nil
			}
		}
	}

	// The mutex is the advisory lock here: the balance re-check below is the
	// in-lock check.
	if amountCents > m.availableLocked(driverID) {
		return nil, nil, fmt.Errorf(
			"insufficient balance: requested %d cents, available %d: %w",
			amountCents, m.availableLocked(driverID), repository.ErrConflict)
	}

	now := time.Now()
	row := model.DriverEarning{
		ID:             newID(),
		DriverID:       driverID,
		Kind:           "withdrawal",
		AmountCents:    -amountCents,
		Status:         "pending",
		Currency:       m.currency,
		IdempotencyKey: idempotencyKey,
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	m.rows = append(m.rows, row)
	return &row, m.summaryLocked(driverID, now.UTC()), nil
}

func (m *MockEarningsRepo) summaryLocked(driverID string, now time.Time) *model.EarningsSummary {
	s := &model.EarningsSummary{Currency: m.currency, Months: []model.EarningsMonth{}}
	monthTotals := map[string]*model.EarningsMonth{}
	for _, row := range m.rows {
		if row.DriverID != driverID {
			continue
		}
		if row.Status == "available" || (row.Kind == "withdrawal" && (row.Status == "pending" || row.Status == "paid")) {
			s.AvailableCents += row.AmountCents
		}
		if row.Status == "pending" && row.Kind != "withdrawal" {
			s.PendingCents += row.AmountCents
		}
		if row.Kind == "withdrawal" && (row.Status == "pending" || row.Status == "paid") {
			s.WithdrawnCents -= row.AmountCents
		}
		if row.Kind == "ride_earning" || row.Kind == "tip" || row.Kind == "adjustment" {
			s.LifetimeCents += row.AmountCents
			month := row.CreatedAt.UTC().Format("2006-01")
			mBucket, ok := monthTotals[month]
			if !ok {
				mBucket = &model.EarningsMonth{Month: month}
				monthTotals[month] = mBucket
			}
			mBucket.TotalCents += row.AmountCents
			if row.Kind == "ride_earning" {
				s.CompletedTrips++
				mBucket.Trips++
			}
		}
	}
	for _, bucket := range monthTotals {
		s.Months = append(s.Months, *bucket)
	}
	sort.Slice(s.Months, func(i, j int) bool { return s.Months[i].Month > s.Months[j].Month })
	monthPrefix := now.Format("2006-01")
	for _, bucket := range s.Months {
		if bucket.Month == monthPrefix {
			s.MonthTotalCents = bucket.TotalCents
			s.MonthTrips = bucket.Trips
			break
		}
	}
	return s
}
