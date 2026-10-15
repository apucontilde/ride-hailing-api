package tests

// Payout contract tests (api_plans/[payout]_driver_earnings_and_withdraw.md).
// The response shapes asserted here are the CROSS-APP CONTRACT with
// driver_app_plans/01_[payout]_withdraw_ui.md: GET /driver/me/earnings answers
// {"earnings": {...}} (envelope key `earnings`, never `summary`) and every
// money field is INTEGER CENTS.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/gorilla/websocket"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/router"
	"ride-hailing-api/tests/testutil"
)

// driverUserID resolves the ledger's driver_id through the public profile
// (json tag `user_id`) so a test can seed or inspect the ledger directly.
func driverUserID(t *testing.T, driverToken string) string {
	t.Helper()
	resp := ts.DoRequest("GET", "/api/v1/driver/me", driverToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	var out struct {
		Driver struct {
			UserID string `json:"user_id"`
		} `json:"driver"`
	}
	testutil.ParseJSON(t, resp.Body, &out)
	if out.Driver.UserID == "" {
		t.Fatal("driver profile returned an empty user_id")
	}
	return out.Driver.UserID
}

// postWithdraw issues POST /driver/earnings/withdraw with an optional
// Idempotency-Key header — DoRequest has no header parameter, so the payout
// endpoint (the only one keyed by one) goes through net/http directly.
func postWithdraw(t *testing.T, driverToken, idempotencyKey string, body interface{}) *testutil.TestResponse {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshalling withdraw body: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/driver/earnings/withdraw", bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("building withdraw request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	if driverToken != "" {
		req.Header.Set("Authorization", "Bearer "+driverToken)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("withdraw request failed: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(resp.Body); err != nil {
		t.Fatalf("reading withdraw response: %v", err)
	}
	return &testutil.TestResponse{Response: resp, Body: buf.Bytes()}
}

// TestEarningsZeroedSummaryForNewDriver: a driver with no ledger rows gets a
// zeroed 200, never a 404 — an empty wallet is a normal state.
func TestEarningsZeroedSummaryForNewDriver(t *testing.T) {
	token := registerDriver(t, "driver.earn.empty@test.com", "+7991000001")
	resp := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "earnings.available_cents", float64(0))
	resp.AssertJSONHas(t, "earnings.pending_cents", float64(0))
	resp.AssertJSONHas(t, "earnings.withdrawn_cents", float64(0))
	resp.AssertJSONHas(t, "earnings.lifetime_cents", float64(0))
	resp.AssertJSONHas(t, "earnings.completed_trips", float64(0))
	resp.AssertJSONHas(t, "earnings.currency", "USD")
}

// TestEarningsWithdrawValidation covers the 422/400 table of the plan: absent
// amount, non-integer amount, non-positive amount, and below-minimum amount.
func TestEarningsWithdrawValidation(t *testing.T) {
	token := registerDriver(t, "driver.earn.valid@test.com", "+7991000002")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.valid.seed", 10000)

	cases := []struct {
		name       string
		body       interface{}
		wantStatus int
		wantCode   string
	}{
		{"missing amount_cents", map[string]interface{}{}, http.StatusUnprocessableEntity, "VALIDATION_ERROR"},
		{"zero", map[string]interface{}{"amount_cents": 0}, http.StatusUnprocessableEntity, "VALIDATION_ERROR"},
		{"negative", map[string]interface{}{"amount_cents": -100}, http.StatusUnprocessableEntity, "VALIDATION_ERROR"},
		{"below minimum", map[string]interface{}{"amount_cents": 100}, http.StatusUnprocessableEntity, "VALIDATION_ERROR"},
		{"non-integer", map[string]interface{}{"amount_cents": 12.5}, http.StatusBadRequest, "BAD_REQUEST"},
		{"malformed body", "{not json", http.StatusBadRequest, "BAD_REQUEST"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if s, ok := tc.body.(string); ok {
				// Raw malformed body path (not JSON at all).
				req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/driver/earnings/withdraw", bytes.NewReader([]byte(s)))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Authorization", "Bearer "+token)
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatalf("request failed: %v", err)
				}
				defer func() { _ = resp.Body.Close() }()
				if resp.StatusCode != tc.wantStatus {
					t.Errorf("status = %d, want %d", resp.StatusCode, tc.wantStatus)
				}
				return
			}
			resp := postWithdraw(t, token, "valid-"+tc.name, tc.body)
			resp.AssertStatus(t, tc.wantStatus)
			resp.AssertJSONHas(t, "error.code", tc.wantCode)
		})
	}
}

