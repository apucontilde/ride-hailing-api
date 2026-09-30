package testutil

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"testing"
	"time"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/service"
)

// TestMockErrorsLockstep pins the lockstep from api_plans [errors] step 3: the
// mocks must return the repository sentinels, not their own invented taxonomy.
// A missed mock fails silently (the suite stays green while asserting behaviour
// that cannot happen in production), so this is enforced by the suite.

func TestMockFindByEmailReturnsErrNotFound(t *testing.T) {
	m := NewMockUserRepo()
	_, err := m.FindByEmail("nobody@example.com")
	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("mock FindByEmail missing user = %v, want ErrNotFound", err)
	}
}

func TestMockCreateUserDuplicateEmailReturnsErrConflict(t *testing.T) {
	m := NewMockUserRepo()
	if err := m.CreateUser(&model.User{Email: "dup@example.com", Phone: "+15550000001"}); err != nil {
		t.Fatalf("first CreateUser failed: %v", err)
	}
	err := m.CreateUser(&model.User{Email: "dup@example.com", Phone: "+15550000002"})
	if !errors.Is(err, repository.ErrConflict) {
		t.Fatalf("mock CreateUser duplicate email = %v, want ErrConflict", err)
	}
}

// TestAuthServiceRejectsExpiredRefreshToken pins the expiry divergence fixed in
// api_plans [errors] step 3: the mock returns the token model (with a past
// ExpiresAt) and the SERVICE rejects it, so the real service-expiry branch is
// the thing under test rather than a mock-side invented error.
func TestAuthServiceRejectsExpiredRefreshToken(t *testing.T) {
	repo := NewMockUserRepo()
	svc := service.NewAuthService(&config.Config{JWTSecret: "test-secret"}, repo)

	// A token whose ExpiresAt is in the past. The repository returns it as-is;
	// the expiry rule lives in AuthService.RefreshAccessToken.
	const plaintext = "some-refresh-token"
	sum := sha256.Sum256([]byte(plaintext))
	if err := repo.CreateRefreshToken(&model.RefreshToken{
		UserID:    "user-1",
		TokenHash: hex.EncodeToString(sum[:]),
		ExpiresAt: time.Now().Add(-time.Minute),
	}); err != nil {
		t.Fatalf("CreateRefreshToken failed: %v", err)
	}

	_, err := svc.RefreshAccessToken(plaintext)
	if err == nil {
		t.Fatal("RefreshAccessToken with an expired token = nil, want error")
	}
	if !errors.Is(err, service.ErrInvalidRefreshToken) {
		t.Fatalf("RefreshAccessToken expired token error = %v, want ErrInvalidRefreshToken", err)
	}
}
