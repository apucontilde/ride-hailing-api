package service

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type AuthService struct {
	cfg      *config.Config
	userRepo repository.UserRepository
}

// ErrTokenRevoke marks a repository failure while revoking a token. Every
// other error in this file is a client mistake and is answered 4xx; a failure
// here is a backend outage and must be answered 5xx without echoing the driver
// error back to the caller. api_plans [errors] stage 01 replaces this ad-hoc
// sentinel with the full taxonomy.
var ErrTokenRevoke = errors.New("token revocation failed")

// ErrInvalidCredentials marks a login attempt with wrong credentials (unknown
// email or wrong password, deliberately indistinguishable). The handler maps
// only this sentinel to 401; every other Login error is an internal failure
// (e.g. a database outage) and becomes a 500, so an outage can no longer
// masquerade as "invalid credentials".
var ErrInvalidCredentials = errors.New("invalid credentials")

// ErrInvalidRefreshToken marks a refresh attempt whose token is not usable:
// unknown, expired, or already revoked. Only this sentinel maps to 401; any
// wrapped repository failure (e.g. the fail-closed RevokeRefreshToken) falls
// through to a 500 with the driver error in the log, not the body.
var ErrInvalidRefreshToken = errors.New("invalid or expired refresh token")

// ErrInvalidResetToken marks a reset attempt whose token is not usable:
// unknown, expired, or already consumed. Only this sentinel maps to 400; any
// wrapped repository failure (e.g. the fail-closed RevokePasswordResetToken)
// falls through to a 500 with the driver error in the log, not the body.
var ErrInvalidResetToken = errors.New("invalid or expired reset token")

func NewAuthService(cfg *config.Config, userRepo repository.UserRepository) *AuthService {
	return &AuthService{cfg: cfg, userRepo: userRepo}
}

type TokenClaims struct {
	UserID string `json:"sub"`
	Role   string `json:"role"`
	jwt.RegisteredClaims
}

type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

func (s *AuthService) Register(email, phone, password string) (*model.User, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, fmt.Errorf("failed to hash password: %w", err)
	}

	user := &model.User{
		Email:        email,
		Phone:        phone,
		PasswordHash: string(hash),
		Role:         "rider",
		Status:       "active",
	}

	if err := s.userRepo.CreateUser(user); err != nil {
		return nil, fmt.Errorf("failed to create user: %w", err)
	}

	rider := &model.Rider{UserID: user.ID, Status: "idle"}
	if err := s.userRepo.CreateRider(rider); err != nil {
		return nil, fmt.Errorf("failed to create rider profile: %w", err)
	}

	return user, nil
}

func (s *AuthService) Login(email, password string) (*TokenPair, *model.User, error) {
	user, err := s.userRepo.FindByEmail(email)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return nil, nil, ErrInvalidCredentials
		}
		return nil, nil, fmt.Errorf("failed to load user: %w", err)
	}

	if user.Status == "deleted" || user.Status == "suspended" {
		return nil, nil, errors.New("account is disabled")
	}

	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)) != nil {
		return nil, nil, ErrInvalidCredentials
	}

	tokens, refreshModel, err := s.generateTokenPair(user.ID, user.Role)
	if err != nil {
		return nil, nil, err
	}

	if err := s.userRepo.CreateRefreshToken(refreshModel); err != nil {
		return nil, nil, fmt.Errorf("failed to store refresh token: %w", err)
	}

	return tokens, user, nil
}

func (s *AuthService) RefreshAccessToken(refreshTokenStr string) (*TokenPair, error) {
	hash := hashToken(refreshTokenStr)
	stored, err := s.userRepo.FindRefreshTokenByHash(hash)
	if err != nil {
		return nil, ErrInvalidRefreshToken
	}

	if time.Now().After(stored.ExpiresAt) {
		return nil, ErrInvalidRefreshToken
	}

	if stored.Revoked {
		return nil, ErrInvalidRefreshToken
	}

	user, err := s.userRepo.FindByID(stored.UserID)
	if err != nil {
		return nil, errors.New("user not found")
	}

	if revokeErr := s.userRepo.RevokeRefreshToken(stored.ID); revokeErr != nil {
		return nil, fmt.Errorf("%w: failed to revoke refresh token: %w", ErrTokenRevoke, revokeErr)
	}

	tokens, refreshModel, err := s.generateTokenPair(user.ID, user.Role)
	if err != nil {
		return nil, err
	}

	if err := s.userRepo.CreateRefreshToken(refreshModel); err != nil {
		return nil, fmt.Errorf("failed to store refresh token: %w", err)
	}

	return tokens, nil
}

