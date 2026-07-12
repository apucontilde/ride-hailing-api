package model

import "time"

type User struct {
	ID            string    `db:"id" json:"id"`
	Email         string    `db:"email" json:"email"`
	Phone         string    `db:"phone" json:"phone"`
	PasswordHash  string    `db:"password_hash" json:"-"`
	Role          string    `db:"role" json:"role"`
	EmailVerified bool      `db:"email_verified" json:"email_verified"`
	PhoneVerified bool      `db:"phone_verified" json:"phone_verified"`
	Status        string    `db:"status" json:"status"`
	CreatedAt     time.Time `db:"created_at" json:"created_at"`
	UpdatedAt     time.Time `db:"updated_at" json:"updated_at"`
}

type Rider struct {
	UserID    string    `db:"user_id" json:"user_id"`
	FirstName string    `db:"first_name" json:"first_name"`
	LastName  string    `db:"last_name" json:"last_name"`
	PhotoURL  string    `db:"photo_url" json:"photo_url"`
	Status    string    `db:"status" json:"status"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

type Driver struct {
	UserID           string    `db:"user_id" json:"user_id"`
	FirstName        string    `db:"first_name" json:"first_name"`
	LastName         string    `db:"last_name" json:"last_name"`
	PhotoURL         string    `db:"photo_url" json:"photo_url"`
	Status           string    `db:"status" json:"status"`
	OnboardingStatus string    `db:"onboarding_status" json:"onboarding_status"`
	RatingSummary    string    `db:"rating_summary" json:"rating_summary"`
	CreatedAt        time.Time `db:"created_at" json:"created_at"`
	UpdatedAt        time.Time `db:"updated_at" json:"updated_at"`
}

type DriverDocument struct {
	ID              string    `db:"id" json:"id"`
	DriverID        string    `db:"driver_id" json:"driver_id"`
	DocumentType    string    `db:"document_type" json:"document_type"`
	FileURL         string    `db:"file_url" json:"file_url"`
	Status          string    `db:"status" json:"status"`
	RejectionReason string    `db:"rejection_reason" json:"rejection_reason"`
	CreatedAt       time.Time `db:"created_at" json:"created_at"`
	UpdatedAt       time.Time `db:"updated_at" json:"updated_at"`
}

type DriverVehicle struct {
	ID          string    `db:"id" json:"id"`
	DriverID    string    `db:"driver_id" json:"driver_id"`
	Make        string    `db:"make" json:"make"`
	Model       string    `db:"model" json:"model"`
	Color       string    `db:"color" json:"color"`
	Year        int       `db:"year" json:"year"`
	PlateNumber string    `db:"plate_number" json:"plate_number"`
	VehicleType string    `db:"vehicle_type" json:"vehicle_type"`
	IsActive    bool      `db:"is_active" json:"is_active"`
	CreatedAt   time.Time `db:"created_at" json:"created_at"`
	UpdatedAt   time.Time `db:"updated_at" json:"updated_at"`
}
