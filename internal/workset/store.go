package workset

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const databaseFilename = "hermit.db"

const (
	defaultBusyTimeoutMS = 5000
	defaultMaxOpenConns  = 4
	defaultMaxIdleConns  = 2
)

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
	configureDBPool(db)
	if err := configureSQLite(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	s := &Store{db: db, now: time.Now}
	if err := s.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func configureDBPool(db *sql.DB) {
	db.SetMaxOpenConns(defaultMaxOpenConns)
	db.SetMaxIdleConns(defaultMaxIdleConns)
}

func configureSQLite(db *sql.DB) error {
	stmts := []string{
		`PRAGMA foreign_keys = ON`,
		fmt.Sprintf(`PRAGMA busy_timeout = %d`, defaultBusyTimeoutMS),
		`PRAGMA journal_mode = WAL`,
		`PRAGMA synchronous = NORMAL`,
		`PRAGMA cache_size = -64000`,
		`PRAGMA temp_store = MEMORY`,
		`PRAGMA wal_autocheckpoint = 1000`,
	}
	for _, stmt := range stmts {
		if _, err := db.Exec(stmt); err != nil {
			return fmt.Errorf("configure sqlite %q: %w", stmt, err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		return fmt.Errorf("ping sqlite: %w", err)
	}
	return nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) migrate(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS repository_rfc_lists (
			repository_id TEXT PRIMARY KEY,
			payload_json TEXT NOT NULL,
			last_successful_refresh_at TEXT,
			last_attempted_refresh_at TEXT,
			last_error_code TEXT NOT NULL DEFAULT '',
			last_error_message TEXT NOT NULL DEFAULT '',
			etag TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_repository_rfc_lists_last_success ON repository_rfc_lists(last_successful_refresh_at)`,
		`CREATE TABLE IF NOT EXISTS rendered_review_documents (
			repository_id TEXT NOT NULL,
			commit_sha TEXT NOT NULL,
			file_path TEXT NOT NULL,
			payload_json TEXT NOT NULL,
			rendered_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			PRIMARY KEY(repository_id, commit_sha, file_path)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_rendered_review_documents_repository ON rendered_review_documents(repository_id, updated_at)`,
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