func (s *AuthService) Logout(refreshTokenStr string) error {
	hash := hashToken(refreshTokenStr)
	stored, err := s.userRepo.FindRefreshTokenByHash(hash)
	if err != nil {
		return nil
	}

	return s.userRepo.RevokeRefreshToken(stored.ID)
}

func (s *AuthService) ValidateAccessToken(tokenStr string) (*TokenClaims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &TokenClaims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(s.cfg.JWTSecret), nil
	})
	if err != nil {
		return nil, err
	}

	claims, ok := token.Claims.(*TokenClaims)
	if !ok || !token.Valid {
		return nil, errors.New("invalid token")
	}

	return claims, nil
}

func (s *AuthService) generateTokenPair(userID, role string) (*TokenPair, *model.RefreshToken, error) {
	now := time.Now()

	// `jti` is random rather than a timestamp. The rest of the claims have
	// only second granularity, so a timestamp-derived `jti` made every token
	// minted inside the same clock tick byte-identical: a login immediately
	// followed by a refresh returned the *same* access token, and any
	// `jti`-keyed revocation or replay tracking would treat them as one
	// token. Windows' coarse clock (~0.5-15ms) made that an intermittent test
	// failure; it is a latent identity collision in production too.
	jti, err := generateRandomToken(16)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to generate token id: %w", err)
	}

	accessClaims := &TokenClaims{
		UserID: userID,
		Role:   role,
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        jti,
			ExpiresAt: jwt.NewNumericDate(now.Add(s.cfg.JWTAccessTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
		},
	}

	accessToken, err := jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims).SignedString([]byte(s.cfg.JWTSecret))
	if err != nil {
		return nil, nil, fmt.Errorf("failed to sign access token: %w", err)
	}

	refreshToken, err := generateRandomToken(32)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to generate refresh token: %w", err)
	}

	refreshModel := &model.RefreshToken{
		UserID:    userID,
		TokenHash: hashToken(refreshToken),
		ExpiresAt: now.Add(s.cfg.JWTRefreshTTL),
	}

	return &TokenPair{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
	}, refreshModel, nil
}

func generateRandomToken(length int) (string, error) {
	bytes := make([]byte, length)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func (s *AuthService) ForgotPassword(email string) (string, error) {
	user, err := s.userRepo.FindByEmail(email)
	if err != nil {
		return "", nil
	}

	token, err := generateRandomToken(32)
	if err != nil {
		return "", fmt.Errorf("failed to generate reset token: %w", err)
	}

	if err := s.userRepo.RevokeUserPasswordResetTokens(user.ID); err != nil {
		return "", fmt.Errorf("%w: failed to revoke previous reset tokens: %w", ErrTokenRevoke, err)
	}

	resetModel := &model.PasswordResetToken{
		UserID:    user.ID,
		TokenHash: hashToken(token),
		ExpiresAt: time.Now().Add(15 * time.Minute),
	}

	if err := s.userRepo.CreatePasswordResetToken(resetModel); err != nil {
		return "", fmt.Errorf("failed to store reset token: %w", err)
	}

	return token, nil
}

func (s *AuthService) ResetPassword(tokenStr, newPassword string) error {
	hash := hashToken(tokenStr)
	stored, err := s.userRepo.FindPasswordResetTokenByHash(hash)
	if err != nil {
		return ErrInvalidResetToken
	}

	if time.Now().After(stored.ExpiresAt) {
		return ErrInvalidResetToken
	}

	passwordHash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("failed to hash password: %w", err)
	}

	// Fail closed: if the consumed token cannot be revoked it would stay
	// reusable, so abort before the password is changed.
	if revokeErr := s.userRepo.RevokePasswordResetToken(stored.ID); revokeErr != nil {
		return fmt.Errorf("%w: failed to revoke reset token: %w", ErrTokenRevoke, revokeErr)
	}

	user, err := s.userRepo.FindByID(stored.UserID)
	if err != nil {
		return errors.New("user not found")
	}

	user.PasswordHash = string(passwordHash)
	return s.userRepo.UpdateUser(user)
}

func (s *AuthService) VerifyEmail(userID, code string) error {
	_ = code
	user, err := s.userRepo.FindByID(userID)
	if err != nil {
		return err
	}
	user.EmailVerified = true
	return s.userRepo.UpdateUser(user)
}

func (s *AuthService) VerifyPhone(userID, code string) error {
	_ = code
	user, err := s.userRepo.FindByID(userID)
	if err != nil {
		return err
	}
	user.PhoneVerified = true
	return s.userRepo.UpdateUser(user)
}

func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
