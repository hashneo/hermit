package workset

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreOpensConfiguredSQLiteDatabase(t *testing.T) {
	dataDir := t.TempDir()
	store, err := Open(dataDir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if _, err := os.Stat(filepath.Join(dataDir, databaseFilename)); err != nil {
		t.Fatalf("expected sqlite database file: %v", err)
	}
	if got := pragmaInt(t, store.db, "busy_timeout"); got != defaultBusyTimeoutMS {
		t.Fatalf("busy_timeout = %d, want %d", got, defaultBusyTimeoutMS)
	}
	if got := pragmaInt(t, store.db, "foreign_keys"); got != 1 {
		t.Fatalf("foreign_keys = %d, want 1", got)
	}
	if got := store.db.Stats().MaxOpenConnections; got != defaultMaxOpenConns {
		t.Fatalf("max open connections = %d, want %d", got, defaultMaxOpenConns)
	}
}

func pragmaInt(t *testing.T, db *sql.DB, name string) int {
	t.Helper()
	var v int
	if err := db.QueryRow("PRAGMA " + name).Scan(&v); err != nil {
		t.Fatalf("PRAGMA %s: %v", name, err)
	}
	return v
}

func TestStorePersistsRepositoryRFCLists(t *testing.T) {
	dataDir := t.TempDir()
	store, err := Open(dataDir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	payload := map[string]any{
		"items": []map[string]any{
			{"id": "rfc-1", "title": "Cached RFC"},
		},
		"summary": map[string]any{"pending_review_count": 1, "open_pr_count": 2},
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	if _, err := store.PutRepositoryRFCListSuccess(context.Background(), "repo-1", payloadJSON); err != nil {
		t.Fatalf("put repository rfc list: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close store: %v", err)
	}

	reopened, err := Open(dataDir)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	t.Cleanup(func() { _ = reopened.Close() })

	projection, ok, err := reopened.GetFreshRepositoryRFCList(context.Background(), "repo-1", time.Hour)
	if err != nil {
		t.Fatalf("get repository rfc list: %v", err)
	}
	if !ok {
		t.Fatalf("expected fresh repository rfc list")
	}
	if !projection.Cache.Cached {
		t.Fatalf("repository rfc list metadata cached = false, want true")
	}
	var decoded struct {
		Items []struct {
			Title string `json:"title"`
		} `json:"items"`
	}
	if err := json.Unmarshal(projection.Payload, &decoded); err != nil {
		t.Fatalf("decode repository rfc list: %v", err)
	}
	if got := decoded.Items[0].Title; got != "Cached RFC" {
		t.Fatalf("cached title = %q, want Cached RFC", got)
	}

	if err := reopened.PutRepositoryRFCListError(context.Background(), "repo-1", "provider_error", "rate limited"); err != nil {
		t.Fatalf("put repository rfc list error: %v", err)
	}
	projection, ok, err = reopened.GetAnyRepositoryRFCList(context.Background(), "repo-1", time.Hour)
	if err != nil {
		t.Fatalf("get any repository rfc list: %v", err)
	}
	if !ok {
		t.Fatalf("expected stale repository rfc list after error")
	}
	if projection.Cache.LastErrorCode != "provider_error" || projection.Cache.LastErrorMessage != "rate limited" {
		t.Fatalf("error metadata = %q/%q, want provider_error/rate limited", projection.Cache.LastErrorCode, projection.Cache.LastErrorMessage)
	}

	if err := reopened.InvalidateRepositoryRFCList(context.Background(), "repo-1"); err != nil {
		t.Fatalf("invalidate repository rfc list: %v", err)
	}
	if _, ok, err := reopened.GetFreshRepositoryRFCList(context.Background(), "repo-1", time.Hour); err != nil {
		t.Fatalf("get invalidated repository rfc list: %v", err)
	} else if ok {
		t.Fatalf("expected invalidated repository rfc list cache miss")
	}
}

func TestStoreEnqueuesOperationMetadata(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	err = store.EnqueueOperation(context.Background(), Operation{
		ID:          "op-1",
		Kind:        "repository_refresh",
		Priority:    10,
		DedupeKey:   "repo-1",
		PayloadJSON: `{"repository_id":"repo-1"}`,
	})
	if err != nil {
		t.Fatalf("enqueue operation: %v", err)
	}
}

func TestStoreCachesRenderedReviewDocumentsByCommit(t *testing.T) {
	dataDir := t.TempDir()
	store, err := Open(dataDir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	payload := []byte(`{"id":"pr:7:docs-cms/rfcs/rfc-007-cache.md","title":"Cached Render","path":"docs-cms/rfcs/rfc-007-cache.md","head_sha":"abc123","markdown_source":"# Cached Render\n"}`)
	if err := store.PutRenderedReviewDocument(context.Background(), "repo-1", "ABC123", "/docs-cms/rfcs/rfc-007-cache.md", payload); err != nil {
		t.Fatalf("put rendered review document: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close store: %v", err)
	}

	reopened, err := Open(dataDir)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	t.Cleanup(func() { _ = reopened.Close() })

	got, ok, err := reopened.GetRenderedReviewDocument(context.Background(), "repo-1", "abc123", "docs-cms/rfcs/rfc-007-cache.md")
	if err != nil {
		t.Fatalf("get rendered review document: %v", err)
	}
	if !ok {
		t.Fatalf("expected rendered review document cache hit")
	}
	if string(got) != string(payload) {
		t.Fatalf("cached payload = %s, want %s", got, payload)
	}

	if _, ok, err := reopened.GetRenderedReviewDocument(context.Background(), "repo-1", "def456", "docs-cms/rfcs/rfc-007-cache.md"); err != nil {
		t.Fatalf("get rendered review document miss: %v", err)
	} else if ok {
		t.Fatalf("expected different commit sha to miss rendered review document cache")
	}
}
