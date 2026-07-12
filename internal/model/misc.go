package model

import "time"

type RefreshToken struct {
	ID        string    `db:"id" json:"id"`
	UserID    string    `db:"user_id" json:"user_id"`
	TokenHash string    `db:"token_hash" json:"-"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
	Revoked   bool      `db:"revoked" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

type DeviceToken struct {
	ID        string    `db:"id" json:"id"`
	UserID    string    `db:"user_id" json:"user_id"`
	Token     string    `db:"token" json:"token"`
	Platform  string    `db:"platform" json:"platform"`
	IsActive  bool      `db:"is_active" json:"is_active"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

type Promotion struct {
	ID            string    `db:"id" json:"id"`
	Code          string    `db:"code" json:"code"`
	Description   string    `db:"description" json:"description"`
	DiscountType  string    `db:"discount_type" json:"discount_type"`
	DiscountValue float64   `db:"discount_value" json:"discount_value"`
	MaxUses       int       `db:"max_uses" json:"max_uses"`
	CurrentUses   int       `db:"current_uses" json:"current_uses"`
	ExpiresAt     time.Time `db:"expires_at" json:"expires_at"`
	IsActive      bool      `db:"is_active" json:"is_active"`
	CreatedAt     time.Time `db:"created_at" json:"created_at"`
}

type SOSAlert struct {
	ID        string     `db:"id" json:"id"`
	UserID    string     `db:"user_id" json:"user_id"`
	UserRole  string     `db:"user_role" json:"user_role"`
	RideID    *string    `db:"ride_id" json:"ride_id"`
	Lat       float64    `db:"lat" json:"lat"`
	Lng       float64    `db:"lng" json:"lng"`
	Status    string     `db:"status" json:"status"`
	CreatedAt time.Time  `db:"created_at" json:"created_at"`
}

type Feedback struct {
	ID      string    `db:"id" json:"id"`
	UserID  string    `db:"user_id" json:"user_id"`
	RideID  *string   `db:"ride_id" json:"ride_id"`
	Message string    `db:"message" json:"message"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

type PasswordResetToken struct {
	ID        string    `db:"id" json:"id"`
	UserID    string    `db:"user_id" json:"user_id"`
	TokenHash string    `db:"token_hash" json:"-"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
	Used      bool      `db:"used" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

type Favorite struct {
	ID      string    `db:"id" json:"id"`
	RiderID string    `db:"rider_id" json:"rider_id"`
	Name    string    `db:"name" json:"name"`
	Lat     float64   `db:"lat" json:"lat"`
	Lng     float64   `db:"lng" json:"lng"`
	Address string    `db:"address" json:"address"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}
