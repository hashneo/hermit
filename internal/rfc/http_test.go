package rfc

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeResolver implements RepositoryResolver for tests.
type fakeResolver struct {
	owner, name, registry, branch, docsPath, token string
}

func (f *fakeResolver) ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, token string, ok bool) {
	return f.owner, f.name, f.registry, f.branch, f.docsPath, f.token, true
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
