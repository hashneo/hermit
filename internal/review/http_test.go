package review

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestApproveSetsReviewState(t *testing.T) {
	service := NewService(nil)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST "+ReviewApprovePath(), handler.Approve)
	mux.HandleFunc("GET "+ReviewStatePath(), handler.GetReviewState)

	body := bytes.NewBufferString(`{"body":"looks good"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-123/pull-requests/42/review/approve", body)
	req.Header.Set("X-Hermit-User", "alice")
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("approve status = %d, want %d", resp.Code, http.StatusOK)
	}

	// The approve response still contains an internal State for backward compat.
	var approved State
	if err := json.Unmarshal(resp.Body.Bytes(), &approved); err != nil {
		t.Fatalf("decode approve response: %v", err)
	}
	if approved.State != StateApproved {
		t.Fatalf("approve state = %q, want %q", approved.State, StateApproved)
	}

	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-123/pull-requests/42/review", nil)
	getResp := httptest.NewRecorder()
	mux.ServeHTTP(getResp, getReq)

	if getResp.Code != http.StatusOK {
		t.Fatalf("review get status = %d, want %d", getResp.Code, http.StatusOK)
	}

	// GetReviewState returns ReviewStateResponse: { approved: bool, reviewers: [] }
	var current ReviewStateResponse
	if err := json.Unmarshal(getResp.Body.Bytes(), &current); err != nil {
		t.Fatalf("decode get response: %v", err)
	}
	if !current.Approved {
		t.Fatalf("stored approved = false, want true")
	}
	if len(current.Reviewers) == 0 || current.Reviewers[0] != "alice" {
		t.Fatalf("reviewers = %v, want [alice]", current.Reviewers)
	}
}

func TestApproveRejectsInvalidPRNumber(t *testing.T) {
	service := NewService(nil)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST "+ReviewApprovePath(), handler.Approve)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-123/pull-requests/invalid/review/approve", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusBadRequest)
	}
}

