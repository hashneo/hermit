package rfc

import (
	"encoding/base64"
	"encoding/json"
	"hermit/internal/workset"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// fakeResolver implements RepositoryResolver for tests.
type fakeResolver struct {
	owner, name, registry, branch, docsPath, token string
}

func (f *fakeResolver) ResolveRepositoryAccess(id string) (owner, name, registry, baseURL, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool) {
	return f.owner, f.name, f.registry, "", f.branch, f.docsPath, "hermit:rfc-ready", f.token, true
}

func TestGetDocument(t *testing.T) {
	service := NewService()
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc", handler.GetDocument)

	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-1/pull-requests/11/rfc", nil)
	getResp := httptest.NewRecorder()
	mux.ServeHTTP(getResp, getReq)

	if getResp.Code != http.StatusOK {
		t.Fatalf("get document status = %d, want %d", getResp.Code, http.StatusOK)
	}

	var doc Document
	if err := json.Unmarshal(getResp.Body.Bytes(), &doc); err != nil {
		t.Fatalf("decode document response: %v", err)
	}
	if doc.Eligibility.Status != "eligible" {
		t.Fatalf("eligibility status = %q, want eligible", doc.Eligibility.Status)
	}
}

func TestRenderPRRFC(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: draft\n---\n# Test RFC\n\nContent here.\n"
	rfcContent := base64.StdEncoding.EncodeToString([]byte(rfcMarkdown))

	// Fake Gitea/GitHub API server.
	gitea := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls" && r.URL.Query().Get("state") == "open":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"number": 1,
					"draft":  false,
					"head":   map[string]any{"sha": "abc123"},
					"labels": []map[string]any{{"name": "hermit:rfc-ready"}},
				},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/1/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-001-test.md", "status": "added"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/1":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"head": map[string]any{"sha": "abc123"},
			})
		case strings.HasPrefix(r.URL.Path, "/repos/owner/repo/contents/"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":    "rfc-001-test.md",
				"path":    "docs-cms/rfcs/rfc-001-test.md",
				"content": rfcContent,
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer gitea.Close()

	resolver := &fakeResolver{
		owner:    "owner",
		name:     "repo",
		registry: "gitea-local",
		branch:   "main",
		docsPath: "docs-cms/rfcs",
		token:    "test-token",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gitea-local": gitea.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc/render", handler.Render)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-1/pull-requests/1/rfc/render", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("render status = %d, want 200; body = %s", resp.Code, resp.Body.String())
	}

	var view DocumentView
	if err := json.Unmarshal(resp.Body.Bytes(), &view); err != nil {
		t.Fatalf("decode render response: %v", err)
	}
	if view.MarkdownSource == "" {
		t.Fatal("expected non-empty markdown_source")
	}
	if view.Title != "Test RFC" {
		t.Fatalf("title = %q, want %q", view.Title, "Test RFC")
	}
}

