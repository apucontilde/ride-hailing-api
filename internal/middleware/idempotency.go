package middleware

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
)

// loadStoredResponse reads the replay pair for key. Both columns must be
// readable: replaying with a zero status or a nil body would answer the client
// with a bogus response, so a partial read is reported as an error and the
// request is re-run instead.
func loadStoredResponse(db *sqlx.DB, key string) (int, json.RawMessage, error) {
	var status int
	if err := db.Get(&status, "SELECT response_status FROM idempotency_keys WHERE key = $1", key); err != nil {
		return 0, nil, err
	}
	var body json.RawMessage
	if err := db.Get(&body, "SELECT response_body FROM idempotency_keys WHERE key = $1", key); err != nil {
		return 0, nil, err
	}
	return status, body, nil
}

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
			status, body, readErr := loadStoredResponse(db, key)
			if readErr == nil {
				c.AbortWithStatusJSON(status, body)
				return
			}
			log.Printf("idempotency: stored response for key %s unreadable (%v); re-running handler", key, readErr)
		}

		c.Set("idempotency_key", key)
		c.Next()

		if c.Writer.Status() == http.StatusCreated || c.Writer.Status() == http.StatusOK {
			responseBody, _ := json.Marshal(gin.H{})
			if storedKey, exists := c.Get("idempotency_key"); exists {
				if _, err := db.Exec(
					"INSERT INTO idempotency_keys (key, user_id, response_status, response_body) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
					storedKey, userIDStr, c.Writer.Status(), string(responseBody),
				); err != nil {
					log.Printf("idempotency: failed to store response for key %v: %v", storedKey, err)
				}
			}
		}
	}
}
