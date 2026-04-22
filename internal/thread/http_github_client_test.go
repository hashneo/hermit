package thread

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type resolverStub struct {
	owner   string
	name    string
	reg     string
	token   string
	found   bool
	branch  string
	docs    string
}

func (r resolverStub) ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, token string, ok bool) {
	_ = id
	return r.owner, r.name, r.reg, r.branch, r.docs, r.token, r.found
}

func TestHTTPGitHubClient_CreateThreadPostsIssueComment(t *testing.T) {
	called := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/repos/owner/repo/pulls/42/reviews" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		called = true
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Fatalf("expected bearer auth header")
		}
		var payload struct {
			Event    string `json:"event"`
			Comments []struct {
				Path        string `json:"path"`
				Body        string `json:"body"`
				NewPosition int    `json:"new_position"`
			} `json:"comments"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode payload: %v", err)
		}
		if payload.Event != "COMMENT" {
			t.Fatalf("expected event COMMENT, got %q", payload.Event)
		}
		if len(payload.Comments) != 1 || payload.Comments[0].Path != "docs-cms/rfcs/rfc-001.md" {
			t.Fatalf("expected inline comment payload path, got %+v", payload.Comments)
		}
		if payload.Comments[0].NewPosition != 12 {
			t.Fatalf("expected new_position 12, got %d", payload.Comments[0].NewPosition)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"id": int64(9001)})
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
	if !called {
		t.Fatalf("expected github issue comment API to be called")
	}
	if commentID != "9001" {
		t.Fatalf("expected comment id 9001, got %q", commentID)
	}
	if threadID != "repo_1:42:9001" {
		t.Fatalf("unexpected thread handle: %q", threadID)
	}
}
