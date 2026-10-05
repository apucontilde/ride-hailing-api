// Package push is the backgrounded push-notification pipeline: an injectable
// provider abstraction over FCM/APNs/web plus a best-effort fan-out service.
//
// Delivery is ANCILLARY. Nothing in this package returns an error to a caller
// that is performing an authoritative action, and the credential-free default
// provider is a log-and-continue no-op. That is what makes a push outage
// unable to fail a ride transition.
package push

import (
	"context"
	"log"
)

// Message is a platform-agnostic notification payload. Data is a flat string
// map because FCM/APNs data payloads are string-valued.
type Message struct {
	Title string
	Body  string
	Data  map[string]string
}

// Provider delivers one Message to one device token. Implementations are
// expected to do network I/O and MUST return an error when delivery fails;
// the caller (Service) logs it and moves on.
type Provider interface {
	Send(ctx context.Context, token, platform string, msg Message) error
}

// ProviderFunc adapts a function to Provider, for tests and tiny clients.
type ProviderFunc func(ctx context.Context, token, platform string, msg Message) error

func (f ProviderFunc) Send(ctx context.Context, token, platform string, msg Message) error {
	return f(ctx, token, platform, msg)
}

// LogProvider is the shipped default when no push credentials are configured.
// It never performs I/O and never fails, so the pipeline is safe to install
// before any FCM/APNs client exists.
type LogProvider struct{}

func NewLogProvider() *LogProvider { return &LogProvider{} }

func (p *LogProvider) Send(_ context.Context, token, platform string, msg Message) error {
	log.Printf("push: no provider configured; dropping notification platform=%s token=%s title=%q",
		platform, maskToken(token), msg.Title)
	return nil
}

// MultiProvider routes a message by platform, with an optional fallback for an
// unknown platform. This is the seam a real deployment uses to install an FCM
// client for "android", an APNs client for "ios" and a web client for "web";
// with no provider installed for a platform the send is a successful no-op
// (nil provider), never a failure.
type MultiProvider struct {
	byPlatform map[string]Provider
	fallback   Provider
}

func NewMultiProvider(byPlatform map[string]Provider, fallback Provider) *MultiProvider {
	return &MultiProvider{byPlatform: byPlatform, fallback: fallback}
}

func (m *MultiProvider) Send(ctx context.Context, token, platform string, msg Message) error {
	provider := m.byPlatform[platform]
	if provider == nil {
		provider = m.fallback
	}
	if provider == nil {
		return nil
	}
	return provider.Send(ctx, token, platform, msg)
}

// maskToken keeps device tokens out of the logs in full while still making a
// line recognizable.
func maskToken(token string) string {
	const keep = 8
	if len(token) <= keep {
		return token
	}
	return token[:keep] + "…"
}
