/// Driver-app mirror of the API's documented `PAYOUT_MIN_WITHDRAW_CENTS`
/// default (`api_plans/[payout]_driver_earnings_and_withdraw.md`; server
/// default `DefaultPayoutMinWithdrawCents = 500` in `internal/config/config.go`).
///
/// ⚠️ This is a **pre-submit hint only**. The server is authoritative: a
/// deployment that changes `PAYOUT_MIN_WITHDRAW_CENTS` makes this constant
/// stale, and the divergence surfaces as the server's own `422 VALIDATION_ERROR`
/// `message`, which the sheet renders verbatim. A non-blocking api follow-up is
/// to expose the minimum in the earnings summary so this mirror can be retired.
const int payoutMinWithdrawCents = 500;