// TestEarningsWithdrawHappyPath pins the success envelope: withdrawal row
// (status pending, NEGATIVE amount_cents — a ledger debit, not a payout) plus
// the refreshed earnings summary.
func TestEarningsWithdrawHappyPath(t *testing.T) {
	token := registerDriver(t, "driver.earn.happy@test.com", "+7991000003")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.happy.1", 5000)
	ts.EarningsRepo.Credit(userID, "ride.happy.2", 5000)

	resp := postWithdraw(t, token, "happy-key-1", map[string]interface{}{"amount_cents": 2000})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "withdrawal.kind", "withdrawal")
	resp.AssertJSONHas(t, "withdrawal.status", "pending")
	resp.AssertJSONHas(t, "withdrawal.amount_cents", float64(-2000))
	resp.AssertJSONHas(t, "withdrawal.currency", "USD")
	resp.AssertJSONHas(t, "earnings.available_cents", float64(8000))
	resp.AssertJSONHas(t, "earnings.withdrawn_cents", float64(2000))
	resp.AssertJSONHas(t, "earnings.lifetime_cents", float64(10000))

	// The balance is persisted, not just echoed: a fresh GET agrees.
	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	get.AssertStatus(t, http.StatusOK)
	get.AssertJSONHas(t, "earnings.available_cents", float64(8000))
	get.AssertJSONHas(t, "earnings.withdrawn_cents", float64(2000))
}

// TestEarningsWithdrawPaidKeepsBalanceReduced pins the double-payout guard: when
// ops settles a pending withdrawal (pending → paid), the debit MUST keep
// reducing the balance. If 'paid' dropped out of withdrawalCountedExpr
// (internal/repository/earnings_repo.go:78) the balance would inflate back to
// the full credit and the same earnings could be withdrawn a second time.
//
// This is the ONLY caller of the mock's SetWithdrawalStatus seam, which is the
// point: before it, no test drove a withdrawal into 'paid', so deleting 'paid'
// from the predicate kept every test green while reintroducing the
// double-payout. The mock mirrors the production predicate inline
// (tests/testutil/mock_earnings_repo.go:114,211,217), so this fails RED when
// 'paid' is removed there too.
func TestEarningsWithdrawPaidKeepsBalanceReduced(t *testing.T) {
	token := registerDriver(t, "driver.earn.paid@test.com", "+7991000008")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.paid.seed", 10000)

	resp := postWithdraw(t, token, "paid-key-1", map[string]interface{}{"amount_cents": 4000})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "earnings.available_cents", float64(6000))
	resp.AssertJSONHas(t, "earnings.withdrawn_cents", float64(4000))

	// Ops/provider settles the withdrawal out of band (RIDER_API_GUIDE.md
	// `## Driver Earnings` — pending is requested, paid is settled).
	if err := ts.EarningsRepo.SetWithdrawalStatus(userID, "paid-key-1", "paid"); err != nil {
		t.Fatalf("settling withdrawal: %v", err)
	}

	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	get.AssertStatus(t, http.StatusOK)
	get.AssertJSONHas(t, "earnings.available_cents", float64(6000))
	get.AssertJSONHas(t, "earnings.withdrawn_cents", float64(4000))

	// The ledger-level balance agrees with the HTTP summary: one reducer.
	if got := ts.EarningsRepo.Available(userID); got != 6000 {
		t.Errorf("ledger available after paid = %d, want 6000 (settling must not restore the balance)", got)
	}
}

// TestEarningsWithdrawOverBalance409: requesting more than the available
// balance is the documented 409 CONFLICT with a public "insufficient balance"
// message — never a 4xx that the rider-style fallback would misclassify, and
// never err.Error() leakage.
func TestEarningsWithdrawOverBalance409(t *testing.T) {
	token := registerDriver(t, "driver.earn.poor@test.com", "+7991000004")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.poor.1", 1000)

	resp := postWithdraw(t, token, "poor-key-1", map[string]interface{}{"amount_cents": 2000})
	resp.AssertStatus(t, http.StatusConflict)
	resp.AssertJSONHas(t, "error.code", "CONFLICT")
	resp.AssertJSONHas(t, "error.message", "insufficient balance")

	// Nothing was debited by the failed attempt.
	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	get.AssertJSONHas(t, "earnings.available_cents", float64(1000))
}

