package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/service"
)

type refreshRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

type logoutRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

type forgotPasswordRequest struct {
	Email string `json:"email" binding:"required,email"`
}

type resetPasswordRequest struct {
	Token       string `json:"token" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=8"`
}

type verifyCodeRequest struct {
	Code string `json:"code" binding:"required"`
}

type socialLoginRequest struct {
	Provider string `json:"provider" binding:"required"`
	Token    string `json:"token" binding:"required"`
}

type AuthHandler struct {
	authService *service.AuthService
}

func NewAuthHandler(authService *service.AuthService) *AuthHandler {
	return &AuthHandler{authService: authService}
}

type registerRequest struct {
	Email    string `json:"email" binding:"required,email"`
	Phone    string `json:"phone" binding:"required"`
	Password string `json:"password" binding:"required,min=8"`
}

// Register godoc
//
//	@Summary		Register a new user account
//	@Description	Creates a user account with email, phone, and password. The account starts in the `rider` role.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Param			body	body		registerRequest	true	"Registration request"
//	@Success		201		{object}	RegisterResponse
//	@Failure		409		{object}	ErrorResponse	"Account already exists"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Router			/api/v1/auth/register [post]
func (h *AuthHandler) Register(c *gin.Context) {
	var req registerRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	user, err := h.authService.Register(req.Email, req.Phone, req.Password)
	if err != nil {
		c.JSON(http.StatusConflict, gin.H{
			"error": gin.H{"code": "CONFLICT", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"user": gin.H{
			"id":    user.ID,
			"email": user.Email,
			"phone": user.Phone,
			"role":  user.Role,
		},
	})
}

type loginRequest struct {
	Email    string `json:"email" binding:"required,email"`
	Password string `json:"password" binding:"required"`
}

// Login godoc
//
//	@Summary		Log in a user
//	@Description	Authenticates credentials and returns access and refresh tokens.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Param			body	body		loginRequest	true	"Login request"
//	@Success		200		{object}	LoginResponse
//	@Failure		401		{object}	ErrorResponse	"Invalid credentials"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Router			/api/v1/auth/login [post]
func (h *AuthHandler) Login(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	tokens, user, err := h.authService.Login(req.Email, req.Password)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": gin.H{"code": "UNAUTHORIZED", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"access_token":  tokens.AccessToken,
		"refresh_token": tokens.RefreshToken,
		"user": gin.H{
			"id":    user.ID,
			"email": user.Email,
			"role":  user.Role,
		},
	})
}

// Refresh godoc
//
//	@Summary		Refresh an access token
//	@Description	Exchanges a valid refresh token for a new token pair.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Param			body	body		refreshRequest	true	"Refresh request"
//	@Success		200		{object}	TokenPair
//	@Failure		401		{object}	ErrorResponse	"Invalid or expired refresh token"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Router			/api/v1/auth/refresh [post]
func (h *AuthHandler) Refresh(c *gin.Context) {
	var req refreshRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	tokens, err := h.authService.RefreshAccessToken(req.RefreshToken)
	if err != nil {
		if errors.Is(err, service.ErrTokenRevoke) {
			// A backend outage is not the client's fault, and the driver error
			// must not reach the client.
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": gin.H{"code": "INTERNAL", "message": "failed to revoke refresh token"},
			})
			return
		}
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": gin.H{"code": "UNAUTHORIZED", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"access_token":  tokens.AccessToken,
		"refresh_token": tokens.RefreshToken,
	})
}

// Logout godoc
//
//	@Summary		Log out a user
//	@Description	Revokes the supplied refresh token.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Security		BearerAuth
//	@Param			body	body		logoutRequest	true	"Logout request"
//	@Success		200		{object}	MessageResponse
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Revocation failed"
//	@Router			/api/v1/auth/logout [post]
func (h *AuthHandler) Logout(c *gin.Context) {
	var req logoutRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	if err := h.authService.Logout(req.RefreshToken); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": gin.H{"code": "INTERNAL", "message": "logout failed"},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "logged out"})
}

// ForgotPassword godoc
//
//	@Summary		Request a password reset
//	@Description	Triggers a password reset flow for the given email. A reset token is returned in development.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Param			body	body		forgotPasswordRequest	true	"Forgot password request"
//	@Success		200		{object}	MessageResponse
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Failure		500		{object}	ErrorResponse	"Request failed"
//	@Router			/api/v1/auth/forgot-password [post]
func (h *AuthHandler) ForgotPassword(c *gin.Context) {
	var req forgotPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	token, err := h.authService.ForgotPassword(req.Email)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": gin.H{"code": "INTERNAL", "message": "failed to process request"},
		})
		return
	}

	resp := gin.H{"message": "if the email exists, a reset link has been sent"}
	if token != "" {
		resp["reset_token"] = token
	}
	c.JSON(http.StatusOK, resp)
}

// ResetPassword godoc
//
//	@Summary		Reset a password
//	@Description	Sets a new password using a reset token obtained from forgot-password.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Param			body	body		resetPasswordRequest	true	"Reset password request"
//	@Success		200		{object}	MessageResponse
//	@Failure		400		{object}	ErrorResponse	"Invalid or expired token"
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Router			/api/v1/auth/reset-password [post]
func (h *AuthHandler) ResetPassword(c *gin.Context) {
	var req resetPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	if err := h.authService.ResetPassword(req.Token, req.NewPassword); err != nil {
		if errors.Is(err, service.ErrTokenRevoke) {
			// A backend outage is not the client's fault, and the driver error
			// must not reach the client.
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": gin.H{"code": "INTERNAL", "message": "failed to revoke reset token"},
			})
			return
		}
		c.JSON(http.StatusBadRequest, gin.H{
			"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "password reset successfully"})
}

// VerifyEmail godoc
//
//	@Summary	Verify the user's email
//	@Tags		auth
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		verifyCodeRequest	true	"Email verification request"
//	@Success	200		{object}	MessageResponse
//	@Failure	400		{object}	ErrorResponse	"Invalid code"
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/auth/verify-email [post]
func (h *AuthHandler) VerifyEmail(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var req verifyCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	if err := h.authService.VerifyEmail(userID.(string), req.Code); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "email verified"})
}

// VerifyPhone godoc
//
//	@Summary	Verify the user's phone number
//	@Tags		auth
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		verifyCodeRequest	true	"Phone verification request"
//	@Success	200		{object}	MessageResponse
//	@Failure	400		{object}	ErrorResponse	"Invalid code"
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/auth/verify-phone [post]
func (h *AuthHandler) VerifyPhone(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var req verifyCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	if err := h.authService.VerifyPhone(userID.(string), req.Code); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": gin.H{"code": "BAD_REQUEST", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "phone verified"})
}

// SocialLogin godoc
//
//	@Summary		Social login (stub)
//	@Description	Placeholder for OAuth-based social login. Not yet implemented.
//	@Tags			auth
//	@Accept			json
//	@Produce		json
//	@Param			body	body		socialLoginRequest	true	"Social login request"
//	@Success		200		{object}	MessageResponse
//	@Failure		422		{object}	ErrorResponse	"Validation error"
//	@Router			/api/v1/auth/social [post]
func (h *AuthHandler) SocialLogin(c *gin.Context) {
	var req socialLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": gin.H{"code": "VALIDATION_ERROR", "message": err.Error()},
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "social login not yet implemented",
	})
}
