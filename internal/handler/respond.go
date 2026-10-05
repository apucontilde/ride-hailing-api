package handler

import (
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"github.com/go-playground/validator/v10"

	"ride-hailing-api/internal/repository"
)

// fail writes the standard error envelope and attaches cause to the request so
// middleware.ErrorLogger prints it with the request id.
//
// `message` is PUBLIC: it is rendered verbatim on a Flutter form. Never pass
// err.Error() here for anything derived from a database, a driver, or an
// internal invariant. `cause` is the opposite: always pass the real error, and
// never nil when one exists — the log is the only place the detail belongs.
func fail(c *gin.Context, status int, code, message string, cause error) {
	if cause != nil {
		_ = c.Error(cause)
	}
	c.AbortWithStatusJSON(status, ErrorResponse{
		Error: ErrorDetail{Code: code, Message: message},
	})
}

// fieldName maps a JSON key to the words a user should see.
//
// The struct's Go field name is deliberately NOT used: "PickupLat" is an
// implementation detail, and the validator's default message prints it.
var fieldName = map[string]string{
	"email":         "Email",
	"phone":         "Phone",
	"password":      "Password",
	"first_name":    "First name",
	"last_name":     "Last name",
	"pickup_lat":    "Pickup latitude",
	"pickup_lng":    "Pickup longitude",
	"dropoff_lat":   "Drop-off latitude",
	"dropoff_lng":   "Drop-off longitude",
	"vehicle_type":  "Vehicle type",
	"lat":           "Latitude",
	"lng":           "Longitude",
	"heading":       "Heading",
	"speed":         "Speed",
	"code":          "Code",
	"refresh_token": "Refresh token",
	"token":         "Token",
	"new_password":  "New password",
	"provider":      "Provider",
	"message":       "Message",
	"platform":      "Platform",
	"status":        "Status",
	"score":         "Score",
}

// bindJSON decodes and validates a body, reporting failures as a public
// sentence. Returns false when it has already written the response.
//
// The raw validator error is attached to the context (log), never returned.
// logCtx is prepended to the logged cause; pass "" to log it bare, or the
// "[sos] validation error (user=…)" shape that platform.go already uses and
// that makes its log lines worth reading.
func bindJSON(c *gin.Context, obj any, logCtx string) bool {
	registerJSONFieldNames()

	err := c.ShouldBindJSON(obj)
	if err == nil {
		return true
	}

	if logCtx != "" {
		_ = c.Error(fmt.Errorf("%s: %w", logCtx, err))
	} else {
		_ = c.Error(err)
	}

	var verrs validator.ValidationErrors
	if errors.As(err, &verrs) && len(verrs) > 0 {
		names := make([]string, 0, len(verrs))
		for _, fe := range verrs {
			if n, ok := fieldName[fe.Field()]; ok {
				names = append(names, n)
			} else {
				names = append(names, fe.Field())
			}
		}
		fail(c, http.StatusUnprocessableEntity, "VALIDATION_ERROR",
			"Invalid "+strings.Join(names, ", "), nil)
		return false
	}

	// Not a validation failure: malformed JSON, or a wrong content type. The
	// detail is in the log; the user needs to know only that the body could
	// not be read.
	fail(c, http.StatusBadRequest, "BAD_REQUEST", "Malformed request body", nil)
	return false
}

// registerJSONFieldNames makes go-playground/validator report a field by its
// JSON tag (e.g. "pickup_lat") instead of its Go name ("PickupLat"). Without
// it, fe.Field() returns the Go struct field name, so the public `fieldName`
// map (keyed by JSON tag) never matches and users see implementation detail.
var jsonFieldNamesOnce sync.Once

func registerJSONFieldNames() {
	jsonFieldNamesOnce.Do(func() {
		if v, ok := binding.Validator.Engine().(*validator.Validate); ok {
			v.RegisterTagNameFunc(func(fld reflect.StructField) string {
				name := strings.SplitN(fld.Tag.Get("json"), ",", 2)[0]
				if name == "-" {
					return ""
				}
				return name
			})
		}
	})
}

// respondRepo classifies a repository/service error and writes the response.
//
// All three sentences are chosen by the call site, because all three are
// PUBLIC and rendered verbatim on a Flutter form. Pass the operation's own
// words for internal ("failed to load nearby drivers"), not "internal error":
// a name the user and support can act on, and it leaks nothing — the
// operation is not a secret, the driver error underneath it is.
//
// The status split is the part that matters. Guessing wrong towards 5xx (a
// 500 for a typo) is recoverable: they retry. Guessing wrong towards 4xx is
// not: both apps treat any error status as a route failure, so a
// 4xx-for-an-outage is indistinguishable from a legitimate client error. The
// rider Home preview now surfaces the message + Retry and draws a grey dashed
// line (rider_app/lib/features/home/presentation/home_screen.dart:179-195,440-474),
// so it is no longer silent; its residual honesty gap is tracked by
// rider_app_plans/[map]_route_failure_honesty.md.
func respondRepo(c *gin.Context, err error, notFound, conflict, internal string) {
	switch {
	case errors.Is(err, repository.ErrNotFound):
		fail(c, http.StatusNotFound, "NOT_FOUND", notFound, err)
	case errors.Is(err, repository.ErrConflict):
		fail(c, http.StatusConflict, "CONFLICT", conflict, err)
	default:
		fail(c, http.StatusInternalServerError, "INTERNAL", internal, err)
	}
}
