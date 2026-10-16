package rfc

import (
	"testing"

	"hermit/internal/workset"
)

func TestRepositoryCatalogRecordsMissingToken(t *testing.T) {
	resolver := &fakeResolver{owner: "owner", name: "repo", registry: "test", branch: "main", docsPath: "docs-cms/rfcs"}
	service := NewServiceWithRepositoryResolver(resolver, nil)
	store, err := workset.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	service.WithWorkset(store)
	if _, err := service.ListRFCsByRepository(t.Context(), "repo-1", true); err == nil {
		t.Fatal("missing token should fail")
	}
	meta, ok, err := store.GetRepositoryRFCListCache(t.Context(), "repo-1")
	if err != nil || !ok || meta.LastErrorCode != "auth_failed" {
		t.Fatalf("missing token auth health = %+v, found %v, error %v", meta, ok, err)
	}
}
