package thread

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestThreadLifecycleCreateReplyResolve exercises the full create → reply →
// resolve lifecycle through the HTTP handler layer. Because the service is now
// a synchronous pass-through to the GitHub client, every response should
// already be in state "synced" — there is no pending / async phase.
func TestThreadLifecycleCreateReplyResolve(t *testing.T) {
	service := NewService(nil) // nil → InMemoryGitHubClient
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET "+ThreadsPath(), handler.ListThreads)
	mux.HandleFunc("POST "+ThreadsPath(), handler.CreateThread)
	mux.HandleFunc("POST "+ThreadReplyPath(), handler.ReplyThread)
	mux.HandleFunc("POST "+ThreadResolvePath(), handler.ResolveThread)

	// --- Create ---
	createBody := bytes.NewBufferString(`{"anchor":{"line_start":10,"line_end":12,"text_fingerprint":"abc123"},"body":"first"}`)
	createReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/7/threads", createBody)
	createReq.Header.Set("X-Hermit-User", "alice")
	createResp := httptest.NewRecorder()
	mux.ServeHTTP(createResp, createReq)

	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d\nbody: %s", createResp.Code, http.StatusCreated, createResp.Body)
	}

	var created Thread
	if err := json.Unmarshal(createResp.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.ID == "" {
		t.Fatal("created thread has empty ID")
	}
	// Synchronous path: should be synced immediately, not pending.
	if created.Sync.State != SyncStateSynced {
		t.Fatalf("create sync state = %q, want %q", created.Sync.State, SyncStateSynced)
	}

	// --- Reply ---
	replyBody := bytes.NewBufferString(`{"body":"follow-up"}`)
	replyReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/7/threads/"+created.ID+"/reply", replyBody)
	replyReq.Header.Set("X-Hermit-User", "bob")
	replyResp := httptest.NewRecorder()
	mux.ServeHTTP(replyResp, replyReq)

	if replyResp.Code != http.StatusOK {
		t.Fatalf("reply status = %d, want %d\nbody: %s", replyResp.Code, http.StatusOK, replyResp.Body)
	}

	var replied Thread
	if err := json.Unmarshal(replyResp.Body.Bytes(), &replied); err != nil {
		t.Fatalf("decode reply response: %v", err)
	}
	if len(replied.Messages) != 2 {
		t.Fatalf("message count after reply = %d, want 2", len(replied.Messages))
	}

	// --- Resolve ---
	resolveReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/7/threads/"+created.ID+"/resolve", nil)
	resolveResp := httptest.NewRecorder()
	mux.ServeHTTP(resolveResp, resolveReq)

	if resolveResp.Code != http.StatusOK {
		t.Fatalf("resolve status = %d, want %d\nbody: %s", resolveResp.Code, http.StatusOK, resolveResp.Body)
	}

	var resolved Thread
	if err := json.Unmarshal(resolveResp.Body.Bytes(), &resolved); err != nil {
		t.Fatalf("decode resolve response: %v", err)
	}
	if resolved.Status != ThreadStatusResolved {
		t.Fatalf("resolved status = %q, want %q", resolved.Status, ThreadStatusResolved)
	}
	if resolved.Sync.State != SyncStateSynced {
		t.Fatalf("resolve sync state = %q, want %q", resolved.Sync.State, SyncStateSynced)
	}

	// --- List ---
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
	if listed.Items[0].Status != ThreadStatusResolved {
		t.Fatalf("listed thread status = %q, want %q", listed.Items[0].Status, ThreadStatusResolved)
	}
}

// TestDeleteMessage_Guards verifies that:
//   - deleting a non-last message is rejected (409)
//   - deleting someone else's message is rejected (403)
//   - deleting your own last message succeeds (204)
func TestDeleteMessage_Guards(t *testing.T) {
	service := NewService(nil)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET "+ThreadsPath(), handler.ListThreads)
	mux.HandleFunc("POST "+ThreadsPath(), handler.CreateThread)
	mux.HandleFunc("POST "+ThreadReplyPath(), handler.ReplyThread)
	mux.HandleFunc("DELETE "+ThreadDeletePath(), handler.DeleteThread)
	mux.HandleFunc("DELETE "+ThreadMessageDeletePath(), handler.DeleteMessage)

	// Create a thread as alice.
	body := bytes.NewBufferString(`{"anchor":{"line_start":1,"line_end":1,"text_fingerprint":"fp1"},"body":"alice root"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/3/threads", body)
	req.Header.Set("X-Hermit-User", "alice")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var created Thread
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	rootMsgID := created.Messages[0].ID
	threadID := created.ID

	// Add a reply as bob.
	body = bytes.NewBufferString(`{"body":"bob reply"}`)
	req = httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/pull-requests/3/threads/"+threadID+"/reply", body)
	req.Header.Set("X-Hermit-User", "bob")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("reply: %d %s", rec.Code, rec.Body)
	}
	var replied Thread
	_ = json.Unmarshal(rec.Body.Bytes(), &replied)
	replyMsgID := replied.Messages[1].ID

	// --- Guard: cannot delete non-last message (alice's root, bob's reply is last) ---
	req = httptest.NewRequest(http.MethodDelete, "/api/v1/repositories/repo-1/pull-requests/3/threads/"+threadID+"/messages/"+rootMsgID, nil)
	req.Header.Set("X-Hermit-User", "alice")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("delete non-last: want 409, got %d %s", rec.Code, rec.Body)
	}

	// --- Guard: cannot delete someone else's last message ---
	req = httptest.NewRequest(http.MethodDelete, "/api/v1/repositories/repo-1/pull-requests/3/threads/"+threadID+"/messages/"+replyMsgID, nil)
	req.Header.Set("X-Hermit-User", "alice") // alice trying to delete bob's reply
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("delete other's message: want 403, got %d %s", rec.Code, rec.Body)
	}

	// --- Success: bob deletes their own last message ---
	req = httptest.NewRequest(http.MethodDelete, "/api/v1/repositories/repo-1/pull-requests/3/threads/"+threadID+"/messages/"+replyMsgID, nil)
	req.Header.Set("X-Hermit-User", "bob")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete own last: want 204, got %d %s", rec.Code, rec.Body)
	}
}
