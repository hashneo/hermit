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
	reviewCalled := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Gitea creates inline comments via the review API.
		if r.Method == http.MethodPost && r.URL.Path == "/repos/owner/repo/pulls/42/reviews" {
			reviewCalled = true
			if r.Header.Get("Authorization") != "Bearer test-token" {
				t.Fatalf("expected bearer auth header")
			}
			var payload struct {
				Event    string `json:"event"`
				Comments []struct {
					Path        string `json:"path"`
					NewPosition int    `json:"new_position"`
					Body        string `json:"body"`
				} `json:"comments"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatalf("decode payload: %v", err)
			}
			if payload.Event != "COMMENT" {
				t.Fatalf("expected event COMMENT, got %q", payload.Event)
			}
			if len(payload.Comments) != 1 {
				t.Fatalf("expected 1 comment, got %d", len(payload.Comments))
			}
			if payload.Comments[0].Path != "docs-cms/rfcs/rfc-001.md" {
				t.Fatalf("expected path docs-cms/rfcs/rfc-001.md, got %q", payload.Comments[0].Path)
			}
			if payload.Comments[0].NewPosition != 13 {
				t.Fatalf("expected new_position 13, got %d", payload.Comments[0].NewPosition)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"id": int64(9001)})
		} else {
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
	if !reviewCalled {
		t.Fatalf("expected Gitea review API to be called")
	}
	if commentID != "9001" {
		t.Fatalf("expected comment id 9001, got %q", commentID)
	}
	if threadID != "repo_1:42:9001" {
		t.Fatalf("unexpected thread handle: %q", threadID)
	}
}
