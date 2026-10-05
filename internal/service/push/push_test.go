package push

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"ride-hailing-api/internal/model"
)

// recordingProvider captures every send so a test can assert exactly which
// token received what. It can be made to fail, which is how the
// "a provider error must not surface" rule is exercised.
type recordingProvider struct {
	mu   sync.Mutex
	sent []sentMessage
	err  error
}

type sentMessage struct {
	token    string
	platform string
	msg      Message
}

func (p *recordingProvider) Send(_ context.Context, token, platform string, msg Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sent = append(p.sent, sentMessage{token: token, platform: platform, msg: msg})
	return p.err
}

func (p *recordingProvider) messages() []sentMessage {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]sentMessage(nil), p.sent...)
}

// routingProvider is a token lister whose state can be reassigned, mirroring
// the production global-uniqueness contract: one token, one current owner.
type routingProvider struct {
	mu    sync.Mutex
	owner map[string]string // token -> userID
	order []string          // stable token order
	err   error
}

func newRoutingProvider() *routingProvider {
	return &routingProvider{owner: map[string]string{}}
}

func (r *routingProvider) register(userID, token string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.owner[token]; !ok {
		r.order = append(r.order, token)
	}
	r.owner[token] = userID
}

func (r *routingProvider) ListActiveTokens(userID string) ([]model.DeviceToken, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err != nil {
		return nil, r.err
	}
	var out []model.DeviceToken
	for _, token := range r.order {
		if r.owner[token] == userID {
			out = append(out, model.DeviceToken{Token: token, Platform: "android", IsActive: true})
		}
	}
	if out == nil {
		out = []model.DeviceToken{}
	}
	return out, nil
}

func TestLogProviderIsASafeNoOp(t *testing.T) {
	if err := NewLogProvider().Send(context.Background(), "token", "android", Message{Title: "x"}); err != nil {
		t.Fatalf("LogProvider.Send returned %v, want nil (credential-free default must never fail)", err)
	}
}

func TestMultiProviderRoutesByPlatformWithFallback(t *testing.T) {
	var android, apple, fallback int
	provider := NewMultiProvider(map[string]Provider{
		"android": ProviderFunc(func(context.Context, string, string, Message) error { android++; return nil }),
		"ios":     ProviderFunc(func(context.Context, string, string, Message) error { apple++; return nil }),
	}, ProviderFunc(func(context.Context, string, string, Message) error { fallback++; return nil }))

	_ = provider.Send(context.Background(), "t", "android", Message{})
	_ = provider.Send(context.Background(), "t", "ios", Message{})
	_ = provider.Send(context.Background(), "t", "web", Message{})
	if android != 1 || apple != 1 || fallback != 1 {
		t.Fatalf("routing = android:%d ios:%d fallback:%d, want 1/1/1", android, apple, fallback)
	}
}

func TestNotifyUserDeliversOnlyToTheUsersActiveTokens(t *testing.T) {
	lister := newRoutingProvider()
	lister.register("user-a", "token-a")
	lister.register("user-b", "token-b")
	provider := &recordingProvider{}

	NewService(lister, provider).NotifyUser("user-a", Message{Title: "hi"})

	got := provider.messages()
	if len(got) != 1 || got[0].token != "token-a" {
		t.Fatalf("delivered %+v, want exactly token-a (a token registered for B must not receive A's push)", got)
	}
}

func TestReassignedTokenStopsDeliveringToThePreviousOwner(t *testing.T) {
	lister := newRoutingProvider()
	lister.register("user-a", "shared")
	provider := &recordingProvider{}
	svc := NewService(lister, provider)

	svc.NotifyUser("user-a", Message{Title: "before"})

	// The same device signs in as user B: the token MOVES.
	lister.register("user-b", "shared")

	svc.NotifyUser("user-a", Message{Title: "after-move"})
	if n := len(provider.messages()); n != 1 {
		t.Fatalf("user-a received %d pushes after the token moved to B, want 1 (only the pre-move one)", n)
	}

	svc.NotifyUser("user-b", Message{Title: "after-move"})
	got := provider.messages()
	if len(got) != 2 || got[1].msg.Title != "after-move" {
		t.Fatalf("deliveries after reassignment = %+v, want the second one addressed to B", got)
	}
}

func TestNotifyUserSwallowsProviderErrorAndKeepsGoing(t *testing.T) {
	lister := newRoutingProvider()
	lister.register("user-a", "token-1")
	lister.register("user-a", "token-2")
	provider := &recordingProvider{err: errors.New("fcm: 503 unavailable")}

	// Must not panic, block, or return anything: the interface is void on
	// purpose so a provider outage cannot fail the authoritative action.
	NewService(lister, provider).NotifyUser("user-a", Message{Title: "hi"})

	if len(provider.messages()) != 2 {
		t.Fatalf("provider called %d times, want 2 (one failure must not stop the other device)", len(provider.messages()))
	}
}

func TestNotifyUserLookupFailureIsSwallowed(t *testing.T) {
	lister := newRoutingProvider()
	lister.err = errors.New("database unavailable")
	NewService(lister, &recordingProvider{}).NotifyUser("user-a", Message{Title: "hi"})
}

func TestNotifyUserIsNilSafe(t *testing.T) {
	var nilService *Service
	nilService.NotifyUser("user-a", Message{Title: "hi"})
	NewService(nil, &recordingProvider{}).NotifyUser("user-a", Message{Title: "hi"})
	NewService(newRoutingProvider(), nil).NotifyUser("user-a", Message{Title: "hi"})
}

func TestMaskTokenDoesNotLeakTheFullToken(t *testing.T) {
	const token = "abcdefgh-super-secret-device-token"
	masked := maskToken(token)
	if strings.Contains(masked, "super-secret") {
		t.Fatalf("maskToken(%q) = %q leaks the token tail", token, masked)
	}
	if !strings.HasPrefix(masked, "abcdefgh") {
		t.Fatalf("maskToken(%q) = %q, want the recognizable prefix", token, masked)
	}
}