// TestEarningsWithdrawIdempotentReplay: the same Idempotency-Key replays the
// FIRST withdrawal — same id, no second debit.
func TestEarningsWithdrawIdempotentReplay(t *testing.T) {
	token := registerDriver(t, "driver.earn.idem@test.com", "+7991000005")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.idem.1", 10000)

	first := postWithdraw(t, token, "idem-key-1", map[string]interface{}{"amount_cents": 3000})
	first.AssertStatus(t, http.StatusOK)

	replay := postWithdraw(t, token, "idem-key-1", map[string]interface{}{"amount_cents": 3000})
	replay.AssertStatus(t, http.StatusOK)

	var a, b map[string]interface{}
	testutil.ParseJSON(t, first.Body, &a)
	testutil.ParseJSON(t, replay.Body, &b)
	firstWithdrawal := a["withdrawal"].(map[string]interface{})
	replayWithdrawal := b["withdrawal"].(map[string]interface{})
	if firstWithdrawal["id"] != replayWithdrawal["id"] {
		t.Errorf("replay returned a different withdrawal: %v vs %v",
			firstWithdrawal["id"], replayWithdrawal["id"])
	}

	// One debit, not two.
	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	get.AssertJSONHas(t, "earnings.available_cents", float64(7000))
	get.AssertJSONHas(t, "earnings.withdrawn_cents", float64(3000))
}

// TestEarningsWithdrawNoKeyHeader: a missing Idempotency-Key is accepted (the
// header is required for replay-safety, not for validity) and the row is
// recorded with an empty key, which the partial unique index permits.
func TestEarningsWithdrawNoKeyHeader(t *testing.T) {
	token := registerDriver(t, "driver.earn.nokey@test.com", "+7991000006")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.nokey.1", 6000)

	resp := postWithdraw(t, token, "", map[string]interface{}{"amount_cents": 1000})
	resp.AssertStatus(t, http.StatusOK)

	// A second keyless withdrawal is a NEW request (no key → no replay
	// dedup), and the ledger can hold both.
	resp2 := postWithdraw(t, token, "", map[string]interface{}{"amount_cents": 1000})
	resp2.AssertStatus(t, http.StatusOK)

	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	get.AssertJSONHas(t, "earnings.available_cents", float64(4000))
}

// TestEarningsWithdrawConcurrentNoOverdraw: N concurrent withdrawals against
// a balance that funds only M of them — exactly M succeed (the per-driver
// serialised balance check), the rest are 409, and the balance never goes
// negative.
func TestEarningsWithdrawConcurrentNoOverdraw(t *testing.T) {
	token := registerDriver(t, "driver.earn.conc@test.com", "+7991000007")
	userID := driverUserID(t, token)
	ts.EarningsRepo.Credit(userID, "ride.conc.seed", 1000) // funds exactly 2 × 500

	const workers = 5
	statuses := make([]int, workers)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			resp := postWithdraw(t, token, fmt.Sprintf("conc-key-%d", i),
				map[string]interface{}{"amount_cents": 500})
			statuses[i] = resp.StatusCode
		}(i)
	}
	wg.Wait()

	succeeded := 0
	for i, status := range statuses {
		switch status {
		case http.StatusOK:
			succeeded++
		case http.StatusConflict:
			// expected for the losers
		default:
			t.Errorf("worker %d: status = %d, want 200 or 409", i, status)
		}
	}
	if succeeded != 2 {
		t.Errorf("succeeded = %d, want exactly 2 (balance funds 2 × 500 of 1000)", succeeded)
	}

	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", token, nil)
	get.AssertJSONHas(t, "earnings.available_cents", float64(0))
	if got := ts.EarningsRepo.Available(userID); got < 0 {
		t.Errorf("available balance went negative: %d", got)
	}
}

