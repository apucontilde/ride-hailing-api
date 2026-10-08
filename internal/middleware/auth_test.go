package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/service"
)

func newAuthService() *service.AuthService {
	cfg := &config.Config{
		JWTSecret:    "test-secret",
		JWTAccessTTL: 15 * time.Minute,
	}
	return service.NewAuthService(cfg, nil)
}

func signToken(svc *service.AuthService, userID, role string) string {
	claims := &service.TokenClaims{
		UserID: userID,
		Role:   role,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).
		SignedString([]byte("test-secret"))
	if err != nil {
		panic(err)
	}
	return token
}

func setupProtectedRoutes(svc *service.AuthService) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/ws", AuthRequiredWS(svc), func(c *gin.Context) {
		userID, _ := c.Get("user_id")
		c.JSON(http.StatusOK, gin.H{"user_id": userID})
	})
	r.GET("/api", AuthRequired(svc), func(c *gin.Context) {
		userID, _ := c.Get("user_id")
		c.JSON(http.StatusOK, gin.H{"user_id": userID})
	})
	return r
}

func TestAuthRequiredTokenSources(t *testing.T) {
	svc := newAuthService()
	wsToken := signToken(svc, "user-1", "rider")
	tokenParam := signToken(svc, "user-2", "driver")
	headerToken := signToken(svc, "user-h", "rider")
	badQuery := signToken(svc, "user-q", "rider")
	r := setupProtectedRoutes(svc)

	cases := []struct {
		name       string
		target     string
		authHeader string
		wantStatus int
		wantBody   string
	}{
		{
			name:       "ws_accepts_access_token_query_param",
			target:     "/ws?access_token=" + wsToken,
			wantStatus: http.StatusOK,
			wantBody:   `{"user_id":"user-1"}`,
		},
		{
			name:   "ws_accepts_token_query_param_and_injects_identity",
			target: "/ws?token=" + tokenParam,
			// Assert the identity the middleware injected, not just the status.
			wantStatus: http.StatusOK,
			wantBody:   `{"user_id":"user-2"}`,
		},
		{
			name:       "ws_header_takes_precedence_over_query",
			target:     "/ws?access_token=" + badQuery,
			authHeader: "Bearer " + headerToken,
			wantStatus: http.StatusOK,
			wantBody:   `{"user_id":"user-h"}`,
		},
		{
			name:       "ws_rejects_missing_token",
			target:     "/ws",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "ws_rejects_invalid_token",
			target:     "/ws?access_token=not-a-token",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "rest_rejects_query_token",
			target:     "/api?access_token=" + wsToken,
			wantStatus: http.StatusUnauthorized,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.target, nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)

			if w.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", w.Code, tc.wantStatus, w.Body.String())
			}
			if tc.wantBody != "" && w.Body.String() != tc.wantBody {
				t.Fatalf("body = %s, want %s", w.Body.String(), tc.wantBody)
			}
		})
	}
}

func TestMaskQueryTokens(t *testing.T) {
	cases := map[string]string{
		"/ws?access_token=abc123&role=rider": "/ws?access_token=%2A%2A%2A&role=rider",
		"/ws?token=abc123":                   "/ws?token=%2A%2A%2A",
		"/api/v1/rides?page=1":               "/api/v1/rides?page=1",
		"/plain":                             "/plain",
	}
	for in, want := range cases {
		if got := maskQueryTokens(in); got != want {
			t.Errorf("maskQueryTokens(%q) = %q, want %q", in, got, want)
		}
	}
}
