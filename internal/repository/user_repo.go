package repository

import (
	"fmt"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

type UserRepository interface {
	CreateUser(u *model.User) error
	FindByEmail(email string) (*model.User, error)
	FindByID(id string) (*model.User, error)
	UpdateUser(u *model.User) error
	CreateRider(rider *model.Rider) error
	FindRiderByID(userID string) (*model.Rider, error)
	UpdateRider(rider *model.Rider) error
	CreateDriver(driver *model.Driver) error
	FindDriverByID(userID string) (*model.Driver, error)
	UpdateDriver(driver *model.Driver) error
	SoftDeleteUser(userID string) error
	CreateRefreshToken(token *model.RefreshToken) error
	FindRefreshTokenByHash(hash string) (*model.RefreshToken, error)
	RevokeRefreshToken(id string) error
	CreatePasswordResetToken(token *model.PasswordResetToken) error
	FindPasswordResetTokenByHash(hash string) (*model.PasswordResetToken, error)
	RevokePasswordResetToken(id string) error
	RevokeUserPasswordResetTokens(userID string) error
}

var _ UserRepository = (*UserRepo)(nil)

type UserRepo struct {
	db *sqlx.DB
}

func NewUserRepo(db *sqlx.DB) *UserRepo {
	return &UserRepo{db: db}
}

func (r *UserRepo) CreateUser(u *model.User) error {
	query := `
		INSERT INTO users (email, phone, password_hash, role, email_verified, phone_verified, status)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, created_at, updated_at`
	return r.db.QueryRow(query, u.Email, u.Phone, u.PasswordHash, u.Role,
		u.EmailVerified, u.PhoneVerified, u.Status).
		Scan(&u.ID, &u.CreatedAt, &u.UpdatedAt)
}

func (r *UserRepo) FindByEmail(email string) (*model.User, error) {
	u := &model.User{}
	err := r.db.Get(u, "SELECT * FROM users WHERE email = $1", email)
	if err != nil {
		return nil, fmt.Errorf("user not found: %w", err)
	}
	return u, nil
}

func (r *UserRepo) FindByID(id string) (*model.User, error) {
	u := &model.User{}
	err := r.db.Get(u, "SELECT * FROM users WHERE id = $1", id)
	if err != nil {
		return nil, fmt.Errorf("user not found: %w", err)
	}
	return u, nil
}

func (r *UserRepo) UpdateUser(u *model.User) error {
	_, err := r.db.Exec(`
		UPDATE users SET email=$1, phone=$2, password_hash=$3, email_verified=$4,
		phone_verified=$5, status=$6, role=$7, updated_at=NOW() WHERE id=$8`,
		u.Email, u.Phone, u.PasswordHash, u.EmailVerified,
		u.PhoneVerified, u.Status, u.Role, u.ID)
	return err
}

func (r *UserRepo) CreateRider(rider *model.Rider) error {
	_, err := r.db.Exec(`
		INSERT INTO riders (user_id, first_name, last_name, status)
		VALUES ($1, $2, $3, $4)`,
		rider.UserID, rider.FirstName, rider.LastName, rider.Status)
	return err
}

func (r *UserRepo) FindRiderByID(userID string) (*model.Rider, error) {
	rd := &model.Rider{}
	err := r.db.Get(rd, "SELECT * FROM riders WHERE user_id = $1", userID)
	if err != nil {
		return nil, fmt.Errorf("rider not found: %w", err)
	}
	return rd, nil
}

func (r *UserRepo) UpdateRider(rider *model.Rider) error {
	_, err := r.db.Exec(`
		UPDATE riders SET first_name=$1, last_name=$2, photo_url=$3,
		status=$4, updated_at=NOW() WHERE user_id=$5`,
		rider.FirstName, rider.LastName, rider.PhotoURL, rider.Status, rider.UserID)
	return err
}

func (r *UserRepo) CreateDriver(driver *model.Driver) error {
	_, err := r.db.Exec(`
		INSERT INTO drivers (user_id, first_name, last_name, status, onboarding_status)
		VALUES ($1, $2, $3, $4, $5)`,
		driver.UserID, driver.FirstName, driver.LastName, driver.Status, driver.OnboardingStatus)
	return err
}

func (r *UserRepo) FindDriverByID(userID string) (*model.Driver, error) {
	d := &model.Driver{}
	err := r.db.Get(d, "SELECT * FROM drivers WHERE user_id = $1", userID)
	if err != nil {
		return nil, fmt.Errorf("driver not found: %w", err)
	}
	return d, nil
}

func (r *UserRepo) UpdateDriver(driver *model.Driver) error {
	_, err := r.db.Exec(`
		UPDATE drivers SET first_name=$1, last_name=$2, photo_url=$3,
		status=$4, updated_at=NOW() WHERE user_id=$5`,
		driver.FirstName, driver.LastName, driver.PhotoURL, driver.Status, driver.UserID)
	return err
}

func (r *UserRepo) SoftDeleteUser(userID string) error {
	_, err := r.db.Exec("UPDATE users SET status='deleted', updated_at=NOW() WHERE id=$1", userID)
	return err
}

func (r *UserRepo) CreateRefreshToken(token *model.RefreshToken) error {
	_, err := r.db.Exec(`
		INSERT INTO refresh_tokens (user_id, token_hash, expires_at)
		VALUES ($1, $2, $3)`,
		token.UserID, token.TokenHash, token.ExpiresAt)
	return err
}

func (r *UserRepo) FindRefreshTokenByHash(hash string) (*model.RefreshToken, error) {
	t := &model.RefreshToken{}
	err := r.db.Get(t, "SELECT * FROM refresh_tokens WHERE token_hash = $1 AND revoked = FALSE LIMIT 1", hash)
	if err != nil {
		return nil, fmt.Errorf("refresh token not found: %w", err)
	}
	return t, nil
}

func (r *UserRepo) RevokeRefreshToken(id string) error {
	_, err := r.db.Exec("UPDATE refresh_tokens SET revoked = TRUE WHERE id = $1", id)
	return err
}

func (r *UserRepo) CreatePasswordResetToken(token *model.PasswordResetToken) error {
	_, err := r.db.Exec(`
		INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
		VALUES ($1, $2, $3)`,
		token.UserID, token.TokenHash, token.ExpiresAt)
	return err
}

func (r *UserRepo) FindPasswordResetTokenByHash(hash string) (*model.PasswordResetToken, error) {
	t := &model.PasswordResetToken{}
	err := r.db.Get(t, "SELECT * FROM password_reset_tokens WHERE token_hash = $1 AND used = FALSE LIMIT 1", hash)
	if err != nil {
		return nil, fmt.Errorf("password reset token not found: %w", err)
	}
	return t, nil
}

func (r *UserRepo) RevokePasswordResetToken(id string) error {
	_, err := r.db.Exec("UPDATE password_reset_tokens SET used = TRUE WHERE id = $1", id)
	return err
}

func (r *UserRepo) RevokeUserPasswordResetTokens(userID string) error {
	_, err := r.db.Exec("UPDATE password_reset_tokens SET used = TRUE WHERE user_id = $1 AND used = FALSE", userID)
	return err
}
