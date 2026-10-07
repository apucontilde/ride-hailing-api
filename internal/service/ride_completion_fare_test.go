package service

import (
	"math"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

// captureFinalizeRepo records the arguments of the completion finalization so a
// test can prove the RECOMPUTED uplift (not the booked one) is what the final
// charge carries. It embeds the interface nil on purpose: any method the
// completion path does not use panics, which is the "this test only exercises
// the completion path" signal.
type captureFinalizeRepo struct {
	repository.RideRepository
	ride      *model.Ride
	points    []model.RideTrackPoint
	finalized bool
	gotUplift *float64
}

func (r *captureFinalizeRepo) FindByID(string) (*model.Ride, error) {
	cp := *r.ride
	return &cp, nil
}
func (r *captureFinalizeRepo) UpdateRideStatus(string, string, *time.Time) error { return nil }
func (r *captureFinalizeRepo) CreateEvent(*model.RideEvent) error                { return nil }
func (r *captureFinalizeRepo) FindRideTrackPoints(string) ([]model.RideTrackPoint, error) {
	return r.points, nil
}
func (r *captureFinalizeRepo) SetRideActuals(string, *int, *float64) error { return nil }
func (r *captureFinalizeRepo) FinalizeRideFare(_ string, _, _, _, _ float64, gradeUpliftPct *float64) (bool, error) {
	r.finalized = true
	r.gotUplift = gradeUpliftPct
	return true, nil
}

// TestCompletionFinalizesWithRecomputedGradeUpliftNotBooked is defect 1 of the
// actuals review: the uplift stored/echoed for a completed ride must be the one
// actually used for the FINAL distance leg, not the booked value. The booked
// quoted value is preserved separately for audit.
func TestCompletionFinalizesWithRecomputedGradeUpliftNotBooked(t *testing.T) {
	fares := newFakeFareRepo()
	fares.setUplift("cr-sj", "sedan", 0.001, 0.15)
	cardID := fares.rates["cr-sj|sedan"].ID

	const booked = 0.10
	ascent := 250.0
	started := time.Now().Add(-5 * time.Minute)
	ride := &model.Ride{
		ID: "ride-final-uplift", Status: "in_progress",
		FareRateID: &cardID, GradeAscentM: &ascent, GradeUpliftPct: floatPtr(booked),
		SurgeMultiplier: 1.0,
		BaseFare:        5, DistanceFare: 7.5, TimeFare: 2.5, TotalFare: 15,
		StartedAt: &started,
	}
	points := []model.RideTrackPoint{
		{Lat: 40.0, Lng: -74.0, RecordedAt: started},
		{Lat: 40.05, Lng: -74.0, RecordedAt: started.Add(300 * time.Second)},
	}
	repo := &captureFinalizeRepo{ride: ride, points: points}
	svc := NewRideService(repo, nil, websocket.NewHub(), NewFareService(nil, nil, fares, testFareConfig()))

	got, err := svc.AdvanceStatus(ride.ID, "completed", "driver")
	if err != nil {
		t.Fatalf("AdvanceStatus: %v", err)
	}
	if !repo.finalized {
		t.Fatal("completion did not finalize the fare")
	}

	dist := DrivenDistanceMeters(points)
	if dist == nil {
		t.Fatal("fixture trace is unusable; the test cannot exercise the recompute")
	}
	want := gradeUpliftPct(ascent, int(math.Round(*dist)), true, 0.001, 0.15)
	if repo.gotUplift == nil || math.Abs(*repo.gotUplift-want) > 1e-12 {
		t.Errorf("finalized uplift = %v, want the recomputed %v", repo.gotUplift, want)
	}
	if repo.gotUplift != nil && *repo.gotUplift == booked {
		t.Errorf("finalized uplift equals the booked %v; the final leg's uplift must be used", booked)
	}
	if got.GradeUpliftPct == nil || math.Abs(*got.GradeUpliftPct-want) > 1e-12 {
		t.Errorf("ride.GradeUpliftPct = %v, want the applied %v", got.GradeUpliftPct, want)
	}
	if got.QuotedGradeUpliftPct == nil || *got.QuotedGradeUpliftPct != booked {
		t.Errorf("ride.QuotedGradeUpliftPct = %v, want the booked %v", got.QuotedGradeUpliftPct, booked)
	}
}

func floatPtr(v float64) *float64 { return &v }
