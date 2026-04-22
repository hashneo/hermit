package thread

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

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
			AnchorID:        "anc_1002",
			LineStart:       10,
			LineEnd:         12,
			FormattedLineStart: 22,
			FormattedLineEnd:   25,
			TextFingerprint: "abc123",
			FilePath:        "docs-cms/rfcs/rfc-001.md",
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

func TestServiceLoadsFromStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "threads.json")
	store := NewFileStore(path)

	now := time.Now().UTC().Truncate(time.Second)
	seed := []Thread{{
		ID:           "thr_1200",
		RepositoryID: "repo-1",
		PRNumber:     7,
		Status:       ThreadStatusOpen,
		Anchor: Anchor{
			AnchorID:        "anc_1201",
			LineStart:       20,
			LineEnd:         21,
			TextFingerprint: "seed",
		},
		Messages: []Message{{
			ID:           "msg_1202",
			Author:       "seed",
			Body:         "hello",
			SourceSystem: "hermit",
			CreatedAt:    now,
		}},
		CreatedAt: now,
		UpdatedAt: now,
	}}
	if err := store.Save(seed); err != nil {
		t.Fatalf("save seed: %v", err)
	}

	service := NewServiceWithStore(NewInMemoryGitHubClient(), store)
	loaded := service.List("repo-1", 7)
	if len(loaded) != 1 {
		t.Fatalf("expected 1 loaded thread, got %d", len(loaded))
	}
	if loaded[0].ID != "thr_1200" {
		t.Fatalf("expected loaded id thr_1200, got %q", loaded[0].ID)
	}

	created, err := service.Create(context.Background(), CreateRequest{
		RepositoryID: "repo-1",
		PRNumber:     7,
		Anchor: Anchor{
			LineStart:       30,
			LineEnd:         31,
			TextFingerprint: "new",
		},
		Body: "new comment",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.ID == "thr_1200" {
		t.Fatalf("expected new unique id, got reused id %q", created.ID)
	}
}
