package service

import "ride-hailing-api/internal/repository"

type RiderService struct {
	userRepo repository.UserRepository
}

func NewRiderService(userRepo repository.UserRepository) *RiderService {
	return &RiderService{userRepo: userRepo}
}
