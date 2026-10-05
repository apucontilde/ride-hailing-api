package service

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/service/push"
	"ride-hailing-api/internal/websocket"
)

// staticTokenLister returns one active token for any user, so the push service
// actually attempts a delivery.
type staticTokenLister struct {
	tokens []model.DeviceToken
}

func (l staticTokenLister) ListActiveTokens(string) ([]model.DeviceToken, error) {
	return l.tokens, nil
}

// countingErrorProvider records every Send and answers a fixed error, so a test
// can prove a delivery was ATTEMPTED (not merely that no error propagated).
type countingErrorProvider struct {
	mu    sync.Mutex
	count int
	err   error
}

func (p *countingErrorProvider) Send(context.Context, string, string, push.Message) error {
	p.mu.Lock()
	p.count++
	p.mu.Unlock()
	return p.err
}

func (p *countingErrorProvider) sends() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.count
}

// syncNotifier wraps the real push.Service and signals after each NotifyUser
// returns. NotifyUser is called from a fire-and-forget goroutine by the ride
// service, so without this the test would race it: it might assert before any
// delivery attempt happened. The signal makes "the push was attempted" a
// deterministic observation while adding NOTHING to production code — the
// PushNotifier seam already exists and this is a plain test double.
type syncNotifier struct {
	inner PushNotifier
	ch    chan struct{}
}

func newSyncNotifier(inner PushNotifier) *syncNotifier {
	return &syncNotifier{inner: inner, ch: make(chan struct{}, 8)}
}

func (n *syncNotifier) NotifyUser(userID string, msg push.Message) {
	n.inner.NotifyUser(userID, msg)
	n.ch <- struct{}{}
}

// waitFor blocks until want notifications have returned, failing the test on
// timeout instead of racing the goroutine.
func (n *syncNotifier) waitFor(t *testing.T, want int) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for i := 0; i < want; i++ {
		select {
		case <-n.ch:
		case <-deadline:
			t.Fatalf("timed out waiting for push attempt %d of %d", i+1, want)
		}
	}
}

// TestProviderErrorDoesNotFailRideTransition is the invariant test: push is
// ancillary, so a provider that cannot deliver must never turn a valid status
// transition into an error (or a non-completed ride). It now WAITS for the
// fire-and-forget delivery and asserts it was actually attempted, so the test
// would also fail if the push silently stopped being sent.
func TestProviderErrorDoesNotFailRideTransition(t *testing.T) {
	ride := &model.Ride{ID: "ride-1", RiderID: "rider-1", Status: "in_progress"}
	repo := &stubRideRepo{ride: ride}
	svc := NewRideService(repo, nil, websocket.NewHub(), nil)

	provider := &countingErrorProvider{err: errors.New("fcm: 503 service unavailable")}
	notifier := newSyncNotifier(push.NewService(
		staticTokenLister{tokens: []model.DeviceToken{{Token: "device-1", Platform: "android", IsActive: true}}},
		provider,
	))
	svc.SetPushNotifier(notifier)

	got, err := svc.AdvanceStatus("ride-1", "completed", "driver")
	if err != nil {
		t.Fatalf("AdvanceStatus returned %v; a push failure must never fail the transition", err)
	}
	if got == nil || got.Status != "completed" {
		t.Fatalf("ride = %+v, want status completed", got)
	}

	notifier.waitFor(t, 1)
	if n := provider.sends(); n != 1 {
		t.Fatalf("push attempts = %d, want 1 (the failing provider must have been called)", n)
	}
}

// TestProviderErrorDoesNotFailCancellation pins the same rule on the cancel
// path, which pushes to BOTH parties. It waits for both attempts so a dropped
// driver notification would fail the test.
func TestProviderErrorDoesNotFailCancellation(t *testing.T) {
	driver := "driver-1"
	ride := &model.Ride{ID: "ride-2", RiderID: "rider-1", DriverID: &driver, Status: "accepted"}
	repo := &stubRideRepo{ride: ride}
	svc := NewRideService(repo, nil, websocket.NewHub(), nil)

	provider := &countingErrorProvider{err: errors.New("apns: connection reset")}
	notifier := newSyncNotifier(push.NewService(
		staticTokenLister{tokens: []model.DeviceToken{{Token: "device-1", Platform: "ios", IsActive: true}}},
		provider,
	))
	svc.SetPushNotifier(notifier)

	got, err := svc.CancelRide("ride-2", "rider")
	if err != nil {
		t.Fatalf("CancelRide returned %v; a push failure must never fail the cancellation", err)
	}
	if got == nil || got.Status != "cancelled" {
		t.Fatalf("ride = %+v, want status cancelled", got)
	}

	notifier.waitFor(t, 2)
	if n := provider.sends(); n != 2 {
		t.Fatalf("push attempts = %d, want 2 (rider and driver)", n)
	}
}
