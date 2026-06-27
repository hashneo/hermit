package workset

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const databaseFilename = "hermit.db"

type Store struct {
	db  *sql.DB
	now func() time.Time
}

type CacheMetadata struct {
	Cached                  bool   `json:"cached"`
	LastSuccessfulRefreshAt string `json:"last_successful_refresh_at,omitempty"`
	LastAttemptedRefreshAt  string `json:"last_attempted_refresh_at,omitempty"`
	NextAutomaticRefreshAt  string `json:"next_automatic_refresh_at,omitempty"`
	LastErrorCode           string `json:"last_error_code,omitempty"`
	LastErrorMessage        string `json:"last_error_message,omitempty"`
}

type cacheRecord struct {
	Payload                 []byte
	LastSuccessfulRefreshAt time.Time
	LastAttemptedRefreshAt  time.Time
	LastErrorCode           string
	LastErrorMessage        string
}

func Open(dataDir string) (*Store, error) {
	if dataDir == "" {
		return nil, errors.New("data dir is required")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", filepath.Join(dataDir, databaseFilename))
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, now: time.Now}
	if err := s.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) GetFreshCache(ctx context.Context, key string, ttl time.Duration) ([]byte, CacheMetadata, bool, error) {
	record, ok, err := s.getCache(ctx, key)
	if err != nil || !ok {
		return nil, CacheMetadata{}, false, err
	}
	if record.LastSuccessfulRefreshAt.IsZero() {
		return nil, metadataFromRecord(record, false, time.Time{}), false, nil
	}
	next := record.LastSuccessfulRefreshAt.Add(ttl)
	if s.now().Before(next) {
		return record.Payload, metadataFromRecord(record, true, next), true, nil
	}
	return nil, metadataFromRecord(record, false, next), false, nil
}

func (s *Store) GetAnyCache(ctx context.Context, key string, ttl time.Duration) ([]byte, CacheMetadata, bool, error) {
	record, ok, err := s.getCache(ctx, key)
	if err != nil || !ok {
		return nil, CacheMetadata{}, false, err
	}
	if record.LastSuccessfulRefreshAt.IsZero() {
		return nil, metadataFromRecord(record, false, time.Time{}), false, nil
	}
	return record.Payload, metadataFromRecord(record, true, record.LastSuccessfulRefreshAt.Add(ttl)), true, nil
}

func (s *Store) PutCacheSuccess(ctx context.Context, scope, key string, value any) (CacheMetadata, error) {
	payload, err := json.Marshal(value)
	if err != nil {
		return CacheMetadata{}, err
	}
	now := s.now().UTC()
	nowText := now.Format(time.RFC3339)
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO cache_entries (
			key, scope, payload_json, last_successful_refresh_at, last_attempted_refresh_at,
			last_error_code, last_error_message, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, '', '', ?, ?)
		ON CONFLICT(key) DO UPDATE SET
			scope = excluded.scope,
			payload_json = excluded.payload_json,
			last_successful_refresh_at = excluded.last_successful_refresh_at,
			last_attempted_refresh_at = excluded.last_attempted_refresh_at,
			last_error_code = '',
			last_error_message = '',
			updated_at = excluded.updated_at
	`, key, scope, string(payload), nowText, nowText, nowText, nowText)
	if err != nil {
		return CacheMetadata{}, err
	}
	return CacheMetadata{
		Cached:                  false,
		LastSuccessfulRefreshAt: nowText,
		LastAttemptedRefreshAt:  nowText,
	}, nil
}

func (s *Store) PutCacheError(ctx context.Context, scope, key, code, message string) error {
	nowText := s.now().UTC().Format(time.RFC3339)
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO cache_entries (
			key, scope, payload_json, last_attempted_refresh_at,
			last_error_code, last_error_message, created_at, updated_at
		)
		VALUES (?, ?, '{}', ?, ?, ?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET
			scope = excluded.scope,
			last_attempted_refresh_at = excluded.last_attempted_refresh_at,
			last_error_code = excluded.last_error_code,
			last_error_message = excluded.last_error_message,
			updated_at = excluded.updated_at
	`, key, scope, nowText, code, message, nowText, nowText)
	return err
}

