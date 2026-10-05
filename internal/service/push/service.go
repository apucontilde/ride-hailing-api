package push

import (
	"context"
	"log"
	"time"

	"ride-hailing-api/internal/model"
)

// TokenLister is the read seam the push service needs. It is deliberately
// narrow so the concrete repository stays behind it (and so the service is
// testable without a database). repository.DeviceTokenRepository satisfies it.
type TokenLister interface {
	ListActiveTokens(userID string) ([]model.DeviceToken, error)
}

// defaultSendTimeout bounds one fan-out burst. It exists so a hung provider
// cannot hold a caller's goroutine forever.
const defaultSendTimeout = 5 * time.Second

// Service fans a message out to every active token of a user.
//
// NotifyUser is the whole public surface and it returns NOTHING: by
// construction a push can never fail, delay a return value, or bubble a
// provider error into a ride transition. Every failure is logged.
type Service struct {
	tokens   TokenLister
	provider Provider
	timeout  time.Duration
}

func NewService(tokens TokenLister, provider Provider) *Service {
	return &Service{tokens: tokens, provider: provider, timeout: defaultSendTimeout}
}

// NotifyUser delivers msg to every active token for userID.
//
// It is nil-safe: a nil service, a nil token source or a nil provider simply
// drops the notification. This matters because the ride service is constructed
// in tests (and by the db-less harnesses) without a push service, and a push
// misconfiguration must never panic a request.
func (s *Service) NotifyUser(userID string, msg Message) {
	if s == nil || s.tokens == nil || s.provider == nil || userID == "" {
		return
	}

	tokens, err := s.tokens.ListActiveTokens(userID)
	if err != nil {
		log.Printf("push: list active tokens for user %s failed: %v", userID, err)
		return
	}
	if len(tokens) == 0 {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
	defer cancel()

	for _, t := range tokens {
		if err := s.provider.Send(ctx, t.Token, t.Platform, msg); err != nil {
			// Best-effort: keep going with the user's other devices.
			log.Printf("push: send failed user=%s platform=%s: %v", userID, t.Platform, err)
		}
	}
}
