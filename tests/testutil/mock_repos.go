package testutil

import (
	crand "crypto/rand"
	"fmt"
	"math"
	"sync"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

func newID() string {
	b := make([]byte, 16)
	if _, err := crand.Read(b); err != nil {
		panic(fmt.Sprintf("testutil: cannot read random bytes: %v", err))
	}
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// failNext consumes a repo's one-shot injected failure, if any. It lets the
// write-failure branches (which the real repositories can hit through a dead
// driver) be exercised under test.
func failNext(fail *error) error {
	if fail == nil || *fail == nil {
		return nil
	}
	err := *fail
	*fail = nil
	return err
}

// --- MockUserRepo ---

type MockUserRepo struct {
	mu                  sync.Mutex
	users               map[string]*model.User
	riders              map[string]*model.Rider
	drivers             map[string]*model.Driver
	byEmail             map[string]string
	refreshTokens       map[string]*model.RefreshToken
	passwordResetTokens map[string]*model.PasswordResetToken

	// FailNext, when non-nil, is returned by the next operation that checks it
	// (FindByEmail read path, and the fail-closed write branches: token
	// revocation, write failures) and then cleared. It makes the failure
	// branches reachable under test: the real repositories return a driver
	// error from Exec/Query, and the mock must be able to too.
	FailNext error
}

func NewMockUserRepo() *MockUserRepo {
	return &MockUserRepo{
		users:               make(map[string]*model.User),
		riders:              make(map[string]*model.Rider),
		drivers:             make(map[string]*model.Driver),
		byEmail:             make(map[string]string),
		refreshTokens:       make(map[string]*model.RefreshToken),
		passwordResetTokens: make(map[string]*model.PasswordResetToken),
	}
}

func (m *MockUserRepo) CreateUser(u *model.User) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	if _, exists := m.byEmail[u.Email]; exists {
		return fmt.Errorf("create user: %w", repository.ErrConflict)
	}
	id := newID()
	now := time.Now()
	u.ID = id
	u.CreatedAt = now
	u.UpdatedAt = now
	if u.Status == "" {
		u.Status = "active"
	}
	if u.Role == "" {
		u.Role = "rider"
	}
	m.users[id] = u
	m.byEmail[u.Email] = id
	return nil
}

func (m *MockUserRepo) FindByEmail(email string) (*model.User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return nil, err
	}
	id, ok := m.byEmail[email]
	if !ok {
		return nil, fmt.Errorf("load user: %w", repository.ErrNotFound)
	}
	u, ok := m.users[id]
	if !ok {
		return nil, fmt.Errorf("load user: %w", repository.ErrNotFound)
	}
	cp := *u
	return &cp, nil
}

func (m *MockUserRepo) FindByID(id string) (*model.User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return nil, fmt.Errorf("load user: %w", repository.ErrNotFound)
	}
	cp := *u
	return &cp, nil
}

func (m *MockUserRepo) UpdateUser(u *model.User) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, ok := m.users[u.ID]
	if !ok {
		return fmt.Errorf("load user: %w", repository.ErrNotFound)
	}
	u.CreatedAt = existing.CreatedAt
	u.UpdatedAt = time.Now()
	m.users[u.ID] = u
	return nil
}

func (m *MockUserRepo) CreateRider(rider *model.Rider) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	rider.CreatedAt = now
	rider.UpdatedAt = now
	if rider.Status == "" {
		rider.Status = "idle"
	}
	m.riders[rider.UserID] = rider
	return nil
}

func (m *MockUserRepo) FindRiderByID(userID string) (*model.Rider, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.riders[userID]
	if !ok {
		return nil, fmt.Errorf("load rider: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

func (m *MockUserRepo) UpdateRider(rider *model.Rider) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, ok := m.riders[rider.UserID]
	if !ok {
		return fmt.Errorf("load rider: %w", repository.ErrNotFound)
	}
	rider.CreatedAt = existing.CreatedAt
	rider.UpdatedAt = time.Now()
	m.riders[rider.UserID] = rider
	return nil
}

func (m *MockUserRepo) CreateDriver(driver *model.Driver) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	driver.CreatedAt = now
	driver.UpdatedAt = now
	if driver.Status == "" {
		driver.Status = "available"
	}
	if driver.OnboardingStatus == "" {
		driver.OnboardingStatus = "completed"
	}
	m.drivers[driver.UserID] = driver
	return nil
}

func (m *MockUserRepo) FindDriverByID(userID string) (*model.Driver, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.drivers[userID]
	if !ok {
		return nil, fmt.Errorf("load driver: %w", repository.ErrNotFound)
	}
	cp := *d
	return &cp, nil
}

func (m *MockUserRepo) UpdateDriver(driver *model.Driver) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	existing, ok := m.drivers[driver.UserID]
	if !ok {
		return fmt.Errorf("load driver: %w", repository.ErrNotFound)
	}
	driver.CreatedAt = existing.CreatedAt
	driver.UpdatedAt = time.Now()
	m.drivers[driver.UserID] = driver
	return nil
}

