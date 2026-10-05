package tests

import (
	"errors"
	"net/http"
	"strings"
	"testing"
)

// TestFeedbackTypeRoundTrips pins bug #20: the client sends a classification
// and it must be persisted and echoed, not silently dropped.
func TestFeedbackTypeRoundTrips(t *testing.T) {
	token := registerAndLogin(t, "push.feedback@test.com", "+5100000009")

	resp := ts.DoRequest("POST", "/api/v1/feedback", token, map[string]string{
		"type":    "app_issue",
		"message": "the app crashes when I open the trip screen",
	})
	resp.AssertStatus(t, http.StatusCreated)
	resp.AssertJSONHas(t, "message", "feedback submitted")
	resp.AssertJSONHas(t, "feedback.type", "app_issue")

	last := ts.FeedbackRepo.Last()
	if last == nil {
		t.Fatal("no feedback persisted")
	}
	if last.Type != "app_issue" {
		t.Fatalf("persisted type = %q, want app_issue", last.Type)
	}
	if last.Message == "" {
		t.Fatal("persisted message is empty")
	}
}

// TestFeedbackWithoutTypeStillAccepted keeps the pre-#20 client (message only)
// working with an empty stored type.
func TestFeedbackWithoutTypeStillAccepted(t *testing.T) {
	token := registerAndLogin(t, "push.feedback.notype@test.com", "+5100000010")

	resp := ts.DoRequest("POST", "/api/v1/feedback", token, map[string]string{
		"message": "nice app",
	})
	resp.AssertStatus(t, http.StatusCreated)

	last := ts.FeedbackRepo.Last()
	if last == nil {
		t.Fatal("no feedback persisted")
	}
	if last.Type != "" {
		t.Fatalf("persisted type = %q, want empty when the client sent none", last.Type)
	}
}

func TestFeedbackValidationError(t *testing.T) {
	token := registerAndLogin(t, "push.feedback.validation@test.com", "+5100000011")

	resp := ts.DoRequest("POST", "/api/v1/feedback", token, map[string]string{
		"type": "app_issue",
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestFeedbackWriteFailureIs500(t *testing.T) {
	token := registerAndLogin(t, "push.feedback.outage@test.com", "+5100000012")

	ts.FeedbackRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := ts.DoRequest("POST", "/api/v1/feedback", token, map[string]string{
		"type": "app_issue", "message": "x",
	})
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to submit feedback") {
		t.Fatalf("body = %s, want the operation sentence", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") {
		t.Fatalf("body leaks the driver error: %s", resp.Body)
	}
}
