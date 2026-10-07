package handler

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// stubRideFinder satisfies repository.RideRepository for the one call the
// receipt handler makes. The embedded interface is nil on purpose: any other
// method would panic, which is exactly the "this test only exercises FindByID"
// signal. testutil's mock cannot be imported here (it imports router → cycle).
type stubRideFinder struct {
	repository.RideRepository
	ride *model.Ride
}

func (s stubRideFinder) FindByID(string) (*model.Ride, error) { return s.ride, nil }

// TestGetRideReceiptEchoesAppliedGradeUplift proves the receipt reports the
// uplift APPLIED to the final distance leg, not the booked quote, once a ride is
// completed. The db-less end-to-end harness can only produce a 0 uplift (its
// navigation mock takes the legacy, elevation-unaware path), so this drives the
// handler directly with a completed snapshot whose applied uplift differs from
// the quoted one (defect 1 of the actuals review).
func TestGetRideReceiptEchoesAppliedGradeUplift(t *testing.T) {
	finalUplift := 0.0567
	bookedUplift := 0.1135
	region := "cr-sj"
	currency := "USD"
	ride := &model.Ride{
		ID:                   "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
		RiderID:              "11111111-1111-1111-1111-111111111111",
		FareRegionID:         &region,
		FareCurrency:         &currency,
		GradeUpliftPct:       &finalUplift,
		QuotedGradeUpliftPct: &bookedUplift,
	}

	c, w := newTestContext()
	c.Params = gin.Params{{Key: "id", Value: ride.ID}}
	NewRideHandler(nil, nil, stubRideFinder{ride: ride}).GetRideReceipt(c)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", w.Code, w.Body.String())
	}
	var body struct {
		Receipt struct {
			RegionID       string  `json:"region_id"`
			Currency       string  `json:"currency"`
			GradeUpliftPct float64 `json:"grade_uplift_pct"`
		} `json:"receipt"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode receipt: %v", err)
	}
	if body.Receipt.GradeUpliftPct != finalUplift {
		t.Errorf("receipt grade_uplift_pct = %v, want the APPLIED final %v (not the quoted %v)",
			body.Receipt.GradeUpliftPct, finalUplift, bookedUplift)
	}
	if body.Receipt.RegionID != region || body.Receipt.Currency != currency {
		t.Errorf("receipt region/currency = %q/%q, want %q/%q",
			body.Receipt.RegionID, body.Receipt.Currency, region, currency)
	}
}
