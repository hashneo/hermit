package rfc

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
