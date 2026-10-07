package handler

import "testing"

func f64ptr(v float64) *float64 { return &v }

// TestValidateCreateCoordinates pins the create-ride top-level bounds check
// (STATUS.md known bug #23): 0 and the exact limits are valid, and each of the
// four coordinates is rejected by its own public name, with a non-nil cause so
// fail() logs which value was bad.
func TestValidateCreateCoordinates(t *testing.T) {
	tests := []struct {
		name                                         string
		pickupLat, pickupLng, dropoffLat, dropoffLng float64
		wantMsg                                      string
	}{
		{name: "all zero is valid (equator / prime meridian)", wantMsg: ""},
		{name: "the exact limits are valid", pickupLat: 90, pickupLng: 180, dropoffLat: -90, dropoffLng: -180, wantMsg: ""},
		{name: "pickup latitude above range", pickupLat: 91, pickupLng: -74, dropoffLat: 40.7, dropoffLng: -74, wantMsg: "Pickup latitude out of range"},
		{name: "pickup latitude below range", pickupLat: -91, pickupLng: -74, dropoffLat: 40.7, dropoffLng: -74, wantMsg: "Pickup latitude out of range"},
		{name: "pickup longitude above range", pickupLat: 40.7, pickupLng: 181, dropoffLat: 40.7, dropoffLng: -74, wantMsg: "Pickup longitude out of range"},
		{name: "pickup longitude below range", pickupLat: 40.7, pickupLng: -181, dropoffLat: 40.7, dropoffLng: -74, wantMsg: "Pickup longitude out of range"},
		{name: "drop-off latitude above range", pickupLat: 40.7, pickupLng: -74, dropoffLat: 999, dropoffLng: -74, wantMsg: "Drop-off latitude out of range"},
		{name: "drop-off longitude above range", pickupLat: 40.7, pickupLng: -74, dropoffLat: 40.7, dropoffLng: 181, wantMsg: "Drop-off longitude out of range"},
		{name: "drop-off longitude below range", pickupLat: 40.7, pickupLng: -74, dropoffLat: 40.7, dropoffLng: -181, wantMsg: "Drop-off longitude out of range"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := &rideRequest{
				PickupLat:  f64ptr(tt.pickupLat),
				PickupLng:  f64ptr(tt.pickupLng),
				DropoffLat: f64ptr(tt.dropoffLat),
				DropoffLng: f64ptr(tt.dropoffLng),
			}

			msg, cause := validateCreateCoordinates(req)

			if tt.wantMsg == "" {
				if msg != "" || cause != nil {
					t.Fatalf("valid coordinates rejected: msg=%q cause=%v", msg, cause)
				}
				return
			}
			if msg != tt.wantMsg {
				t.Errorf("message = %q, want %q", msg, tt.wantMsg)
			}
			if cause == nil {
				t.Error("cause is nil; fail() would log nothing for this rejection")
			}
		})
	}
}
