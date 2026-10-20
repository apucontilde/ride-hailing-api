package service

import (
	"log"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/service/push"
)

// Proximity arrival geofence — api_plans/[arrival]_proximity_arrival_geofence.md.
//
// The service owns the proximity evaluation on the geo driver-location hot
// path. For the caller's active ride while it is status "accepted" it:
//
//   - measures the straight-line (haversine) distance from the fix to the
//     ride's pickup;
//   - advances accepted -> driver_arrived via the EXISTING state machine when
//     the fix is inside the arrive radius (server-authoritative, actor
//     "system"); and
//   - reports the additive nearby fields the handler puts on driver.location.
//
// It never returns an error: a geofence failure (a failed transition, a lost
// race) is logged and swallowed so it can never fail the location update.

// nearState is the process-local per-ride nearby bookkeeping (plan §3 D9).
//
// It is deliberately in-memory and single-pod: a server restart re-arms the
// flag (one duplicate ride.nearby push is possible), and with multiple pods each
// pod may push once. Both are harmless UX duplicates; arrival itself is
// idempotent in the database (the state machine rejects driver_arrived ->
// driver_arrived), so this state never decides a status. The durable multi-pod
// variant is the plan's D10 follow-up, not taken here.
type nearState struct {
	lastLat, lastLng float64
	haveLast         bool
	nearFired        bool
}

// SetArrivalGeofence installs the geofence configuration. It is a separate seam
// from the constructor so existing NewRideService call sites keep compiling; the
// zero value (Enabled=false) is the documented "off" mode. Called once at wiring
// time (router.SetupWithRepos).
func (s *RideService) SetArrivalGeofence(cfg config.ArrivalGeofence) {
	s.arrival = cfg
}

// EvaluateArrival observes one accepted-phase fix for the caller's ride. It may
// advance the ride to driver_arrived (server-authoritative) and fire the
// backgrounded nearby push on the first crossing. It never returns an error: a
// geofence failure must not fail the location update. It returns the proximity
// fields for the driver.location event.
//
// No evaluation happens when the feature is off, the caller is not the ride's
// driver, or the ride is not "accepted". On a ride that has left "accepted" the
// nearby bookkeeping is dropped and the fields go back to their legacy (absent)
// shape.
func (s *RideService) EvaluateArrival(ride *model.Ride, driverID string, lat, lng float64) (nearPickup bool, distanceToPickupM float64) {
	if s == nil || ride == nil || !s.arrival.Enabled {
		return false, 0
	}
	// Defensive ownership re-check: FindCurrentRideByDriver already scopes the
	// query to this driver, but a ride whose driver is somebody else must never
	// advance or notify.
	if ride.DriverID == nil || *ride.DriverID != driverID {
		return false, 0
	}

	// The proximity fields and the state advance exist only while accepted.
	// Once the ride moves on, forget the nearby bookkeeping and report nothing.
	if ride.Status != "accepted" {
		s.forgetNearState(ride.ID)
		return false, 0
	}

	d := HaversineMeters(lat, lng, ride.PickupLat, ride.PickupLng)

	// Arrive gate. Deliberately evaluated BEFORE the min-move nearby debounce:
	// a slow creep from 82 m to 77 m in sub-MIN_MOVE steps must still fire
	// arrival (plan §3 D3).
	if s.advanceIfInsideArriveRadius(ride, d) {
		s.forgetNearState(ride.ID)
		return true, d
	}

	return s.evaluateNearby(ride, lat, lng, d), d
}

// EvaluateArrivalAtAccept is the ARRIVE-ONLY entry point used by the accept
// path (api_plans/[arrival]_accept_time_evaluation.md D4=A). It runs exactly the
// same arrive gate as EvaluateArrival and nothing else: it never evaluates the
// nearby radius, never fires a ride.nearby push, and never primes or clears the
// nearby hysteresis state. A driver who accepts while already inside the arrive
// radius is advanced to driver_arrived without depending on the app
// re-publishing a fix.
//
// Like EvaluateArrival it never returns an error and swallows a failed or
// lost-race transition (the [rides] CAS already makes the transition
// single-writer). Freshness is deliberately NOT its concern: the accept path
// gates the SQL-computed fix age before calling it, while the live PUT path is
// inherently fresh.
func (s *RideService) EvaluateArrivalAtAccept(ride *model.Ride, driverID string, lat, lng float64) bool {
	if s == nil || ride == nil || !s.arrival.Enabled {
		return false
	}
	if ride.DriverID == nil || *ride.DriverID != driverID {
		return false
	}
	if ride.Status != "accepted" {
		return false
	}
	return s.advanceIfInsideArriveRadius(ride, HaversineMeters(lat, lng, ride.PickupLat, ride.PickupLng))
}