func (m *MockUserRepo) SoftDeleteUser(userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[userID]
	if !ok {
		return fmt.Errorf("load user: %w", repository.ErrNotFound)
	}
	u.Status = "deleted"
	u.UpdatedAt = time.Now()
	return nil
}

func (m *MockUserRepo) CreateRefreshToken(token *model.RefreshToken) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	id := newID()
	token.ID = id
	token.CreatedAt = time.Now()
	m.refreshTokens[token.TokenHash] = token
	return nil
}

func (m *MockUserRepo) FindRefreshTokenByHash(hash string) (*model.RefreshToken, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.refreshTokens[hash]
	if !ok || t.Revoked {
		return nil, fmt.Errorf("load refresh token: %w", repository.ErrNotFound)
	}
	cp := *t
	return &cp, nil
}

func (m *MockUserRepo) RevokeRefreshToken(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	for _, t := range m.refreshTokens {
		if t.ID == id {
			t.Revoked = true
			return nil
		}
	}
	return nil
}

func (m *MockUserRepo) CreatePasswordResetToken(token *model.PasswordResetToken) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	id := newID()
	token.ID = id
	token.CreatedAt = time.Now()
	m.passwordResetTokens[token.TokenHash] = token
	return nil
}

func (m *MockUserRepo) FindPasswordResetTokenByHash(hash string) (*model.PasswordResetToken, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.passwordResetTokens[hash]
	if !ok || t.Used {
		return nil, fmt.Errorf("load password reset token: %w", repository.ErrNotFound)
	}
	cp := *t
	return &cp, nil
}

func (m *MockUserRepo) RevokePasswordResetToken(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	for _, t := range m.passwordResetTokens {
		if t.ID == id {
			t.Used = true
			return nil
		}
	}
	return nil
}

func (m *MockUserRepo) RevokeUserPasswordResetTokens(userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	for _, t := range m.passwordResetTokens {
		if t.UserID == userID && !t.Used {
			t.Used = true
		}
	}
	return nil
}

// --- MockRideRepo ---

type MockRideRepo struct {
	mu       sync.Mutex
	rides    map[string]*model.Ride
	events   []*model.RideEvent
	ratings  []*model.Rating
	vehicles map[string]*model.DriverVehicle

	// FailNext, when non-nil, is returned by the next write operation and then
	// cleared. It makes the write-failure branches in CreateEvent/CreateRating
	// reachable: the real repositories return a driver error from Exec.
	FailNext error
}

func NewMockRideRepo() *MockRideRepo {
	return &MockRideRepo{
		rides:    make(map[string]*model.Ride),
		events:   make([]*model.RideEvent, 0),
		ratings:  make([]*model.Rating, 0),
		vehicles: make(map[string]*model.DriverVehicle),
	}
}

func (m *MockRideRepo) CreateRide(ride *model.Ride) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	id := newID()
	now := time.Now()
	ride.ID = id
	ride.Status = "pending"
	ride.RequestedAt = &now
	ride.CreatedAt = now
	ride.UpdatedAt = now
	m.rides[id] = ride
	return nil
}

func (m *MockRideRepo) FindByID(id string) (*model.Ride, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.rides[id]
	if !ok {
		return nil, fmt.Errorf("load ride: %w", repository.ErrNotFound)
	}
	cp := *r
	return &cp, nil
}

func (m *MockRideRepo) FindCurrentRideByRider(riderID string) (*model.Ride, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var latest *model.Ride
	for _, r := range m.rides {
		if r.RiderID == riderID && (r.Status == "pending" || r.Status == "accepted" || r.Status == "driver_arrived" || r.Status == "in_progress") {
			if latest == nil || r.CreatedAt.After(latest.CreatedAt) {
				cp := *r
				latest = &cp
			}
		}
	}
	if latest == nil {
		return nil, fmt.Errorf("load active ride: %w", repository.ErrNotFound)
	}
	return latest, nil
}

func (m *MockRideRepo) FindCurrentRideByDriver(driverID string) (*model.Ride, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var latest *model.Ride
	for _, r := range m.rides {
		if r.DriverID != nil && *r.DriverID == driverID && (r.Status == "accepted" || r.Status == "driver_arrived" || r.Status == "in_progress") {
			if latest == nil || r.CreatedAt.After(latest.CreatedAt) {
				cp := *r
				latest = &cp
			}
		}
	}
	if latest == nil {
		return nil, fmt.Errorf("load active ride: %w", repository.ErrNotFound)
	}
	return latest, nil
}