func (s *Store) EnqueueOperation(ctx context.Context, op Operation) error {
	nowText := s.now().UTC().Format(time.RFC3339)
	if op.ID == "" {
		return errors.New("operation id is required")
	}
	if op.Status == "" {
		op.Status = "queued"
	}
	if op.NotBeforeAt == "" {
		op.NotBeforeAt = nowText
	}
	if op.PayloadJSON == "" {
		op.PayloadJSON = "{}"
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO provider_operations (
			id, kind, status, priority, dedupe_key, payload_json, attempts,
			not_before_at, last_error_code, last_error_message, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, op.ID, op.Kind, op.Status, op.Priority, op.DedupeKey, op.PayloadJSON, op.Attempts,
		op.NotBeforeAt, op.LastErrorCode, op.LastErrorMessage, nowText, nowText)
	return err
}

type Operation struct {
	ID               string
	Kind             string
	Status           string
	Priority         int
	DedupeKey        string
	PayloadJSON      string
	Attempts         int
	NotBeforeAt      string
	LastErrorCode    string
	LastErrorMessage string
}

func (s *Store) getCache(ctx context.Context, key string) (cacheRecord, bool, error) {
	var payload, successText, attemptedText, errorCode, errorMessage string
	err := s.db.QueryRowContext(ctx, `
		SELECT payload_json, COALESCE(last_successful_refresh_at, ''), COALESCE(last_attempted_refresh_at, ''),
		       COALESCE(last_error_code, ''), COALESCE(last_error_message, '')
		FROM cache_entries
		WHERE key = ?
	`, key).Scan(&payload, &successText, &attemptedText, &errorCode, &errorMessage)
	if errors.Is(err, sql.ErrNoRows) {
		return cacheRecord{}, false, nil
	}
	if err != nil {
		return cacheRecord{}, false, err
	}
	successAt, _ := time.Parse(time.RFC3339, successText)
	attemptedAt, _ := time.Parse(time.RFC3339, attemptedText)
	return cacheRecord{
		Payload:                 []byte(payload),
		LastSuccessfulRefreshAt: successAt,
		LastAttemptedRefreshAt:  attemptedAt,
		LastErrorCode:           errorCode,
		LastErrorMessage:        errorMessage,
	}, true, nil
}

func (s *Store) migrate(ctx context.Context) error {
	stmts := []string{
		`PRAGMA journal_mode = WAL`,
		`CREATE TABLE IF NOT EXISTS cache_entries (
			key TEXT PRIMARY KEY,
			scope TEXT NOT NULL,
			payload_json TEXT NOT NULL,
			last_successful_refresh_at TEXT,
			last_attempted_refresh_at TEXT,
			last_error_code TEXT NOT NULL DEFAULT '',
			last_error_message TEXT NOT NULL DEFAULT '',
			etag TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_cache_entries_scope ON cache_entries(scope)`,
		`CREATE TABLE IF NOT EXISTS provider_operations (
			id TEXT PRIMARY KEY,
			kind TEXT NOT NULL,
			status TEXT NOT NULL,
			priority INTEGER NOT NULL DEFAULT 0,
			dedupe_key TEXT NOT NULL DEFAULT '',
			payload_json TEXT NOT NULL DEFAULT '{}',
			attempts INTEGER NOT NULL DEFAULT 0,
			not_before_at TEXT NOT NULL,
			last_error_code TEXT NOT NULL DEFAULT '',
			last_error_message TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_operations_ready ON provider_operations(status, not_before_at, priority)`,
		`CREATE INDEX IF NOT EXISTS idx_provider_operations_dedupe ON provider_operations(dedupe_key)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate workset sqlite: %w", err)
		}
	}
	return nil
}

func metadataFromRecord(record cacheRecord, cached bool, next time.Time) CacheMetadata {
	meta := CacheMetadata{Cached: cached}
	if !record.LastSuccessfulRefreshAt.IsZero() {
		meta.LastSuccessfulRefreshAt = record.LastSuccessfulRefreshAt.UTC().Format(time.RFC3339)
		meta.NextAutomaticRefreshAt = next.UTC().Format(time.RFC3339)
	}
	if !record.LastAttemptedRefreshAt.IsZero() {
		meta.LastAttemptedRefreshAt = record.LastAttemptedRefreshAt.UTC().Format(time.RFC3339)
	}
	meta.LastErrorCode = record.LastErrorCode
	meta.LastErrorMessage = record.LastErrorMessage
	return meta
}
