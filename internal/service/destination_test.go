package service

import (
	"errors"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/websocket"
)

// stubRideRepo is the minimum RideRepository ChangeDestination touches: it
// answers FindByID and records the ReplaceDestination call, so the service's
// authorization and status rules are testable without a database.
type stubRideRepo struct {
	mu   sync.Mutex
	ride *model.Ride
	// replaceErr fails ReplaceDestination (the persistence-outage case).
	replaceErr error
	replaced   []model.RideStop
}

func (s *stubRideRepo) CreateRide(*model.Ride) error { return nil }
func (s *stubRideRepo) FindStopsByRideID(string) ([]model.RideStop, error) {
	return nil, nil
}
func (s *stubRideRepo) FindStopsByRideIDs([]string) (map[string][]model.RideStop, error) {
	return nil, nil
}
func (s *stubRideRepo) FindCurrentRideByRider(string) (*model.Ride, error) {
	return nil, repository.ErrNotFound
}
func (s *stubRideRepo) FindCurrentRideByDriver(string) (*model.Ride, error) {
	return nil, repository.ErrNotFound
}
func (s *stubRideRepo) FindRidesByRider(string, int, int) ([]model.Ride, int, error) {
	return nil, 0, nil
}
func (s *stubRideRepo) FindRidesByDriver(string, int, int) ([]model.Ride, int, error) {
	return nil, 0, nil
}
func (s *stubRideRepo) UpdateRideStatus(string, string, *time.Time) error { return nil }
func (s *stubRideRepo) AssignDriver(string, string) error                 { return nil }
func (s *stubRideRepo) CreateEvent(*model.RideEvent) error                { return nil }
func (s *stubRideRepo) CreateRating(*model.Rating) error                  { return nil }
func (s *stubRideRepo) FindRatingsByRater(string, string, int, int) ([]model.Rating, int, error) {
	return nil, 0, nil
}
func (s *stubRideRepo) FindVehicleByDriverID(string) (*model.DriverVehicle, error) {
	return nil, repository.ErrNotFound
}

func (s *stubRideRepo) FindByID(id string) (*model.Ride, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ride == nil || s.ride.ID != id {
		return nil, errors.Join(repository.ErrNotFound, errors.New("no such ride"))
	}
	cp := *s.ride
	return &cp, nil
}

func (s *stubRideRepo) ReplaceDestination(_ string, dest model.RideStop) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.replaceErr != nil {
		return s.replaceErr
	}
	s.replaced = append(s.replaced, dest)
	return nil
}

func newDestinationService(ride *model.Ride, replaceErr error) (*RideService, *stubRideRepo) {
	repo := &stubRideRepo{ride: ride, replaceErr: replaceErr}
	return NewRideService(repo, nil, websocket.NewHub(), nil), repo
}

// TestChangeDestinationAuthorizationAndStatus is the table behind the endpoint's
// error contract: a destination change is a data mutation allowed only for the
// ride's own rider and only while the itinerary is open.
func TestChangeDestinationAuthorizationAndStatus(t *testing.T) {
	const riderID = "11111111-1111-1111-1111-111111111111"
	const otherID = "22222222-2222-2222-2222-222222222222"

	dest := model.RideStop{Kind: model.DestinationKind, Lat: 40.7, Lng: -74.0, Address: "New"}

	tests := []struct {
		name        string
		status      string
		rideRider   string
		caller      string
		replaceErr  error
		wantErr     error
		wantPersist bool
	}{
		{
			name: "pending ride may change it", status: "pending",
			rideRider: riderID, caller: riderID, wantPersist: true,
		},
		{
			name: "accepted ride may change it", status: "accepted",
			rideRider: riderID, caller: riderID, wantPersist: true,
		},
		{
			name: "driver_arrived ride may change it", status: "driver_arrived",
			rideRider: riderID, caller: riderID, wantPersist: true,
		},
		{
			name: "in_progress ride may change it (mid-trip)", status: "in_progress",
			rideRider: riderID, caller: riderID, wantPersist: true,
		},
		{
			name: "another rider may not", status: "pending",
			rideRider: otherID, caller: riderID, wantErr: ErrNotRideRider,
		},
		{
			name: "a completed ride is closed", status: "completed",
			rideRider: riderID, caller: riderID, wantErr: ErrDestinationLocked,
		},
		{
			name: "a cancelled ride is closed", status: "cancelled",
			rideRider: riderID, caller: riderID, wantErr: ErrDestinationLocked,
		},
		{
			name: "a ride with no driver found is closed", status: "no_driver_available",
			rideRider: riderID, caller: riderID, wantErr: ErrDestinationLocked,
		},
		{
			name:   "an unknown status is closed, never a silent success",
			status: "teleported", rideRider: riderID, caller: riderID,
			wantErr: ErrDestinationLocked,
		},
		{
			name:   "a write outage propagates and is not a state error",
			status: "pending", rideRider: riderID, caller: riderID,
			replaceErr: errors.New("connection refused"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ride := &model.Ride{
				ID: "ride-1", RiderID: tt.rideRider, Status: tt.status,
				DropoffLat: 1, DropoffLng: 1, DropoffAddress: "Old",
			}
			svc, repo := newDestinationService(ride, tt.replaceErr)

			got, err := svc.ChangeDestination("ride-1", tt.caller, dest)

			switch {
			case tt.replaceErr != nil:
				// A failed write must reach the caller as an error, never as a
				// ride that looks updated.
				if err == nil {
					t.Fatal("expected the write failure to propagate")
				}
				if errors.Is(err, ErrDestinationLocked) || errors.Is(err, ErrNotRideRider) {
					t.Fatalf("a database outage was misreported as a client error: %v", err)
				}
				if got != nil {
					t.Error("expected no ride when the write failed")
				}
			case tt.wantErr != nil:
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("error = %v, want %v", err, tt.wantErr)
				}
			default:
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if got.DropoffLat != dest.Lat || got.DropoffLng != dest.Lng ||
					got.DropoffAddress != dest.Address {
					t.Errorf("returned ride still has the old destination: %+v", got)
				}
				// The status must NOT move: this is not a transition.
				if got.Status != tt.status {
					t.Errorf("status = %q, want it unchanged at %q", got.Status, tt.status)
				}
			}

			wantPersisted := tt.wantPersist || tt.replaceErr == nil && tt.wantErr == nil
			if got2 := len(repo.replaced); (got2 == 1) != wantPersisted {
				t.Errorf("ReplaceDestination called %d times, want persisted=%v", got2, wantPersisted)
			}
		})
	}
}

// TestChangeDestinationMissingRideIsNotFound keeps a deleted ride out of the
// 500 path: FindByID's taxonomy error must arrive unchanged.
func TestChangeDestinationMissingRideIsNotFound(t *testing.T) {
	svc, repo := newDestinationService(nil, nil)

	_, err := svc.ChangeDestination("gone", "11111111-1111-1111-1111-111111111111", model.RideStop{
		Kind: model.DestinationKind, Lat: 1, Lng: 1,
	})
	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("error = %v, want repository.ErrNotFound", err)
	}
	if len(repo.replaced) != 0 {
		t.Error("a missing ride must not be written to")
	}
}