// TestRideCompletionCreditsEarningsLedger walks a real ride to completed and
// asserts the ledger credit: one ride_earning row, lifetime/available > 0,
// completed_trips = 1, and a retried completion is rejected by the state
// machine (so no double credit is reachable).
func TestRideCompletionCreditsEarningsLedger(t *testing.T) {
	_, _, driverToken, rideID, _ := setupAcceptedRide(t, 970)
	driverID := driverUserID(t, driverToken)

	// Empty before the completion.
	get := ts.DoRequest("GET", "/api/v1/driver/me/earnings", driverToken, nil)
	get.AssertStatus(t, http.StatusOK)
	get.AssertJSONHas(t, "earnings.lifetime_cents", float64(0))

	for _, status := range []string{"driver_arrived", "in_progress", "completed"} {
		ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
			map[string]string{"status": status}).AssertStatus(t, http.StatusOK)
	}

	get = ts.DoRequest("GET", "/api/v1/driver/me/earnings", driverToken, nil)
	get.AssertStatus(t, http.StatusOK)
	get.AssertJSONHas(t, "earnings.completed_trips", float64(1))
	get.AssertJSONHas(t, "earnings.month_trips", float64(1))
	get.AssertJSONHas(t, "earnings.currency", "USD")

	var out struct {
		Earnings struct {
			LifetimeCents   int64 `json:"lifetime_cents"`
			AvailableCents  int64 `json:"available_cents"`
			MonthTotalCents int64 `json:"month_total_cents"`
			Months          []struct {
				Month      string `json:"month"`
				TotalCents int64  `json:"total_cents"`
				Trips      int    `json:"trips"`
			} `json:"months"`
		} `json:"earnings"`
	}
	testutil.ParseJSON(t, get.Body, &out)
	if out.Earnings.LifetimeCents <= 0 {
		t.Errorf("lifetime_cents = %d, want a positive fare credit", out.Earnings.LifetimeCents)
	}
	if out.Earnings.AvailableCents != out.Earnings.LifetimeCents {
		t.Errorf("available = %d, lifetime = %d: with commission 0 they must match",
			out.Earnings.AvailableCents, out.Earnings.LifetimeCents)
	}
	if out.Earnings.MonthTotalCents != out.Earnings.LifetimeCents {
		t.Errorf("month_total = %d, lifetime = %d", out.Earnings.MonthTotalCents, out.Earnings.LifetimeCents)
	}
	if len(out.Earnings.Months) == 0 || out.Earnings.Months[0].Trips != 1 {
		t.Errorf("months = %+v, want one bucket with trips=1", out.Earnings.Months)
	}

	// Exactly one ledger row: one ride_earning for the ride.
	rows := ts.EarningsRepo.Rows(driverID)
	if len(rows) != 1 {
		t.Fatalf("ledger rows = %d, want 1", len(rows))
	}
	if rows[0].Kind != "ride_earning" || rows[0].Status != "available" {
		t.Errorf("row = kind %s / status %s, want ride_earning / available", rows[0].Kind, rows[0].Status)
	}
	if rows[0].RideID == nil || *rows[0].RideID != rideID {
		t.Errorf("row ride_id = %v, want %s", rows[0].RideID, rideID)
	}
	// The credit is EXACTLY round(total_fare × 100) when the commission is 0
	// (the shipped default) — not merely "> 0". The ledger stores integer
	// cents and the float fare is converted exactly once at credit time.
	stored, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("reload completed ride: %v", err)
	}
	wantCredit := int64(math.Round(stored.TotalFare * 100))
	if rows[0].AmountCents != wantCredit {
		t.Errorf("credit = %d cents, want round(total_fare %v × 100) = %d",
			rows[0].AmountCents, stored.TotalFare, wantCredit)
	}

	// The state machine rejects completed → completed, so a retried credit
	// is unreachable: 400, not a second ledger row.
	retry := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
		map[string]string{"status": "completed"})
	retry.AssertStatus(t, http.StatusBadRequest)
	retry.AssertJSONHas(t, "error.code", "BAD_REQUEST")

	after := ts.DoRequest("GET", "/api/v1/driver/me/earnings", driverToken, nil)
	after.AssertJSONHas(t, "earnings.completed_trips", float64(1))
	after.AssertJSONHas(t, "earnings.lifetime_cents", float64(out.Earnings.LifetimeCents))
}

// TestRideCompletionFailedCreditIs500: a failing ledger write on completion
// answers 500 (an outage), never a false 200 completed and never a 400.
func TestRideCompletionFailedCreditIs500(t *testing.T) {
	_, _, driverToken, rideID, _ := setupAcceptedRide(t, 971)

	for _, status := range []string{"driver_arrived", "in_progress"} {
		ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
			map[string]string{"status": status}).AssertStatus(t, http.StatusOK)
	}

	// The completion's ledger credit fails like a dead database would.
	ts.EarningsRepo.SetFailNext(fmt.Errorf("connection refused"))

	complete := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
		map[string]string{"status": "completed"})
	complete.AssertStatus(t, http.StatusInternalServerError)
	complete.AssertJSONHas(t, "error.code", "INTERNAL")

	// The failed credit must not appear as a silent balance.
	driverID := driverUserID(t, driverToken)
	if got := ts.EarningsRepo.Available(driverID); got != 0 {
		t.Errorf("available = %d after a FAILED credit, want 0", got)
	}
}

