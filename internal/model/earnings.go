package model

import "time"

// DriverEarning is one row of the driver earnings ledger
// (api_plans/[payout]_driver_earnings_and_withdraw.md, migration 024). The
// ledger is the wallet: credits are positive, debits negative, everything is
// integer cents — there is no float money and no balance column.
type DriverEarning struct {
	ID       string  `db:"id" json:"id"`
	DriverID string  `db:"driver_id" json:"driver_id"`
	RideID   *string `db:"ride_id" json:"ride_id"`
	// Kind is ride_earning | tip | adjustment | withdrawal.
	Kind string `db:"kind" json:"kind"`
	// AmountCents: credit +, debit -. A withdrawal debit is inserted
	// negative with status "pending".
	AmountCents int64  `db:"amount_cents" json:"amount_cents"`
	Status      string `db:"status" json:"status"`
	Currency    string `db:"currency" json:"currency"`
	// IdempotencyKey is the Idempotency-Key header the withdrawal was created
	// under (empty for credits). It is internal bookkeeping — never echoed to
	// a client.
	IdempotencyKey string    `db:"idempotency_key" json:"-"`
	CreatedAt      time.Time `db:"created_at" json:"created_at"`
	UpdatedAt      time.Time `db:"updated_at" json:"updated_at"`
}

// EarningsMonth is one "YYYY-MM" bucket of the ledger's credit rows, newest
// first in the summary's months list.
type EarningsMonth struct {
	Month      string `db:"month" json:"month"`
	TotalCents int64  `db:"total_cents" json:"total_cents"`
	Trips      int    `db:"trips" json:"trips"`
}

// EarningsSummary is the GET /driver/me/earnings payload (envelope key
// "earnings") and the "earnings" half of the withdraw response. Every money
// field is integer cents — these endpoints are the documented exception to the
// ride JSON's major-units rule; the client converts once at render time.
//
// Semantics (single source of truth = the ledger):
//   - AvailableCents is the withdrawable balance: available credits minus
//     pending withdrawal debits. A failed/reversed withdrawal debit drops out
//     of the sum, so the balance is restored automatically.
//   - PendingCents is pending CREDIT (money not yet available to withdraw).
//   - WithdrawnCents is the gross of pending+paid withdrawal debits.
//   - LifetimeCents is the gross of every credit row ever (kind
//     ride_earning/tip/adjustment).
//   - Month*/Months bucket the credit rows by created_at in UTC.
type EarningsSummary struct {
	AvailableCents  int64           `db:"available_cents" json:"available_cents"`
	PendingCents    int64           `db:"pending_cents" json:"pending_cents"`
	WithdrawnCents  int64           `db:"withdrawn_cents" json:"withdrawn_cents"`
	LifetimeCents   int64           `db:"lifetime_cents" json:"lifetime_cents"`
	Currency        string          `db:"currency" json:"currency"`
	MonthTotalCents int64           `db:"month_total_cents" json:"month_total_cents"`
	MonthTrips      int             `db:"month_trips" json:"month_trips"`
	CompletedTrips  int             `db:"completed_trips" json:"completed_trips"`
	Months          []EarningsMonth `json:"months"`
}