func TestListRepositoryRFCs_IncludesSummary(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: draft\n---\n# Test RFC\n\nContent here.\n"
	rfcContent := base64.StdEncoding.EncodeToString([]byte(rfcMarkdown))

	gitea := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs":
			_ = json.NewEncoder(w).Encode([]map[string]any{{
				"name": "rfc-001-test.md", "path": "docs-cms/rfcs/rfc-001-test.md", "type": "file",
			}})
		case r.URL.Path == "/repos/owner/repo/pulls" && r.URL.Query().Get("state") == "open":
			_ = json.NewEncoder(w).Encode([]map[string]any{{
				"number": 1,
				"draft":  false,
				"head":   map[string]any{"sha": "abc123", "ref": "feature/rfc"},
				"labels": []map[string]any{{"name": "hermit:rfc-ready"}},
			}})
		case r.URL.Path == "/repos/owner/repo/pulls/1/files":
			_ = json.NewEncoder(w).Encode([]map[string]any{{
				"filename": "docs-cms/rfcs/rfc-001-test.md", "status": "added", "additions": 3,
			}})
		case strings.HasPrefix(r.URL.Path, "/repos/owner/repo/contents/"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":    "rfc-001-test.md",
				"path":    "docs-cms/rfcs/rfc-001-test.md",
				"sha":     "blobsha",
				"content": rfcContent,
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer gitea.Close()

	resolver := &fakeResolver{
		owner:    "owner",
		name:     "repo",
		registry: "gitea-local",
		branch:   "main",
		docsPath: "docs-cms/rfcs",
		token:    "test-token",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gitea-local": gitea.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/rfcs", handler.ListRepositoryRFCs)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-1/rfcs", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("list repository rfcs status = %d, want 200; body = %s", resp.Code, resp.Body.String())
	}

	var payload struct {
		Items   []CatalogItem `json:"items"`
		Total   int           `json:"total"`
		Summary struct {
			PendingReviewCount int `json:"pending_review_count"`
			OpenPRCount        int `json:"open_pr_count"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode list repository rfcs response: %v", err)
	}
	if payload.Summary.PendingReviewCount != 1 {
		t.Fatalf("pending_review_count = %d, want 1", payload.Summary.PendingReviewCount)
	}
	if payload.Summary.OpenPRCount != 1 {
		t.Fatalf("open_pr_count = %d, want 1", payload.Summary.OpenPRCount)
	}
	if payload.Total != len(payload.Items) {
		t.Fatalf("total = %d, want %d", payload.Total, len(payload.Items))
	}
}

func TestListRepositoryRFCs_UsesSQLiteCache(t *testing.T) {
	rfcMarkdown := "---\ntitle: Cached RFC\nstatus: accepted\n---\n# Cached RFC\n\nBody.\n"
	rfcContent := base64.StdEncoding.EncodeToString([]byte(rfcMarkdown))
	var upstreamCalls atomic.Int64

	gitea := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls.Add(1)
		switch {
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs":
			_ = json.NewEncoder(w).Encode([]map[string]any{{
				"name": "rfc-001-cached.md", "path": "docs-cms/rfcs/rfc-001-cached.md", "type": "file",
			}})
		case r.URL.Path == "/repos/owner/repo/pulls" && r.URL.Query().Get("state") == "open":
			_ = json.NewEncoder(w).Encode([]map[string]any{})
		case strings.HasPrefix(r.URL.Path, "/repos/owner/repo/contents/"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name": "rfc-001-cached.md", "path": "docs-cms/rfcs/rfc-001-cached.md", "sha": "blobsha", "content": rfcContent,
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer gitea.Close()

	resolver := &fakeResolver{
		owner:    "owner",
		name:     "repo",
		registry: "gitea-local",
		branch:   "main",
		docsPath: "docs-cms/rfcs",
		token:    "test-token",
	}
	store, err := workset.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open sqlite workset: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gitea-local": gitea.URL})
	service.WithWorkset(store)

	first, err := service.ListRFCsByRepository(t.Context(), "repo-1")
	if err != nil {
		t.Fatalf("first list repository rfcs: %v", err)
	}
	callsAfterFirst := upstreamCalls.Load()
	if callsAfterFirst == 0 {
		t.Fatalf("expected first call to hit upstream")
	}
	if first.Cache == nil || first.Cache.Cached {
		t.Fatalf("first response cache metadata = %+v, want fresh non-cached metadata", first.Cache)
	}

	second, err := service.ListRFCsByRepository(t.Context(), "repo-1")
	if err != nil {
		t.Fatalf("second list repository rfcs: %v", err)
	}
	if upstreamCalls.Load() != callsAfterFirst {
		t.Fatalf("second call hit upstream: calls before=%d after=%d", callsAfterFirst, upstreamCalls.Load())
	}
	if second.Cache == nil || !second.Cache.Cached {
		t.Fatalf("second response cache metadata = %+v, want cached metadata", second.Cache)
	}
	if second.Total != first.Total {
		t.Fatalf("second total = %d, want %d", second.Total, first.Total)
	}
}

// newLifecycleTestServer builds a fake GitHub API server that serves a single RFC
// and responds to user/permission/contents endpoints as needed for lifecycle tests.
func newLifecycleTestServer(t *testing.T, rfcMarkdown, permission string, captureCommit *string) *httptest.Server {
	t.Helper()
	rfcContent := base64.StdEncoding.EncodeToString([]byte(rfcMarkdown))

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		// Authenticated user lookup
		case r.URL.Path == "/user":
			_ = json.NewEncoder(w).Encode(map[string]string{"login": "alice"})

		// Collaborator permission
		case strings.HasPrefix(r.URL.Path, "/repos/owner/repo/collaborators/alice/permission"):
			_ = json.NewEncoder(w).Encode(map[string]string{"permission": permission})

		// RFC content GET
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/repos/owner/repo/contents/"):
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":    "rfc-001-test.md",
				"path":    "docs-cms/rfcs/rfc-001-test.md",
				"sha":     "blobsha",
				"content": rfcContent,
			})

		// RFC content PUT (commit)
		case r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/repos/owner/repo/contents/"):
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			if captureCommit != nil {
				if msg, ok := body["message"].(string); ok {
					*captureCommit = msg
				}
			}
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"commit": map[string]string{"sha": "newsha123"},
			})

		default:
			http.NotFound(w, r)
		}
	}))
}

func TestApproveRFC_Success(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: draft\n---\n# Test RFC\n"
	var capturedCommitMsg string
	srv := newLifecycleTestServer(t, rfcMarkdown, "admin", &capturedCommitMsg)
	defer srv.Close()

	resolver := &fakeResolver{
		owner: "owner", name: "repo",
		registry: "gh", branch: "main",
		docsPath: "docs-cms/rfcs", token: "tok",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gh": srv.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/approve", handler.ApproveRFC)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/rfcs/docs-cms%2Frfcs%2Frfc-001-test.md/approve", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("approve status = %d, want 200; body = %s", resp.Code, resp.Body.String())
	}
	var result LifecycleTransitionResult
	if err := json.Unmarshal(resp.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode approve response: %v", err)
	}
	if result.NewStatus != "accepted" {
		t.Errorf("new_status = %q, want accepted", result.NewStatus)
	}
	if result.CommitSHA != "newsha123" {
		t.Errorf("commit_sha = %q, want newsha123", result.CommitSHA)
	}
}

func TestApproveRFC_Forbidden(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: draft\n---\n# Test RFC\n"
	srv := newLifecycleTestServer(t, rfcMarkdown, "read", nil)
	defer srv.Close()

	resolver := &fakeResolver{
		owner: "owner", name: "repo",
		registry: "gh", branch: "main",
		docsPath: "docs-cms/rfcs", token: "tok",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gh": srv.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/approve", handler.ApproveRFC)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/rfcs/docs-cms%2Frfcs%2Frfc-001-test.md/approve", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d; body = %s", resp.Code, resp.Body.String())
	}
}

func TestApproveRFC_WrongStatus(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: accepted\n---\n# Test RFC\n"
	srv := newLifecycleTestServer(t, rfcMarkdown, "admin", nil)
	defer srv.Close()

	resolver := &fakeResolver{
		owner: "owner", name: "repo",
		registry: "gh", branch: "main",
		docsPath: "docs-cms/rfcs", token: "tok",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gh": srv.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/approve", handler.ApproveRFC)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/rfcs/docs-cms%2Frfcs%2Frfc-001-test.md/approve", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d; body = %s", resp.Code, resp.Body.String())
	}
}

func TestMarkImplemented_Success(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: accepted\n---\n# Test RFC\n"
	var capturedCommitMsg string
	srv := newLifecycleTestServer(t, rfcMarkdown, "admin", &capturedCommitMsg)
	defer srv.Close()

	resolver := &fakeResolver{
		owner: "owner", name: "repo",
		registry: "gh", branch: "main",
		docsPath: "docs-cms/rfcs", token: "tok",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gh": srv.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/mark-implemented", handler.MarkImplemented)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/rfcs/docs-cms%2Frfcs%2Frfc-001-test.md/mark-implemented", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("mark-implemented status = %d, want 200; body = %s", resp.Code, resp.Body.String())
	}
	var result LifecycleTransitionResult
	if err := json.Unmarshal(resp.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode mark-implemented response: %v", err)
	}
	if result.NewStatus != "implemented" {
		t.Errorf("new_status = %q, want implemented", result.NewStatus)
	}
}

func TestMarkImplemented_Forbidden(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: accepted\n---\n# Test RFC\n"
	srv := newLifecycleTestServer(t, rfcMarkdown, "write", nil)
	defer srv.Close()

	resolver := &fakeResolver{
		owner: "owner", name: "repo",
		registry: "gh", branch: "main",
		docsPath: "docs-cms/rfcs", token: "tok",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gh": srv.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/mark-implemented", handler.MarkImplemented)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/rfcs/docs-cms%2Frfcs%2Frfc-001-test.md/mark-implemented", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d; body = %s", resp.Code, resp.Body.String())
	}
}

func TestMarkImplemented_WrongStatus(t *testing.T) {
	rfcMarkdown := "---\ntitle: Test RFC\nstatus: draft\n---\n# Test RFC\n"
	srv := newLifecycleTestServer(t, rfcMarkdown, "admin", nil)
	defer srv.Close()

	resolver := &fakeResolver{
		owner: "owner", name: "repo",
		registry: "gh", branch: "main",
		docsPath: "docs-cms/rfcs", token: "tok",
	}
	service := NewServiceWithRepositoryResolver(resolver, map[string]string{"gh": srv.URL})
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/mark-implemented", handler.MarkImplemented)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/repo-1/rfcs/docs-cms%2Frfcs%2Frfc-001-test.md/mark-implemented", nil)
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d; body = %s", resp.Code, resp.Body.String())
	}
}
