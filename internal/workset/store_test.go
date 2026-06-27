package workset

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStorePersistsCacheEntries(t *testing.T) {
	dataDir := t.TempDir()
	store, err := Open(dataDir)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}

	payload := map[string]any{"items": []string{"one"}}
	if _, err := store.PutCacheSuccess(context.Background(), "test_scope", "test:key", payload); err != nil {
		t.Fatalf("put cache: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close store: %v", err)
	}

	reopened, err := Open(dataDir)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	t.Cleanup(func() { _ = reopened.Close() })

	data, meta, ok, err := reopened.GetFreshCache(context.Background(), "test:key", time.Hour)
	if err != nil {
		t.Fatalf("get cache: %v", err)
	}
	if !ok {
		t.Fatalf("expected fresh cache entry")
	}
	if !meta.Cached {
		t.Fatalf("cache metadata cached = false, want true")
	}
	var decoded map[string][]string
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if got := decoded["items"][0]; got != "one" {
		t.Fatalf("cached item = %q, want one", got)
	}
	if _, err := os.Stat(filepath.Join(dataDir, databaseFilename)); err != nil {
		t.Fatalf("expected sqlite database file: %v", err)
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
