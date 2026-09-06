package middleware

import (
	"log"

	"github.com/gin-gonic/gin"
)

// ErrorLogger logs every error attached with c.Error(err) in every
// environment, so server-side failures stay visible even when body/request
// debugging (DebugLogger) is off. Handlers keep returning a stable public
// message to the client; this prints the raw error with its request context.
//
// Register it unconditionally. When debug logging is enabled it must run
// before DebugLogger so both middlewares share the same request_id and each
// error is logged exactly once.
func ErrorLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		method := c.Request.Method
		uri := c.Request.URL.RequestURI()
		reqID := ensureRequestID(c)

		c.Next()

		for _, e := range c.Errors {
			log.Printf("[ERROR] %s %s => %d request_id=%s error=%s", method, uri, c.Writer.Status(), reqID, e.Error())
		}
	}
}