// assertRideUpdatedWS reads one frame and requires it to be a ride.updated for
// status. It is the shared reader for the failed-credit ordering test, where a
// missing frame (the regression under test) must fail the read.
func assertRideUpdatedWS(t *testing.T, conn *websocket.Conn, status string) {
	t.Helper()
	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Fatalf("expected ride.updated, got %v", msg["type"])
	}
	data, ok := msg["data"].(map[string]interface{})
	if !ok {
		t.Fatalf("ride.updated data not an object: %v", msg["data"])
	}
	if data["status"] != status {
		t.Fatalf("expected status %q, got %v (data=%v)", status, data["status"], data)
	}
}

// TestRideCompletionFailedCreditStillNotifiesClients pins the broadcast ordering
// in RideService.AdvanceStatus (internal/service/ride.go:565-624): the committed
// `completed` status is sent to BOTH the rider and the driver BEFORE a failed
// earnings credit is returned. The request still answers 500 (a failed money
// write never answers success), but neither client is left waiting for a
// ride.updated that already happened — otherwise the driver app's advance()
// would wait forever for a broadcast that never comes.
//
// TestRideCompletionFailedCreditIs500 above already pins the 500 + zero
// balance, but it would stay green if the credit error were returned BEFORE the
// broadcasts. Only the two reads here make the ordering non-vacuous: move the
// `return nil, creditErr` above the hub SendToUser calls and both reads time
// out.
func TestRideCompletionFailedCreditStillNotifiesClients(t *testing.T) {
	riderConn, _, driverToken, rideID, _ := setupAcceptedRide(t, 973)

	// The setup's driver socket is internal; attach our own so the driver side
	// of the broadcast is observable. A second dial deliberately evicts the
	// first registration (hub.HandleWS), which is the documented reconnect path.
	driverConn := ts.DialWS(t, driverToken)
	t.Cleanup(func() { _ = driverConn.Close() })

	for _, status := range []string{"driver_arrived", "in_progress"} {
		ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
			map[string]string{"status": status}).AssertStatus(t, http.StatusOK)
		assertRideUpdatedWS(t, riderConn, status)
		assertRideUpdatedWS(t, driverConn, status)
	}

	// The completion's ledger credit fails like a dead database would.
	ts.EarningsRepo.SetFailNext(fmt.Errorf("connection refused"))

	complete := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
		map[string]string{"status": "completed"})
	complete.AssertStatus(t, http.StatusInternalServerError)
	complete.AssertJSONHas(t, "error.code", "INTERNAL")

	// Despite the 500, both clients already learned the committed status.
	assertRideUpdatedWS(t, riderConn, "completed")
	assertRideUpdatedWS(t, driverConn, "completed")
}

// TestRideAdvanceStatusMalformedIDIs422 pins the handler-level uuidRE guard
// (internal/handler/ride.go:591) on the driver status route: a junk ride id is
// a 422 VALIDATION_ERROR answered BEFORE FindByID, mirroring the sibling
// decline endpoint (tests/dispatch_decline_test.go:79). Remove the guard and
// the mock repo's ErrNotFound turns this into a 404 — so the assertion is
// non-vacuous and does not depend on the mock's pq-error divergence.
func TestRideAdvanceStatusMalformedIDIs422(t *testing.T) {
	token := registerDriver(t, "driver.advance.badid@test.com", "+7991000009")

	resp := ts.DoRequest("PUT", "/api/v1/driver/rides/not-a-uuid/status", token,
		map[string]string{"status": "completed"})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
	resp.AssertJSONHas(t, "error.code", "VALIDATION_ERROR")
}

