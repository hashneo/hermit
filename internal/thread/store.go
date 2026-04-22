package thread

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type ThreadStore interface {
	Load() ([]Thread, error)
	Save([]Thread) error
}

type FileStore struct {
	path string
}

func NewFileStore(path string) *FileStore {
	return &FileStore{path: path}
}

func (s *FileStore) Load() ([]Thread, error) {
	if s == nil || s.path == "" {
		return nil, nil
	}

	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read thread store: %w", err)
	}

	if len(data) == 0 {
		return nil, nil
	}

	var threads []Thread
	if err := json.Unmarshal(data, &threads); err != nil {
		return nil, fmt.Errorf("decode thread store: %w", err)
	}

	return threads, nil
}

func (s *FileStore) Save(threads []Thread) error {
	if s == nil || s.path == "" {
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("create thread store dir: %w", err)
	}

	data, err := json.MarshalIndent(threads, "", "  ")
	if err != nil {
		return fmt.Errorf("encode thread store: %w", err)
	}

	if err := os.WriteFile(s.path, data, 0o644); err != nil {
		return fmt.Errorf("write thread store: %w", err)
	}

	return nil
}
