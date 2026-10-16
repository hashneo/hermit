package rfc

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"hermit/internal/workset"
)

func TestRepositoryCatalogPreservesDocumentTypes(t *testing.T) {
	structures := map[string]string{
		"legacy":           "  rfc_dir: rfcs\n  adr_dir: adr\n  prd_dir: prd\n  memo_dir: memos\n",
		"doc_types":        "  docs_roots: [.]\n  doc_types:\n    rfc: {schema: rfc, folders: [rfcs]}\n    adr: {schema: adr, folders: [adr]}\n    prd: {schema: prd, folders: [prd]}\n    memo: {schema: memo, folders: [memos]}\n",
		"document_folders": "  document_folders: [rfcs, adr, prd, memos]\n",
	}
	for name, structure := range structures {
		t.Run(name, func(t *testing.T) {
			docs := map[string]string{
				"docs-cms/rfcs/rfc-001-example.md":   "rfc",
				"docs-cms/adr/adr-002-example.md":    "adr",
				"docs-cms/prd/prd-003-example.md":    "prd",
				"docs-cms/memos/memo-004-example.md": "memo",
			}
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/repos/owner/repo/pulls" {
					_ = json.NewEncoder(w).Encode([]any{})
					return
				}
				file := strings.TrimPrefix(r.URL.Path, "/repos/owner/repo/contents/")
				if file == "docs-cms/docs-project.yaml" {
					writeContentResponse(t, w, file, "project: {id: example, name: Example}\nstructure:\n"+structure)
					return
				}
				if kind, ok := docs[file]; ok {
					writeContentResponse(t, w, file, "---\ntitle: Example "+kind+"\nstatus: accepted\n---\nContent")
					return
				}
				var entries []map[string]string
				for path := range docs {
					if strings.HasPrefix(path, file+"/") {
						entries = append(entries, map[string]string{"path": path, "type": "file"})
					}
				}
				if len(entries) > 0 {
					entries = append(entries, map[string]string{"path": file + "/index.md", "type": "file"})
					_ = json.NewEncoder(w).Encode(entries)
					return
				}
				http.NotFound(w, r)
			}))
			defer provider.Close()
			resolver := &fakeResolver{owner: "owner", name: "repo", registry: "test", branch: "main", docsPath: "docs-cms/rfcs", token: "test-token"}
			service := NewServiceWithRepositoryResolver(resolver, map[string]string{"test": provider.URL})
			store, err := workset.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			service.WithWorkset(store)
			for _, refresh := range []bool{true, false} {
				response, err := service.ListRFCsByRepository(t.Context(), "repo-1", refresh)
				if err != nil {
					t.Fatal(err)
				}
				if len(response.Items) != len(docs) {
					t.Fatalf("got %d items, want %d: %+v", len(response.Items), len(docs), response.Items)
				}
				for _, item := range response.Items {
					if want := docs[item.Path]; want == "" || item.DocumentType != want {
						t.Errorf("%s type = %q, want %q", item.Path, item.DocumentType, want)
					}
				}
				if !refresh && (response.Cache == nil || !response.Cache.Cached) {
					t.Fatal("second read did not use cache")
				}
			}
		})
	}
}
