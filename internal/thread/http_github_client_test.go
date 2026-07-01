package thread

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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

func (r resolverStub) ResolveRepositoryAccess(id string) (owner, name, registry, baseURL, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool) {
	_ = id
	return r.owner, r.name, r.reg, "", r.branch, r.docs, "hermit:rfc-ready", r.token, r.found
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

func TestHTTPGitHubClient_CreateThread_422ReturnsError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.Contains(r.URL.Path, "/pulls/") {
			w.WriteHeader(http.StatusUnprocessableEntity)
			_, _ = w.Write([]byte(`{"message":"pull_request_review_thread.line is not part of the diff"}`))
			return
		}
		t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()

	// Use "api.github.com" in the base URL to exercise the GitHub code path.
	client := NewHTTPGitHubClient(
		resolverStub{owner: "owner", name: "repo", reg: "gh", token: "tok", found: true},
		map[string]string{"gh": server.URL + "/api.github.com"},
	)

	_, _, err := client.CreateThread(context.Background(), Thread{
		RepositoryID: "repo_1",
		PRNumber:     42,
		Anchor: Anchor{
			LineStart:       5,
			LineEnd:         5,
			TextFingerprint: "unchanged-line",
			FilePath:        "docs-cms/rfcs/rfc-001.md",
		},
		Messages: []Message{{Body: "comment on unchanged line"}},
	})
	if err == nil {
		t.Fatal("expected error for 422, got nil")
	}
	if !strings.Contains(err.Error(), "422") {
		t.Fatalf("expected error to mention 422, got: %v", err)
	}
	if !strings.Contains(err.Error(), "not part of the PR diff") {
		t.Fatalf("expected error to explain the line is not in the diff, got: %v", err)
	}
}

func TestHTTPGitHubClient_CreateThread_GitHub_PostsInlineComment(t *testing.T) {
	reviewCalled := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.Contains(r.URL.Path, "/pulls/42/reviews") {
			reviewCalled = true
			var payload struct {
				Event    string `json:"event"`
				Comments []struct {
					Path string `json:"path"`
					Line int    `json:"line"`
					Side string `json:"side"`
					Body string `json:"body"`
				} `json:"comments"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatalf("decode payload: %v", err)
			}
			if payload.Comments[0].Line != 13 {
				t.Fatalf("expected line 13, got %d", payload.Comments[0].Line)
			}
			if payload.Comments[0].Side != "RIGHT" {
				t.Fatalf("expected side RIGHT, got %q", payload.Comments[0].Side)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"id": int64(1234)})
			return
		}
		t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()

	client := NewHTTPGitHubClient(
		resolverStub{owner: "owner", name: "repo", reg: "gh", token: "test-token", found: true},
		map[string]string{"gh": server.URL + "/api.github.com"},
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
		t.Fatal("expected GitHub reviews API to be called")
	}
	if commentID != "1234" {
		t.Fatalf("expected comment id 1234, got %q", commentID)
	}
	if threadID != "repo_1:42:1234" {
		t.Fatalf("unexpected thread handle: %q", threadID)
	}
}

func TestHTTPGitHubClient_ListThreads_IncludesReplies(t *testing.T) {
	t0 := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	t1 := t0.Add(time.Minute)

	// Simulate GET /pulls/7/comments returning a root comment and one reply.
	comments := []map[string]any{
		{
			"id":                int64(100),
			"in_reply_to_id":    int64(0),
			"body":              "root comment",
			"user":              map[string]any{"login": "alice"},
			"path":              "docs-cms/rfcs/rfc-001.md",
			"position":          5,
			"original_position": 5,
			"created_at":        t0.Format(time.RFC3339),
			"updated_at":        t0.Format(time.RFC3339),
		},
		{
			"id":                int64(101),
			"in_reply_to_id":    int64(100),
			"body":              "reply comment",
			"user":              map[string]any{"login": "bob"},
			"path":              "docs-cms/rfcs/rfc-001.md",
			"position":          5,
			"original_position": 5,
			"created_at":        t1.Format(time.RFC3339),
			"updated_at":        t1.Format(time.RFC3339),
		},
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/repos/owner/repo/pulls/7/comments" {
			_ = json.NewEncoder(w).Encode(comments)
		} else if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/graphql") {
			// Return an empty resolved-threads response for the new fetchResolvedThreadIDs call.
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"pullRequest": map[string]any{
							"reviewThreads": map[string]any{
								"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""},
								"nodes":    []any{},
							},
						},
					},
				},
			})
		} else {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubClient(
		resolverStub{owner: "owner", name: "repo", reg: "gh", token: "tok", found: true},
		map[string]string{"gh": server.URL},
	)

	threads, err := client.ListThreads(context.Background(), "repo_1", 7)
	if err != nil {
		t.Fatalf("ListThreads error: %v", err)
	}
	if len(threads) != 1 {
		t.Fatalf("expected 1 thread, got %d", len(threads))
	}
	th := threads[0]
	if len(th.Messages) != 2 {
		t.Fatalf("expected 2 messages (root + reply), got %d", len(th.Messages))
	}
	if th.Messages[0].Author != "alice" {
		t.Fatalf("expected first message author alice, got %q", th.Messages[0].Author)
	}
	if th.Messages[1].Author != "bob" {
		t.Fatalf("expected second message author bob, got %q", th.Messages[1].Author)
	}
}

// TestResolveThread_GitHub verifies that ResolveThread on a github.com repo:
//  1. Queries the GraphQL endpoint to find the thread node ID by comment databaseId.
//  2. Calls the resolveReviewThread mutation with that node ID.
//  3. Returns nil on success.
func TestResolveThread_GitHub(t *testing.T) {
	const (
		commentDBID  = int64(9876)
		threadNodeID = "PRRT_kwDOABC123"
	)

	findCalled := false
	mutateCalled := false

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/graphql") {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var body struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)

		if strings.Contains(body.Query, "reviewThreads") {
			findCalled = true
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"pullRequest": map[string]any{
							"reviewThreads": map[string]any{
								"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""},
								"nodes": []map[string]any{{
									"id": threadNodeID,
									"comments": map[string]any{
										"nodes": []map[string]any{{"databaseId": commentDBID}},
									},
								}},
							},
						},
					},
				},
			})
		} else if strings.Contains(body.Query, "resolveReviewThread") {
			mutateCalled = true
			if v, ok := body.Variables["threadID"]; !ok || v != threadNodeID {
				t.Fatalf("mutation threadID = %v, want %q", v, threadNodeID)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": map[string]any{
					"resolveReviewThread": map[string]any{
						"thread": map[string]any{"id": threadNodeID, "isResolved": true},
					},
				},
			})
		} else {
			t.Fatalf("unexpected graphql query: %s", body.Query)
		}
	}))
	defer server.Close()

	// Embed "api.github.com" in the base URL so the GitHub code path is taken.
	client := NewHTTPGitHubClient(
		resolverStub{owner: "owner", name: "repo", reg: "gh", token: "tok", found: true},
		map[string]string{"gh": server.URL + "/api.github.com"},
	)

	err := client.ResolveThread(context.Background(), "repo_1:42:9876")
	if err != nil {
		t.Fatalf("ResolveThread error: %v", err)
	}
	if !findCalled {
		t.Fatal("expected GraphQL reviewThreads query to be called")
	}
	if !mutateCalled {
		t.Fatal("expected resolveReviewThread mutation to be called")
	}
}
