package observability

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMiddlewareWithAccessLogRecordsErrors(t *testing.T) {
	store, err := OpenAccessLog(t.TempDir())
	if err != nil {
		t.Fatalf("open access log: %v", err)
	}
	defer store.Close()

	handler := MiddlewareWithAccessLog(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		WriteError(w, r, http.StatusNotFound, "missing_doc", "document not found")
	}), store)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/docs/missing?view=markdown", nil)
	req.Header.Set(CorrelationHeader, "corr-test")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	store.Sync() // wait for async write to complete

	entries, err := store.List(req.Context(), LogQuery{Kind: "error", Limit: 10})
	if err != nil {
		t.Fatalf("list access log: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected one error entry, got %d", len(entries))
	}
	entry := entries[0]
	if entry.Status != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", entry.Status)
	}
	if entry.Kind != "error" {
		t.Fatalf("kind = %q, want error", entry.Kind)
	}
	if entry.Path != "/api/v1/docs/missing" || entry.Query != "view=markdown" {
		t.Fatalf("unexpected target: path=%q query=%q", entry.Path, entry.Query)
	}
	if entry.CorrelationID != "corr-test" {
		t.Fatalf("correlation id = %q, want corr-test", entry.CorrelationID)
	}
	if entry.ErrorCode != "missing_doc" || entry.ErrorMessage != "document not found" {
		t.Fatalf("unexpected error fields: code=%q message=%q", entry.ErrorCode, entry.ErrorMessage)
	}
}

func TestLogHandlerList(t *testing.T) {
	store, err := OpenAccessLog(t.TempDir())
	if err != nil {
		t.Fatalf("open access log: %v", err)
	}
	defer store.Close()

	if err := store.Insert(t.Context(), LogEntry{
		StartedAt:     "2026-06-29T00:00:00Z",
		CompletedAt:   "2026-06-29T00:00:00Z",
		Kind:          "access",
		Method:        http.MethodGet,
		Path:          "/healthz",
		Status:        http.StatusOK,
		CorrelationID: "corr-ok",
	}); err != nil {
		t.Fatalf("insert access: %v", err)
	}
	if err := store.Insert(t.Context(), LogEntry{
		StartedAt:     "2026-06-29T00:00:01Z",
		CompletedAt:   "2026-06-29T00:00:01Z",
		Kind:          "error",
		Method:        http.MethodGet,
		Path:          "/missing",
		Status:        http.StatusNotFound,
		CorrelationID: "corr-error",
		ErrorCode:     "not_found",
		ErrorMessage:  "missing",
	}); err != nil {
		t.Fatalf("insert error: %v", err)
	}
	store.Sync() // wait for async writes to complete

	req := httptest.NewRequest(http.MethodGet, "/api/v1/logs?kind=error&limit=5", nil)
	rec := httptest.NewRecorder()
	NewLogHandler(store).List(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	var response struct {
		Items []LogEntry `json:"items"`
		Total int        `json:"total"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Total != 1 || len(response.Items) != 1 {
		t.Fatalf("expected one error log entry, got total=%d len=%d", response.Total, len(response.Items))
	}
	if response.Items[0].Path != "/missing" {
		t.Fatalf("path = %q, want /missing", response.Items[0].Path)
	}
}
