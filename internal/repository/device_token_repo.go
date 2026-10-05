package repository

import (
	"context"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

// DeviceTokenRepository persists push-notification device tokens.
//
// `token` is GLOBALLY unique (migration 018): a token identifies one device
// install and therefore at most one current user. Register performs the
// reassignment, so a device that signs in as a different user stops receiving
// the previous user's notifications instead of being delivered to both.
type DeviceTokenRepository interface {
	// Register upserts a token for userID. Re-registering the same
	// (user, token) does not duplicate; registering the same token for a
	// different user MOVES it (the previous user stops matching). It
	// (re)activates the row so a token unregistered earlier can come back.
	Register(userID, token, platform string) (*model.DeviceToken, error)
	// Unregister deactivates the caller's token. It is scoped by userID so a
	// caller cannot deactivate somebody else's token, and it is idempotent: a
	// token that is unknown, already inactive, or owned by another user is a
	// no-op rather than an error.
	Unregister(userID, token string) error
	// ListActiveTokens returns the tokens currently active for userID, in
	// registration order. A token moved to another user is not returned.
	ListActiveTokens(userID string) ([]model.DeviceToken, error)
}

var _ DeviceTokenRepository = (*DeviceTokenRepo)(nil)

type DeviceTokenRepo struct {
	db *sqlx.DB
}

func NewDeviceTokenRepo(db *sqlx.DB) *DeviceTokenRepo {
	return &DeviceTokenRepo{db: db}
}

// Register upserts on the globally-unique token. The arbiter is the token
// unique index (migration 018); DO UPDATE moves the row to the new owner and
// reactivates it. This is a single statement, so a concurrent register cannot
// leave the same token active for two users.
func (r *DeviceTokenRepo) Register(userID, token, platform string) (*model.DeviceToken, error) {
	dt := &model.DeviceToken{}
	err := r.db.QueryRowxContext(context.Background(), `
		INSERT INTO device_tokens (user_id, token, platform, is_active)
		VALUES ($1, $2, $3, TRUE)
		ON CONFLICT (token) DO UPDATE
			SET user_id    = EXCLUDED.user_id,
			    platform   = EXCLUDED.platform,
			    is_active  = TRUE,
			    updated_at = NOW()
		RETURNING id, user_id, token, platform, is_active, created_at, updated_at`,
		userID, token, platform).
		StructScan(dt)
	if err != nil {
		return nil, wrapDB("register device token", err)
	}
	return dt, nil
}

// Unregister deactivates the caller's own token. A 0-row UPDATE is a no-op
// (unknown token, already inactive, or somebody else's token), never an error:
// unregister is idempotent and must not leak whether a token exists.
func (r *DeviceTokenRepo) Unregister(userID, token string) error {
	_, err := r.db.ExecContext(context.Background(), `
		UPDATE device_tokens
		SET is_active = FALSE, updated_at = NOW()
		WHERE user_id = $1 AND token = $2 AND is_active = TRUE`, userID, token)
	return wrapDB("unregister device token", err)
}

func (r *DeviceTokenRepo) ListActiveTokens(userID string) ([]model.DeviceToken, error) {
	tokens := []model.DeviceToken{}
	err := r.db.SelectContext(context.Background(), &tokens, `
		SELECT id, user_id, token, platform, is_active, created_at, updated_at
		FROM device_tokens
		WHERE user_id = $1 AND is_active = TRUE
		ORDER BY created_at`, userID)
	if err != nil {
		return nil, wrapDB("list active device tokens", err)
	}
	return tokens, nil
}
