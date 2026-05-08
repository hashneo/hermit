package thread

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// ResolvedStore persists the set of thread IDs that have been marked resolved
// by Hermit locally. This is necessary because neither Gitea nor the GitHub
// REST API exposes a "resolve review thread" endpoint that Hermit can use —
// Gitea has no native concept, and GitHub requires GraphQL. The resolved state
// is therefore owned by Hermit and stored in the app's data directory.
//
// File format: a JSON array of thread ID strings.
// Thread: "{repoID}:{prNumber}:{commentID}"
type ResolvedStore struct {
	mu   sync.RWMutex
	path string
	ids  map[string]struct{}
}

func NewResolvedStore(dataDir string) *ResolvedStore {
	s := &ResolvedStore{
		path: filepath.Join(dataDir, "resolved-threads.json"),
		ids:  make(map[string]struct{}),
	}
	_ = s.load() // best-effort; missing file is fine
	return s
}

func (s *ResolvedStore) IsResolved(threadID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.ids[threadID]
	return ok
}

func (s *ResolvedStore) MarkResolved(threadID string) error {
	s.mu.Lock()
	s.ids[threadID] = struct{}{}
	s.mu.Unlock()
	return s.save()
}

func (s *ResolvedStore) load() error {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var ids []string
	if err := json.Unmarshal(data, &ids); err != nil {
		return err
	}
	s.mu.Lock()
	for _, id := range ids {
		s.ids[id] = struct{}{}
	}
	s.mu.Unlock()
	return nil
}

func (s *ResolvedStore) save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	s.mu.RLock()
	ids := make([]string, 0, len(s.ids))
	for id := range s.ids {
		ids = append(ids, id)
	}
	s.mu.RUnlock()
	data, err := json.MarshalIndent(ids, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0o644)
}
