package thread

import (
	"path/filepath"
	"testing"
	"time"
)

// TestFileStoreSaveLoad verifies the file store can round-trip threads to disk.
// The store is no longer used by Service (GitHub is source of truth), but it
// is kept as a utility and tested here for correctness.
func TestFileStoreSaveLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "threads.json")
	store := NewFileStore(path)

	now := time.Now().UTC().Truncate(time.Second)
	threads := []Thread{{
		ID:           "thr_1001",
		RepositoryID: "repo-1",
		PRNumber:     7,
		Status:       ThreadStatusOpen,
		Anchor: Anchor{
			AnchorID:           "anc_1002",
			LineStart:          10,
			LineEnd:            12,
			FormattedLineStart: 22,
			FormattedLineEnd:   25,
			TextFingerprint:    "abc123",
			FilePath:           "docs-cms/rfcs/rfc-001.md",
		},
		Messages: []Message{{
			ID:           "msg_1003",
			Author:       "alice",
			Body:         "first",
			SourceSystem: "hermit",
			CreatedAt:    now,
		}},
		CreatedAt: now,
		UpdatedAt: now,
	}}

	if err := store.Save(threads); err != nil {
		t.Fatalf("save: %v", err)
	}

	loaded, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(loaded) != 1 {
		t.Fatalf("expected 1 thread, got %d", len(loaded))
	}
	if loaded[0].ID != threads[0].ID {
		t.Fatalf("expected id %q, got %q", threads[0].ID, loaded[0].ID)
	}
	if loaded[0].Anchor.LineEnd != 12 {
		t.Fatalf("expected line end 12, got %d", loaded[0].Anchor.LineEnd)
	}
	if loaded[0].Anchor.FormattedLineStart != 22 || loaded[0].Anchor.FormattedLineEnd != 25 {
		t.Fatalf("expected formatted line range 22-25, got %d-%d", loaded[0].Anchor.FormattedLineStart, loaded[0].Anchor.FormattedLineEnd)
	}
}
