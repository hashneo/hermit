package thread

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type resolverStub struct {
	owner  string
	name   string
	reg    string
	token  string
	found  bool
	branch string
	docs   string
}

func (r resolverStub) ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, token string, ok bool) {
	_ = id
	return r.owner, r.name, r.reg, r.branch, r.docs, r.token, r.found
}

func TestHTTPGitHubClient_CreateThreadPostsInlineComment(t *testing.T) {
	commentCalled := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/repos/owner/repo/pulls/42":
			// Head SHA prefetch
			_ = json.NewEncoder(w).Encode(map[string]any{
				"head": map[string]any{"sha": "abc123sha"},
			})
		case r.Method == http.MethodPost && r.URL.Path == "/repos/owner/repo/pulls/42/comments":
			commentCalled = true
			if r.Header.Get("Authorization") != "Bearer test-token" {
				t.Fatalf("expected bearer auth header")
			}
			var payload struct {
				Body      string `json:"body"`
				CommitID  string `json:"commit_id"`
				Path      string `json:"path"`
				Line      int    `json:"line"`
				Side      string `json:"side"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatalf("decode payload: %v", err)
			}
			if payload.Path != "docs-cms/rfcs/rfc-001.md" {
				t.Fatalf("expected path docs-cms/rfcs/rfc-001.md, got %q", payload.Path)
			}
			if payload.Line != 13 {
				t.Fatalf("expected line 13, got %d", payload.Line)
			}
			if payload.CommitID != "abc123sha" {
				t.Fatalf("expected commit_id abc123sha, got %q", payload.CommitID)
			}
			if payload.Side != "RIGHT" {
				t.Fatalf("expected side RIGHT, got %q", payload.Side)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"id": int64(9001)})
		default:
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubClient(
		resolverStub{owner: "owner", name: "repo", reg: "gh", token: "test-token", found: true},
		map[string]string{"gh": server.URL},
	)

	threadID, commentID, err := client.CreateThread(context.Background(), Thread{
		RepositoryID: "repo_1",
		PRNumber:     42,
		Anchor: Anchor{
			LineStart:       12,
			LineEnd:         13,
			TextFingerprint: "hello-world",
			FilePath:        "docs-cms/rfcs/rfc-001.md",
		},
		Messages: []Message{{Body: "first comment"}},
	})
	if err != nil {
		t.Fatalf("CreateThread error: %v", err)
	}
	if !commentCalled {
		t.Fatalf("expected github inline comment API to be called")
	}
	if commentID != "9001" {
		t.Fatalf("expected comment id 9001, got %q", commentID)
	}
	if threadID != "repo_1:42:9001" {
		t.Fatalf("unexpected thread handle: %q", threadID)
	}
}
