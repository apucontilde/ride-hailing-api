package middleware

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
)

func Idempotency(db *sqlx.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := c.GetHeader("Idempotency-Key")
		if key == "" || db == nil {
			c.Next()
			return
		}

		userID, _ := c.Get("user_id")
		userIDStr, _ := userID.(string)

		var count int
		err := db.Get(&count, "SELECT COUNT(*) FROM idempotency_keys WHERE key = $1 AND user_id = $2", key, userIDStr)
		if err == nil && count > 0 {
			var status int
			var body json.RawMessage
			db.Get(&status, "SELECT response_status FROM idempotency_keys WHERE key = $1", key)
			db.Get(&body, "SELECT response_body FROM idempotency_keys WHERE key = $1", key)
			c.AbortWithStatusJSON(status, body)
			return
		}

		c.Set("idempotency_key", key)
		c.Next()

		if c.Writer.Status() == http.StatusCreated || c.Writer.Status() == http.StatusOK {
			responseBody, _ := json.Marshal(gin.H{})
			if storedKey, exists := c.Get("idempotency_key"); exists {
				db.Exec(
					"INSERT INTO idempotency_keys (key, user_id, response_status, response_body) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
					storedKey, userIDStr, c.Writer.Status(), string(responseBody),
				)
			}
		}
	}
}