// advanceIfInsideArriveRadius is the ONE arrive gate shared by EvaluateArrival
// and EvaluateArrivalAtAccept. It reports whether the fix is inside the
// (clamped) arrive radius; it deliberately does NOT touch the nearby hysteresis
// state — the live PUT caller does that itself, and the accept-time caller must
// not (D4=A). A failed or lost-race transition is logged and swallowed so a
// geofence failure never fails the location update or the accept.
func (s *RideService) advanceIfInsideArriveRadius(ride *model.Ride, d float64) bool {
	arrive := s.arriveRadiusM()
	if arrive <= 0 || d > arrive {
		return false
	}
	if _, err := s.AdvanceStatus(ride.ID, "driver_arrived", "system"); err != nil {
		log.Printf("ride %s: proximity arrival transition failed: %v", ride.ID, err)
	}
	return true
}

// arriveRadiusM applies the ARRIVE <= NEARBY rule: a misconfigured ARRIVE >
// NEARBY is clamped to NEARBY and logged once. A non-positive radius disables
// that leg (fail-closed: never fires).
func (s *RideService) arriveRadiusM() float64 {
	arrive := s.arrival.ArriveRadiusM
	nearby := s.arrival.NearbyRadiusM
	if arrive > nearby {
		s.arrivalClampOnce.Do(func() {
			log.Printf("geofence: GEOFENCE_ARRIVE_RADIUS_M (%g) > GEOFENCE_NEARBY_RADIUS_M (%g); clamping ARRIVE to NEARBY", arrive, nearby)
		})
		arrive = nearby
	}
	return arrive
}

// evaluateNearby runs the nearby hysteresis and fires the one-per-crossing
// backgrounded push. It returns whether the fix is currently "near". A
// non-positive nearby radius disables the leg (fail-closed).
func (s *RideService) evaluateNearby(ride *model.Ride, lat, lng, d float64) bool {
	nearby := s.arrival.NearbyRadiusM
	if nearby <= 0 {
		return false
	}

	s.nearMu.Lock()
	if s.nearStates == nil {
		s.nearStates = make(map[string]*nearState)
	}
	st := s.nearStates[ride.ID]
	if st == nil {
		st = &nearState{}
		s.nearStates[ride.ID] = st
	}

	// MIN_MOVE suppresses the nearby-crossing bookkeeping (but never the arrive
	// gate above): a stationary receiver wobbling must not re-arm or flicker the
	// flag. The current flag is reported unchanged.
	if st.haveLast && s.arrival.MinMoveM > 0 &&
		HaversineMeters(st.lastLat, st.lastLng, lat, lng) < s.arrival.MinMoveM {
		near := st.nearFired
		s.nearMu.Unlock()
		return near
	}
	st.lastLat, st.lastLng, st.haveLast = lat, lng, true

	crossed := false
	if st.nearFired {
		// Re-arm only once clear of the hysteresis band.
		if d > nearby+s.arrival.HysteresisM {
			st.nearFired = false
		}
	} else if d <= nearby {
		st.nearFired = true
		crossed = true
	}
	near := st.nearFired
	s.nearMu.Unlock()

	if crossed {
		s.notifyOffline(ride.RiderID, nearbyPushMessage(ride.ID))
	}
	return near
}

// forgetNearState drops the bookkeeping once a ride leaves accepted.
func (s *RideService) forgetNearState(rideID string) {
	s.nearMu.Lock()
	delete(s.nearStates, rideID)
	s.nearMu.Unlock()
}

// nearbyPushMessage is the canonical backgrounded nearby push (plan §2.4).
// status stays "accepted": nearby is an advisory signal and must never announce
// a status the database does not hold.
func nearbyPushMessage(rideID string) push.Message {
	return push.Message{
		Title: "Driver nearby",
		Body:  "Your driver is almost at the pickup point.",
		Data: map[string]string{
			"type":        "ride.nearby",
			"status":      "accepted",
			"ride_id":     rideID,
			"near_pickup": "true",
		},
	}
}
