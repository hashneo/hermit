package rfc

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPGitHubRFCClient_ListRFCs_FiltersNonDocuchangoFilenames(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode([]map[string]string{
			{"name": "rfc-001-valid-name.md", "path": "docs-cms/rfcs/rfc-001-valid-name.md", "type": "file"},
			{"name": "invalid-name.md", "path": "docs-cms/rfcs/invalid-name.md", "type": "file"},
			{"name": "rfc-002-upper-Case.md", "path": "docs-cms/rfcs/rfc-002-upper-Case.md", "type": "file"},
		})
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListRFCs(context.Background(), server.URL, "owner", "repo", "main", "docs-cms/rfcs", "token")
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}

	if len(items) != 1 {
		t.Fatalf("expected one valid docuchango RFC file, got %d", len(items))
	}
	if items[0].ID != "docs-cms/rfcs/rfc-001-valid-name.md" {
		t.Fatalf("expected valid RFC path, got %q", items[0].ID)
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_FiltersDraftPRsAndRFCPaths(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls" && r.URL.Query().Get("state") == "open":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 10, "draft": false, "head": map[string]any{"sha": "sha-ready"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
				{"number": 11, "draft": true, "head": map[string]any{"sha": "sha-draft"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/10/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-001-main-list.md", "status": "modified"},
				{"filename": "docs-cms/notes.md", "status": "modified"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/11/files":
			t.Fatalf("draft PR file list should not be requested")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-001-main-list.md":
			if r.URL.Query().Get("ref") != "sha-ready" {
				t.Fatalf("expected RFC content request at head sha, got %q", r.URL.Query().Get("ref"))
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-001-main-list.md",
				"path":    "docs-cms/rfcs/rfc-001-main-list.md",
				"content": "LS0tCnRpdGxlOiBSZWFkeSBQUiBSRkMKLS0tCgojIFJlYWR5IFBSIFJGQwo=",
			})
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}

	if len(items) != 1 {
		t.Fatalf("expected one review-ready RFC item, got %d", len(items))
	}
	if items[0].PRNumber != 10 {
		t.Fatalf("expected PR number 10, got %d", items[0].PRNumber)
	}
	if items[0].Path != "docs-cms/rfcs/rfc-001-main-list.md" {
		t.Fatalf("expected RFC path, got %q", items[0].Path)
	}
	if items[0].Title != "Ready PR RFC" {
		t.Fatalf("expected title from markdown content, got %q", items[0].Title)
	}
	if len(items[0].Labels) != 1 || items[0].Labels[0] != "hermit:rfc-ready" {
		t.Fatalf("expected labels to contain hermit:rfc-ready, got %v", items[0].Labels)
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_ExcludesPRsWithoutRFCReadyLabel(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls":
			// Return two PRs: one with the label, one without.
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 20, "draft": false, "head": map[string]any{"sha": "sha-labeled"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
				{"number": 21, "draft": false, "head": map[string]any{"sha": "sha-unlabeled"}, "labels": []map[string]any{}},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/20/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-010-labeled.md", "status": "added"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/21/files":
			t.Fatalf("unlabeled PR file list should not be requested")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-010-labeled.md":
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-010-labeled.md",
				"path":    "docs-cms/rfcs/rfc-010-labeled.md",
				"content": "IyBMYWJlbGVkIFJGQwo=",
			})
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}

	if len(items) != 1 {
		t.Fatalf("expected only the labeled PR RFC, got %d items", len(items))
	}
	if items[0].PRNumber != 20 {
		t.Fatalf("expected PR 20 (labeled), got PR %d", items[0].PRNumber)
	}
}

func TestHTTPGitHubRFCClient_GetRFCFromPullRequest_UsesHeadSHAAndValidatesMembership(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls/23":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"head": map[string]any{"sha": "sha-pr-23"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/23/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-002-target.md", "status": "modified"},
			})
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-002-target.md":
			if r.URL.Query().Get("ref") != "sha-pr-23" {
				t.Fatalf("expected content lookup at PR head sha, got %q", r.URL.Query().Get("ref"))
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-002-target.md",
				"path":    "docs-cms/rfcs/rfc-002-target.md",
				"content": "IyBQUiBkb2N1bWVudA==",
			})
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	view, err := client.GetRFCFromPullRequest(context.Background(), server.URL, "owner", "repo", 23, "docs-cms/rfcs/rfc-002-target.md", "token")
	if err != nil {
		t.Fatalf("GetRFCFromPullRequest returned error: %v", err)
	}

	if !strings.Contains(view.RenderedHTML, "PR document") {
		t.Fatalf("expected rendered html to include markdown content")
	}

	_, err = client.GetRFCFromPullRequest(context.Background(), server.URL, "owner", "repo", 23, "docs-cms/rfcs/rfc-999-missing.md", "token")
	if err == nil {
		t.Fatalf("expected error when requested file is not part of PR")
	}
}
