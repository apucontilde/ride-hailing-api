package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/service"
)

func AuthRequired(svc *service.AuthService) gin.HandlerFunc {
	return AuthRequiredWithTokenParam(svc, false)
}

// AuthRequiredWS is like AuthRequired but also accepts the access token via
// the `access_token` (or `token`) query parameter. Browsers cannot set custom
// headers on WebSocket upgrades, so web clients must pass the JWT in the URL.
// REST routes should keep using AuthRequired (header-only).
func AuthRequiredWS(svc *service.AuthService) gin.HandlerFunc {
	return AuthRequiredWithTokenParam(svc, true)
}

func AuthRequiredWithTokenParam(svc *service.AuthService, allowQueryToken bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := extractToken(c, allowQueryToken)
		if token == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error": gin.H{"code": "UNAUTHORIZED", "message": "missing authorization token"},
			})
			return
		}

		claims, err := svc.ValidateAccessToken(token)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error": gin.H{"code": "UNAUTHORIZED", "message": "invalid or expired token"},
			})
			return
		}

		c.Set("user_id", claims.UserID)
		c.Set("role", claims.Role)
		c.Next()
	}
}

func extractToken(c *gin.Context, allowQueryToken bool) string {
	header := c.GetHeader("Authorization")
	if header != "" {
		token := strings.TrimPrefix(header, "Bearer ")
		if token != header {
			return token
		}
	}
	if allowQueryToken {
		if t := c.Query("access_token"); t != "" {
			return t
		}
		if t := c.Query("token"); t != "" {
			return t
		}
	}
	return ""
}

func RequireRole(role string) gin.HandlerFunc {
	return func(c *gin.Context) {
		userRole, exists := c.Get("role")
		if !exists || userRole.(string) != role {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{
				"error": gin.H{"code": "FORBIDDEN", "message": "insufficient permissions"},
			})
			return
		}
		c.Next()
	}
}
