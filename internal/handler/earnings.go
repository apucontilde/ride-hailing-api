package handler

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/repository"
)

// EarningsHandler serves the driver earnings ledger endpoints
// (api_plans/[payout]_driver_earnings_and_withdraw.md). The response shapes
// are a CROSS-APP CONTRACT with driver_app_plans/01_[payout]_withdraw_ui.md —
// change them only with a coordinated client change.
//
// Every money field on these endpoints is INTEGER CENTS (the *_cents keys).
// That is the documented exception to the ride JSON's major-units rule: the
// client converts once at render time (formatCents(cents/100)).
type EarningsHandler struct {
	earnings repository.EarningsRepository
	// minWithdrawCents is PAYOUT_MIN_WITHDRAW_CENTS; a non-positive amount or
	// one below this floor is 422. The zero value disables nothing: the
	// amount > 0 check still applies.
	minWithdrawCents int64
}

// NewEarningsHandler wires the ledger store and the withdrawal floor. The
// constructor never dereferences repo, so a db-less harness (cmd/openapi)
// with a nil store stays buildable; the handlers fail closed with a 5xx
// rather than panicking if such a route is ever invoked.
func NewEarningsHandler(earnings repository.EarningsRepository, minWithdrawCents int64) *EarningsHandler {
	return &EarningsHandler{earnings: earnings, minWithdrawCents: minWithdrawCents}
}

// GetEarnings godoc
//
//	@Summary		Get the driver's earnings summary
//	@Description	Returns the ledger-derived earnings summary in INTEGER CENTS. A driver with no earnings gets a zeroed summary, never a 404.
//	@Tags			driver
//	@Produce		json
//	@Security		BearerAuth
//	@Success		200	{object}	map[string]any	"{"earnings":{available_cents,pending_cents,withdrawn_cents,lifetime_cents,currency,month_total_cents,month_trips,completed_trips,months:[...]}}"
//	@Failure		500	{object}	ErrorResponse	"Earnings store unavailable"
//	@Router			/api/v1/driver/me/earnings [get]
func (h *EarningsHandler) GetEarnings(c *gin.Context) {
	if h.earnings == nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to load earnings",
			errors.New("earnings repository not wired"))
		return
	}
	userID, _ := c.Get("user_id")
	summary, err := h.earnings.GetEarningsSummary(userID.(string))
	if err != nil {
		respondRepo(c, err, "", "", "failed to load earnings")
		return
	}
	c.JSON(http.StatusOK, gin.H{"earnings": summary})
}

// withdrawRequest binds the only body field. A pointer distinguishes an
// absent field (nil → 422) from a literal 0 (non-nil → 422 by the > 0 rule);
// a non-integer value fails bindJSON's decode as a malformed body (400).
type withdrawRequest struct {
	AmountCents *int64 `json:"amount_cents"`
}

// Withdraw godoc
//
//	@Summary		Request a withdrawal
//	@Description	Records a PENDING ledger debit in integer cents — not a bank transfer; no external payout provider is wired. Idempotent per Idempotency-Key. Amount must be > 0 and >= PAYOUT_MIN_WITHDRAW_CENTS (422) and <= the available balance (409).
//	@Tags			driver
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			Idempotency-Key	header		string			false	"Recommended: replay-safe key for this withdrawal attempt"
//	@Param			body			body		object			true	"{"amount_cents": N} (integer cents)"
//	@Success		200				{object}	map[string]any	"{"withdrawal":{ledger row, status pending},"earnings":{updated summary}}"
//	@Failure		400				{object}	ErrorResponse	"Malformed request body"
//	@Failure		422				{object}	ErrorResponse	"Validation error (amount_cents missing, non-positive, or below the minimum)"
//	@Failure		409				{object}	ErrorResponse	"Insufficient balance"
//	@Failure		500				{object}	ErrorResponse	"Earnings store unavailable"
//	@Router			/api/v1/driver/earnings/withdraw [post]
func (h *EarningsHandler) Withdraw(c *gin.Context) {
	if h.earnings == nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to create withdrawal",
			errors.New("earnings repository not wired"))
		return
	}
	userID, _ := c.Get("user_id")

	var body withdrawRequest
	if !bindJSON(c, &body, "") {
		return
	}
	if body.AmountCents == nil {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR",
			"Amount cents is required", nil)
		return
	}
	amount := *body.AmountCents
	if amount <= 0 {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR",
			"Amount cents must be greater than zero", nil)
		return
	}
	if amount < h.minWithdrawCents {
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR",
			fmt.Sprintf("Minimum withdrawal is %d cents", h.minWithdrawCents), nil)
		return
	}

	// Read the key from the HEADER, not the middleware's context value: with
	// a nil idempotency store (db-less harnesses) middleware.Idempotency
	// bypasses without c.Set, yet the ledger's per-(driver, key) dedup must
	// still see the key to prevent a double debit. In production both reads
	// return the same value (the middleware sets the context from this header
	// after its own replay check).
	idempotencyKey := c.GetHeader("Idempotency-Key")

	withdrawal, summary, err := h.earnings.CreateWithdrawal(userID.(string), amount, idempotencyKey)
	if err != nil {
		// A conflict from the in-lock balance re-check is the client-actionable
		// "insufficient balance"; anything else is an outage (5xx) — a failed
		// money write never answers success.
		respondRepo(c, err, "", "insufficient balance", "failed to create withdrawal")
		return
	}
	c.JSON(http.StatusOK, gin.H{"withdrawal": withdrawal, "earnings": summary})
}
