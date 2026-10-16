package authstatus

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"hermit/internal/repository"
	"hermit/internal/workset"
)

func newRepoService(t *testing.T, token string) (string, *repository.Service) {
	t.Helper()
	svc := repository.NewService(nil)
	handler := repository.NewHandler(svc)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories", handler.CreateRepository)

	body := `{"owner":"hashneo","name":"hermit","personal_access_token":"` + token + `","team":"platform"}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories", bytes.NewBufferString(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create repo status = %d, want 201", rec.Code)
	}
	var cfg repository.Config
	if err := json.Unmarshal(rec.Body.Bytes(), &cfg); err != nil {
		t.Fatalf("decode created repo: %v", err)
	}
	return cfg.ID, svc
}

func TestGetAuthStatus_AuthFailedFromCache(t *testing.T) {
	repoID, svc := newRepoService(t, "ghp_validtoken123")
	store := openStore(t)
	ctx := context.Background()
	if err := store.PutRepositoryRFCListError(ctx, repoID, "src", "auth_failed", "list RFCs failed: 401 bad credentials"); err != nil {
		t.Fatalf("put error: %v", err)
	}

	h := NewHandler(svc, store)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/{repositoryId}/auth-status", nil)
	req.SetPathValue("repositoryId", repoID)
	rec := httptest.NewRecorder()
	h.GetAuthStatus(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var resp Response
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.State != StateAuthenticationReqd {
		t.Errorf("state = %q, want %q", resp.State, StateAuthenticationReqd)
	}
	if resp.LastErrorCode != "auth_failed" {
		t.Errorf("last_error_code = %q, want auth_failed", resp.LastErrorCode)
	}
	if resp.Remediation == "" {
		t.Errorf("expected non-empty remediation hint")
	}
}

func TestGetAuthStatus_HealthyAfterSuccess(t *testing.T) {
	repoID, svc := newRepoService(t, "ghp_validtoken123")
	store := openStore(t)
	ctx := context.Background()
	if _, err := store.PutRepositoryRFCListSuccess(ctx, repoID, "src", []byte("{}")); err != nil {
		t.Fatalf("put success: %v", err)
	}

	h := NewHandler(svc, store)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/{repositoryId}/auth-status", nil)
	req.SetPathValue("repositoryId", repoID)
	rec := httptest.NewRecorder()
	h.GetAuthStatus(rec, req)

	var resp Response
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if resp.State != StateHealthy {
		t.Errorf("state = %q, want %q", resp.State, StateHealthy)
	}
	if resp.LastErrorCode != "" {
		t.Errorf("expected empty last_error_code, got %q", resp.LastErrorCode)
	}
}

func TestGetAuthStatus_UnknownWhenNoHistory(t *testing.T) {
	repoID, svc := newRepoService(t, "ghp_validtoken123")
	store := openStore(t)

	h := NewHandler(svc, store)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/{repositoryId}/auth-status", nil)
	req.SetPathValue("repositoryId", repoID)
	rec := httptest.NewRecorder()
	h.GetAuthStatus(rec, req)

	var resp Response
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if resp.State != StateUnknown {
		t.Errorf("state = %q, want %q", resp.State, StateUnknown)
	}
}

func TestGetAuthStatus_NotFound(t *testing.T) {
	_, svc := newRepoService(t, "ghp_validtoken123")
	store := openStore(t)

	h := NewHandler(svc, store)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/{repositoryId}/auth-status", nil)
	req.SetPathValue("repositoryId", "does-not-exist")
	rec := httptest.NewRecorder()
	h.GetAuthStatus(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

func openStore(t *testing.T) *workset.Store {
	t.Helper()
	dir := t.TempDir()
	store, err := workset.Open(dir)
	if err != nil {
		t.Fatalf("open workset: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func TestDeriveState_Classifications(t *testing.T) {
	cases := []struct {
		code string
		want string
	}{
		{"auth_failed", StateAuthenticationReqd},
		{"access_denied", StateAccessDenied},
		{"provider_error", StateRefreshFailed},
		{"", StateHealthy},
	}
	for _, tc := range cases {
		resp := Response{LastErrorCode: tc.code, LastSuccessfulAt: time.RFC3339}
		if got := deriveState(resp); got != tc.want {
			t.Errorf("deriveState(code=%q) = %q, want %q", tc.code, got, tc.want)
		}
	}
}