func (m *MockRideRepo) FindRidesByRider(riderID string, limit, offset int) ([]model.Ride, int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var matched []model.Ride
	for _, r := range m.rides {
		if r.RiderID == riderID {
			matched = append(matched, *r)
		}
	}
	total := len(matched)
	// Sort by created_at desc (simple bubble)
	for i := 0; i < len(matched); i++ {
		for j := i + 1; j < len(matched); j++ {
			if matched[j].CreatedAt.After(matched[i].CreatedAt) {
				matched[i], matched[j] = matched[j], matched[i]
			}
		}
	}
	if offset >= len(matched) {
		return nil, total, nil
	}
	end := offset + limit
	if end > len(matched) {
		end = len(matched)
	}
	return matched[offset:end], total, nil
}

func (m *MockRideRepo) FindRidesByDriver(driverID string, limit, offset int) ([]model.Ride, int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var matched []model.Ride
	for _, r := range m.rides {
		if r.DriverID != nil && *r.DriverID == driverID {
			matched = append(matched, *r)
		}
	}
	total := len(matched)
	for i := 0; i < len(matched); i++ {
		for j := i + 1; j < len(matched); j++ {
			if matched[j].CreatedAt.After(matched[i].CreatedAt) {
				matched[i], matched[j] = matched[j], matched[i]
			}
		}
	}
	if offset >= len(matched) {
		return nil, total, nil
	}
	end := offset + limit
	if end > len(matched) {
		end = len(matched)
	}
	return matched[offset:end], total, nil
}

func (m *MockRideRepo) UpdateRideStatus(rideID, status string, timestamp *time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.rides[rideID]
	if !ok {
		return fmt.Errorf("load ride: %w", repository.ErrNotFound)
	}
	r.Status = status
	r.UpdatedAt = time.Now()
	ts := timestamp
	if ts == nil {
		t := time.Now()
		ts = &t
	}
	switch status {
	case "accepted":
		r.AcceptedAt = ts
	case "driver_arrived":
		r.DriverArrivedAt = ts
	case "in_progress":
		r.StartedAt = ts
	case "completed":
		r.CompletedAt = ts
	case "cancelled":
		r.CancelledAt = ts
	}
	return nil
}

func (m *MockRideRepo) AssignDriver(rideID, driverID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.rides[rideID]
	if !ok {
		return fmt.Errorf("load ride: %w", repository.ErrNotFound)
	}
	if r.Status != "pending" {
		return fmt.Errorf("update ride status: %w", repository.ErrConflict)
	}
	now := time.Now()
	r.DriverID = &driverID
	r.Status = "accepted"
	r.AcceptedAt = &now
	r.UpdatedAt = now
	return nil
}

func (m *MockRideRepo) CreateEvent(event *model.RideEvent) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	event.ID = newID()
	event.CreatedAt = time.Now()
	m.events = append(m.events, event)
	return nil
}

func (m *MockRideRepo) CreateRating(rating *model.Rating) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	rating.ID = newID()
	rating.CreatedAt = time.Now()
	m.ratings = append(m.ratings, rating)
	return nil
}

func (m *MockRideRepo) FindVehicleByDriverID(driverID string) (*model.DriverVehicle, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.vehicles[driverID]
	if !ok {
		m.vehicles[driverID] = &model.DriverVehicle{
			ID:          newID(),
			DriverID:    driverID,
			Make:        "Toyota",
			Model:       "Camry",
			Color:       "White",
			PlateNumber: "ABC-1234",
			IsActive:    true,
			CreatedAt:   time.Now(),
			UpdatedAt:   time.Now(),
		}
		cp := *m.vehicles[driverID]
		return &cp, nil
	}
	cp := *v
	return &cp, nil
}

// --- MockGeoRepo ---

type driverPosEntry struct {
	lat, lng, heading, speed float64
	status                   string
	updatedAt                time.Time
}

type riderPosEntry struct {
	lat, lng  float64
	updatedAt time.Time
}

type MockGeoRepo struct {
	mu      sync.Mutex
	drivers map[string]*driverPosEntry
	riders  map[string]*riderPosEntry

	// FabricateNearbyDriver makes FindNearbyDrivers invent a driver when no
	// real one is online, so the dispatch goroutine does not flip the ride to
	// no_driver_available mid-test. That hides every real way a driver can
	// become unfindable (never pushed a fix, push went stale, not WS-connected),
	// which is exactly the "rider requests a ride, driver never sees the offer"
	// bug class. Keep it on for legacy tests; use NewStrictMockGeoRepo (and the
	// dispatch_offer_test.go suite) to assert the real chain.
	//
	// It mirrors the production query, which has no such fallback
	// (internal/repository/geo_repo.go:61-87).
	FabricateNearbyDriver bool

	// FailNext, when non-nil, is returned by the next write operation and then
	// cleared. It makes the Upsert{Driver,Rider}Position write-failure branches
	// reachable: the real repositories return a driver error from Exec.
	FailNext error
}

