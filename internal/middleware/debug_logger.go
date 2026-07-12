package middleware

import (
	"bytes"
	"io"
	"log"
	"regexp"

	"github.com/gin-gonic/gin"
)

type fieldPattern struct {
	re    *regexp.Regexp
	field string
}

var sensitivePatterns []fieldPattern

func init() {
	fields := []string{`password`, `new_password`, `refresh_token`, `reset_token`, `token`, `access_token`}
	for _, f := range fields {
		sensitivePatterns = append(sensitivePatterns, fieldPattern{
			re:    regexp.MustCompile(`"` + f + `"\s*:\s*"[^"]*"`),
			field: f,
		})
	}
}

func maskSensitive(body []byte) []byte {
	s := string(body)
	for _, fp := range sensitivePatterns {
		replacement := `"` + fp.field + `":"***"`
		s = fp.re.ReplaceAllString(s, replacement)
	}
	return []byte(s)
}

type bodyWriter struct {
	gin.ResponseWriter
	body *bytes.Buffer
}

func (w *bodyWriter) Write(b []byte) (int, error) {
	w.body.Write(b)
	return w.ResponseWriter.Write(b)
}

const maxLogBody = 2048

func DebugLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		path := c.Request.URL.Path
		method := c.Request.Method

		if c.Request.Body != nil {
			bodyBytes, _ := io.ReadAll(c.Request.Body)
			c.Request.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))

			if len(bodyBytes) > 0 && !isWebSocketUpgrade(c) {
				masked := maskSensitive(bodyBytes)
				if len(masked) > maxLogBody {
					masked = append(masked[:maxLogBody], []byte("... (truncated)")...)
				}
				log.Printf("[DEBUG] REQ %s %s Body: %s", method, path, string(masked))
			}
		}

		bw := &bodyWriter{body: &bytes.Buffer{}, ResponseWriter: c.Writer}
		c.Writer = bw

		c.Next()

		respBody := bw.body.Bytes()
		if len(respBody) > 0 && !isWebSocketUpgrade(c) {
			masked := maskSensitive(respBody)
			if len(masked) > maxLogBody {
				masked = append(masked[:maxLogBody], []byte("... (truncated)")...)
			}
			log.Printf("[DEBUG] RES %s %s => %d Body: %s", method, path, c.Writer.Status(), string(masked))
		}
	}
}

func isWebSocketUpgrade(c *gin.Context) bool {
	return c.Request.Header.Get("Upgrade") == "websocket"
}
