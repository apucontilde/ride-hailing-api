package repository

import (
	"context"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/model"
)

// FeedbackRepository persists user feedback. It is a write-only surface today;
// there is no admin read path in this repo.
type FeedbackRepository interface {
	// CreateFeedback inserts the row and fills in the generated id and
	// created_at. A write failure is returned (never swallowed): the endpoint
	// must not answer 201 for feedback that was not stored.
	CreateFeedback(feedback *model.Feedback) error
}

var _ FeedbackRepository = (*FeedbackRepo)(nil)

type FeedbackRepo struct {
	db *sqlx.DB
}

func NewFeedbackRepo(db *sqlx.DB) *FeedbackRepo {
	return &FeedbackRepo{db: db}
}

func (r *FeedbackRepo) CreateFeedback(feedback *model.Feedback) error {
	err := r.db.QueryRowxContext(context.Background(), `
		INSERT INTO feedback (user_id, ride_id, type, message)
		VALUES ($1, $2, $3, $4)
		RETURNING id, type, created_at`,
		feedback.UserID, feedback.RideID, feedback.Type, feedback.Message).
		Scan(&feedback.ID, &feedback.Type, &feedback.CreatedAt)
	if err != nil {
		return wrapDB("create feedback", err)
	}
	return nil
}
