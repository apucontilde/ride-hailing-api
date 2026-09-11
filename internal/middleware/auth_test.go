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

func TestAuthRequiredWS_AcceptsAccessTokenQueryParam(t *testing.T) {
	svc := newAuthService()
	token := signToken(svc, "user-1", "rider")
	r := setupProtectedRoutes(svc)

	req := httptest.NewRequest(http.MethodGet, "/ws?access_token="+token, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	want := `{"user_id":"user-1"}`
	if w.Body.String() != want {
		t.Fatalf("expected body %s, got %s", want, w.Body.String())
	}
}

func TestAuthRequiredWS_AcceptsTokenQueryParam(t *testing.T) {
	svc := newAuthService()
	token := signToken(svc, "user-2", "driver")
	r := setupProtectedRoutes(svc)

	req := httptest.NewRequest(http.MethodGet, "/ws?token="+token, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
}

func TestAuthRequiredWS_HeaderTakesPrecedence(t *testing.T) {
	svc := newAuthService()
	valid := signToken(svc, "user-h", "rider")
	bad := signToken(svc, "user-q", "rider")
	r := setupProtectedRoutes(svc)

	req := httptest.NewRequest(http.MethodGet, "/ws?access_token="+bad, nil)
	req.Header.Set("Authorization", "Bearer "+valid)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK || w.Body.String() != `{"user_id":"user-h"}` {
		t.Fatalf("expected header token to win, got %d %s", w.Code, w.Body.String())
	}
}

func TestAuthRequiredWS_RejectsMissingToken(t *testing.T) {
	svc := newAuthService()
	r := setupProtectedRoutes(svc)

	req := httptest.NewRequest(http.MethodGet, "/ws", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestAuthRequiredWS_RejectsInvalidToken(t *testing.T) {
	svc := newAuthService()
	r := setupProtectedRoutes(svc)

	req := httptest.NewRequest(http.MethodGet, "/ws?access_token=not-a-token", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestAuthRequired_DoesNotAcceptQueryToken(t *testing.T) {
	svc := newAuthService()
	token := signToken(svc, "user-1", "rider")
	r := setupProtectedRoutes(svc)

	req := httptest.NewRequest(http.MethodGet, "/api?access_token="+token, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected REST auth to reject query token, got %d", w.Code)
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
