package thread

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestThreadLifecycleCreateReplyResolve(t *testing.T) {
	service := NewService(nil)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET "+ThreadsPath(), handler.ListThreads)
	mux.HandleFunc("POST "+ThreadsPath(), handler.CreateThread)
	mux.HandleFunc("POST "+ThreadReplyPath(), handler.ReplyThread)
	mux.HandleFunc("POST "+ThreadResolvePath(), handler.ResolveThread)

	createBody := bytes.NewBufferString(`{"anchor":{"line_start":10,"line_end":12,"text_fingerprint":"abc123"},"body":"first"}`)
	createReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/7/threads", createBody)
	createReq.Header.Set("X-Hermit-User", "alice")
	createResp := httptest.NewRecorder()
	mux.ServeHTTP(createResp, createReq)

	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d", createResp.Code, http.StatusCreated)
	}

	var created Thread
	if err := json.Unmarshal(createResp.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.Sync.State != SyncStateSynced {
		t.Fatalf("create sync state = %q, want %q", created.Sync.State, SyncStateSynced)
	}

	replyBody := bytes.NewBufferString(`{"body":"follow-up"}`)
	replyReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/7/threads/"+created.ID+"/reply", replyBody)
	replyReq.Header.Set("X-Hermit-User", "bob")
	replyResp := httptest.NewRecorder()
	mux.ServeHTTP(replyResp, replyReq)

	if replyResp.Code != http.StatusOK {
		t.Fatalf("reply status = %d, want %d", replyResp.Code, http.StatusOK)
	}

	resolveReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/7/threads/"+created.ID+"/resolve", nil)
	resolveResp := httptest.NewRecorder()
	mux.ServeHTTP(resolveResp, resolveReq)

	if resolveResp.Code != http.StatusOK {
		t.Fatalf("resolve status = %d, want %d", resolveResp.Code, http.StatusOK)
	}

	var resolved Thread
	if err := json.Unmarshal(resolveResp.Body.Bytes(), &resolved); err != nil {
		t.Fatalf("decode resolve response: %v", err)
	}
	if resolved.Status != ThreadStatusResolved {
		t.Fatalf("resolved status = %q, want %q", resolved.Status, ThreadStatusResolved)
	}
	if len(resolved.Messages) != 2 {
		t.Fatalf("message count = %d, want %d", len(resolved.Messages), 2)
	}

	listReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-1/pull-requests/7/threads", nil)
	listResp := httptest.NewRecorder()
	mux.ServeHTTP(listResp, listReq)

	if listResp.Code != http.StatusOK {
		t.Fatalf("list status = %d, want %d", listResp.Code, http.StatusOK)
	}
	var listed struct {
		Items []Thread `json:"items"`
		Total int      `json:"total"`
	}
	if err := json.Unmarshal(listResp.Body.Bytes(), &listed); err != nil {
		t.Fatalf("decode list response: %v", err)
	}
	if listed.Total != 1 {
		t.Fatalf("listed total = %d, want %d", listed.Total, 1)
	}
}