// newPayoutTestServer boots the real router with mock repos and a caller-chosen
// PAYOUT_COMMISSION_RATE. The shared ts server is built once in TestMain and
// cannot carry a per-test commission, so the non-zero-cut credit test builds
// its own — this also exercises the cfg.Payout.CommissionRate → SetEarnings
// wiring that the db-less harness otherwise pins only at 0.
func newPayoutTestServer(t *testing.T, commission float64) (*testutil.TestServer, *testutil.MockEarningsRepo) {
	t.Helper()
	cfg := config.Load()
	cfg.RateLimitRegister = 9999
	cfg.RateLimitLogin = 9999
	cfg.RateLimitGeneral = 9999
	cfg.RateLimitRide = 9999
	cfg.Payout.CommissionRate = commission

	userRepo := testutil.NewMockUserRepo()
	rideRepo := testutil.NewMockRideRepo()
	geoRepo := testutil.NewMockGeoRepo()
	navRepo := testutil.NewMockNavigationRepo()
	placesRepo := testutil.NewMockPlacesRepo()
	deviceRepo := testutil.NewMockDeviceTokenRepo()
	feedbackRepo := testutil.NewMockFeedbackRepo()
	earningsRepo := testutil.NewMockEarningsRepo()

	r := router.SetupWithRepos(cfg, userRepo, rideRepo, geoRepo, navRepo, placesRepo, nil,
		router.WithDeviceTokenRepository(deviceRepo),
		router.WithFeedbackRepository(feedbackRepo),
		router.WithFareRepository(testutil.NewMockFareRepo()),
		router.WithEarningsRepository(earningsRepo),
	)

	srv := &testutil.TestServer{
		Server:       httptest.NewServer(r),
		Config:       cfg,
		AuthTokens:   map[string]string{},
		UserRepo:     userRepo,
		RideRepo:     rideRepo,
		GeoRepo:      geoRepo,
		PlacesRepo:   placesRepo,
		DeviceRepo:   deviceRepo,
		FeedbackRepo: feedbackRepo,
		EarningsRepo: earningsRepo,
	}
	t.Cleanup(srv.Close)
	return srv, earningsRepo
}

// TestRideCompletionCreditIsNetOfCommission pins the commission arithmetic: the
// credited amount is EXACTLY round(fare × (1 − commission) × 100). With a 15%
// cut on a 12.34 fare the ledger holds 1049 cents — not the gross 1234, and not
// a raw float artifact. The ride is booked with no fare card, so the completion
// recompute is a no-op and the credit keys off the booked total.
func TestRideCompletionCreditIsNetOfCommission(t *testing.T) {
	const (
		totalFare  = 12.34
		commission = 0.15
	)
	srv, earnings := newPayoutTestServer(t, commission)
	driverToken, driverID := registerDriverOn(t, srv, "payout.comm.driver@test.com", "+7991000121")
	_, riderID := registerOn(t, srv, "payout.comm.rider@test.com", "+7991000122")

	ride := &model.Ride{
		RiderID:      riderID,
		DriverID:     &driverID,
		PickupLat:    40.71,
		PickupLng:    -74.01,
		DropoffLat:   40.72,
		DropoffLng:   -74.02,
		BaseFare:     4,
		DistanceFare: 6.34,
		TimeFare:     2,
		TotalFare:    totalFare,
	}
	if err := srv.RideRepo.CreateRide(ride); err != nil {
		t.Fatalf("seed ride: %v", err)
	}
	if err := srv.RideRepo.AssignDriver(ride.ID, driverID); err != nil {
		t.Fatalf("assign driver: %v", err)
	}

	for _, status := range []string{"driver_arrived", "in_progress"} {
		srv.DoRequest("PUT", "/api/v1/driver/rides/"+ride.ID+"/status", driverToken,
			map[string]string{"status": status}).AssertStatus(t, http.StatusOK)
	}
	srv.DoRequest("PUT", "/api/v1/driver/rides/"+ride.ID+"/status", driverToken,
		map[string]string{"status": "completed"}).AssertStatus(t, http.StatusOK)

	rows := earnings.Rows(driverID)
	if len(rows) != 1 {
		t.Fatalf("ledger rows = %d, want 1", len(rows))
	}
	want := int64(math.Round(totalFare * (1 - commission) * 100))
	if rows[0].AmountCents != want {
		t.Errorf("credit = %d cents, want round(%v × (1−%v) × 100) = %d",
			rows[0].AmountCents, totalFare, commission, want)
	}
}

// TestEarningsRoutesRejectRiderToken: both earnings routes are driver-only
// (RequireRole("driver")). A rider token must get 403 on each — never a 200
// summary, and never a 4xx the client could mistake for request validation.
func TestEarningsRoutesRejectRiderToken(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.payout.authz@test.com", "+7991000131")

	cases := []struct {
		name   string
		method string
		path   string
		body   interface{}
	}{
		{"get earnings", http.MethodGet, "/api/v1/driver/me/earnings", nil},
		{"withdraw", http.MethodPost, "/api/v1/driver/earnings/withdraw",
			map[string]interface{}{"amount_cents": 1000}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := ts.DoRequest(tc.method, tc.path, riderToken, tc.body)
			resp.AssertStatus(t, http.StatusForbidden)
		})
	}
}
