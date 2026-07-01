package observability

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const accessLogDatabaseFilename = "hermit-observability.db"

type AccessLogStore struct {
	db *sql.DB
}

type LogEntry struct {
	ID            int64  `json:"id"`
	StartedAt     string `json:"started_at"`
	CompletedAt   string `json:"completed_at"`
	Kind          string `json:"kind"`
	Method        string `json:"method"`
	Path          string `json:"path"`
	Query         string `json:"query,omitempty"`
	Status        int    `json:"status"`
	DurationMS    int64  `json:"duration_ms"`
	CorrelationID string `json:"correlation_id"`
	RemoteAddr    string `json:"remote_addr,omitempty"`
	UserAgent     string `json:"user_agent,omitempty"`
	BytesWritten  int    `json:"bytes_written"`
	ErrorCode     string `json:"error_code,omitempty"`
	ErrorMessage  string `json:"error_message,omitempty"`
}

type LogQuery struct {
	Kind  string
	Limit int
}

func OpenAccessLog(dataDir string) (*AccessLogStore, error) {
	if dataDir == "" {
		return nil, errors.New("data dir is required")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", filepath.Join(dataDir, accessLogDatabaseFilename))
	if err != nil {
		return nil, err
	}
	configureAccessLogDBPool(db)
	if err := configureAccessLogSQLite(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	store := &AccessLogStore{db: db}
	if err := store.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func configureAccessLogDBPool(db *sql.DB) {
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
}

func configureAccessLogSQLite(db *sql.DB) error {
	stmts := []string{
		`PRAGMA foreign_keys = ON`,
		`PRAGMA busy_timeout = 5000`,
		`PRAGMA journal_mode = WAL`,
		`PRAGMA synchronous = NORMAL`,
		`PRAGMA temp_store = MEMORY`,
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

func (s *AccessLogStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *AccessLogStore) migrate(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS http_access_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			started_at TEXT NOT NULL,
			completed_at TEXT NOT NULL,
			kind TEXT NOT NULL,
			method TEXT NOT NULL,
			path TEXT NOT NULL,
			query TEXT NOT NULL DEFAULT '',
			status INTEGER NOT NULL,
			duration_ms INTEGER NOT NULL,
			correlation_id TEXT NOT NULL,
			remote_addr TEXT NOT NULL DEFAULT '',
			user_agent TEXT NOT NULL DEFAULT '',
			bytes_written INTEGER NOT NULL DEFAULT 0,
			error_code TEXT NOT NULL DEFAULT '',
			error_message TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_http_access_log_started_at ON http_access_log(started_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_http_access_log_status ON http_access_log(status, started_at DESC)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate access log sqlite: %w", err)
		}
	}
	return nil
}

func (s *AccessLogStore) Insert(ctx context.Context, entry LogEntry) error {
	if s == nil || s.db == nil {
		return nil
	}
	if entry.Kind == "" {
		entry.Kind = "access"
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO http_access_log (
		started_at, completed_at, kind, method, path, query, status, duration_ms,
		correlation_id, remote_addr, user_agent, bytes_written, error_code, error_message
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		entry.StartedAt, entry.CompletedAt, entry.Kind, entry.Method, entry.Path, entry.Query,
		entry.Status, entry.DurationMS, entry.CorrelationID, entry.RemoteAddr, entry.UserAgent,
		entry.BytesWritten, entry.ErrorCode, entry.ErrorMessage,
	)
	return err
}

func (s *AccessLogStore) List(ctx context.Context, query LogQuery) ([]LogEntry, error) {
	if s == nil || s.db == nil {
		return nil, errors.New("access log store is not configured")
	}
	limit := query.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}

	where := ""
	args := []any{}
	switch strings.ToLower(strings.TrimSpace(query.Kind)) {
	case "error":
		where = "WHERE status >= ?"
		args = append(args, 400)
	case "", "all", "access":
	default:
		return nil, fmt.Errorf("unsupported log kind %q", query.Kind)
	}
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, `SELECT
		id, started_at, completed_at, kind, method, path, query, status, duration_ms,
		correlation_id, remote_addr, user_agent, bytes_written, error_code, error_message
		FROM http_access_log `+where+` ORDER BY id DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	entries := []LogEntry{}
	for rows.Next() {
		var entry LogEntry
		if err := rows.Scan(
			&entry.ID,
			&entry.StartedAt,
			&entry.CompletedAt,
			&entry.Kind,
			&entry.Method,
			&entry.Path,
			&entry.Query,
			&entry.Status,
			&entry.DurationMS,
			&entry.CorrelationID,
			&entry.RemoteAddr,
			&entry.UserAgent,
			&entry.BytesWritten,
			&entry.ErrorCode,
			&entry.ErrorMessage,
		); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}