func NewMockGeoRepo() *MockGeoRepo {
	return &MockGeoRepo{
		drivers:               make(map[string]*driverPosEntry),
		riders:                make(map[string]*riderPosEntry),
		FabricateNearbyDriver: true,
	}
}

// NewStrictMockGeoRepo returns a repo that never fabricates a driver: a ride
// is only dispatched to a driver that actually went online, pushed a location
// inside the 30s liveness window, and is within the search radius.
func NewStrictMockGeoRepo() *MockGeoRepo {
	m := NewMockGeoRepo()
	m.FabricateNearbyDriver = false
	return m
}

// AgeDriverPosition backdates a driver's last fix so the 30s staleness filter
// (the same INTERVAL the real query uses) excludes them. Used to pin the rule
// that a driver who stops moving stops being dispatchable.
func (m *MockGeoRepo) AgeDriverPosition(driverID string, age time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if d, ok := m.drivers[driverID]; ok {
		d.updatedAt = time.Now().Add(-age)
	}
}

// DriverIDs returns the ids of every driver with a recorded position, in no
// particular order.
func (m *MockGeoRepo) DriverIDs() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.drivers))
	for id := range m.drivers {
		ids = append(ids, id)
	}
	return ids
}

func (m *MockGeoRepo) UpsertDriverPosition(driverID string, lat, lng, heading, speed float64, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	m.drivers[driverID] = &driverPosEntry{
		lat: lat, lng: lng, heading: heading, speed: speed,
		status: status, updatedAt: time.Now(),
	}
	return nil
}

func (m *MockGeoRepo) UpsertRiderPosition(riderID string, lat, lng float64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := failNext(&m.FailNext); err != nil {
		return err
	}
	m.riders[riderID] = &riderPosEntry{
		lat: lat, lng: lng, updatedAt: time.Now(),
	}
	return nil
}

func (m *MockGeoRepo) FindNearbyDrivers(lat, lng float64, radiusM float64, limit int) ([]model.NearbyDriverResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var results []model.NearbyDriverResult
	for id, d := range m.drivers {
		if d.status != "online" {
			continue
		}
		if time.Since(d.updatedAt) > 30*time.Second {
			continue
		}
		dist := haversine(lat, lng, d.lat, d.lng) * 1000
		if dist > radiusM {
			continue
		}
		results = append(results, model.NearbyDriverResult{
			DriverID:  id,
			Lat:       d.lat,
			Lng:       d.lng,
			Heading:   d.heading,
			Speed:     d.speed,
			DistanceM: dist,
		})
	}
	// If no known online drivers exist, simulate one nearby so that
	// the dispatch goroutine does not set the ride to no_driver_available
	// before the test can accept it (avoids a mock-speed race that does
	// not happen with a real database).
	if len(results) == 0 && m.FabricateNearbyDriver {
		results = append(results, model.NearbyDriverResult{
			DriverID:  "simulated-driver",
			Lat:       lat + 0.001,
			Lng:       lng + 0.001,
			Heading:   90,
			Speed:     0,
			DistanceM: 150,
		})
	}
	if len(results) > limit {
		results = results[:limit]
	}
	return results, nil
}

func (m *MockGeoRepo) GetDriverLocation(driverID string) (*model.NearbyDriverResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.drivers[driverID]
	if !ok {
		return nil, fmt.Errorf("load driver location: %w", repository.ErrNotFound)
	}
	return &model.NearbyDriverResult{
		DriverID: driverID,
		Lat:      d.lat,
		Lng:      d.lng,
		Heading:  d.heading,
		Speed:    d.speed,
	}, nil
}

func (m *MockGeoRepo) CountNearbyDrivers(lat, lng float64, radiusM float64) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	count := 0
	for _, d := range m.drivers {
		if d.status != "online" {
			continue
		}
		if time.Since(d.updatedAt) > 30*time.Second {
			continue
		}
		dist := haversine(lat, lng, d.lat, d.lng) * 1000
		if dist <= radiusM {
			count++
		}
	}
	return count, nil
}

func (m *MockGeoRepo) MarkStaleDriversOffline() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, d := range m.drivers {
		if d.status == "online" && time.Since(d.updatedAt) > 30*time.Second {
			d.status = "offline"
		}
	}
	return nil
}

func haversine(lat1, lng1, lat2, lng2 float64) float64 {
	const R = 6371
	dLat := (lat2 - lat1) * math.Pi / 180
	dLng := (lng2 - lng1) * math.Pi / 180
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*math.Pi/180)*math.Cos(lat2*math.Pi/180)*
			math.Sin(dLng/2)*math.Sin(dLng/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return R * c
}
