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
	cfg    *config.Config
	userRepo repository.UserRepository
}

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
		return nil, nil, errors.New("invalid credentials")
	}

	if user.Status == "deleted" || user.Status == "suspended" {
		return nil, nil, errors.New("account is disabled")
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		return nil, nil, errors.New("invalid credentials")
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
		return nil, errors.New("invalid or expired refresh token")
	}

	if time.Now().After(stored.ExpiresAt) {
		return nil, errors.New("refresh token expired")
	}

	if stored.Revoked {
		return nil, errors.New("refresh token revoked")
	}

	user, err := s.userRepo.FindByID(stored.UserID)
	if err != nil {
		return nil, errors.New("user not found")
	}

	s.userRepo.RevokeRefreshToken(stored.ID)

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
	accessClaims := &TokenClaims{
		UserID: userID,
		Role:   role,
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        fmt.Sprintf("%d", now.UnixNano()),
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

	s.userRepo.RevokeUserPasswordResetTokens(user.ID)

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
		return errors.New("invalid or expired reset token")
	}

	if time.Now().After(stored.ExpiresAt) {
		return errors.New("reset token expired")
	}

	passwordHash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("failed to hash password: %w", err)
	}

	s.userRepo.RevokePasswordResetToken(stored.ID)

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
