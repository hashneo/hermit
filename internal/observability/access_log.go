package observability

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

const accessLogDatabaseFilename = "hermit-observability.db"

// AccessLogStore records HTTP access log entries into SQLite.
//
// SQLite allows only one writer at a time.  All writes are dispatched through
// a buffered channel and consumed by a single background goroutine, keeping
// middleware hot-path non-blocking and eliminating SQLITE_BUSY contention.
type AccessLogStore struct {
	db       *sql.DB
	writeCh  chan LogEntry
	flushCh  chan chan struct{} // used by Sync() to drain pending writes
	stopCh   chan struct{}
	loopDone chan struct{} // closed by writeLoop when it exits
	stopped  sync.Once    // guards Close() against double-close panics
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
	// Single connection for the write goroutine — eliminates lock contention.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if err := configureAccessLogSQLite(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	store := &AccessLogStore{
		db:       db,
		writeCh:  make(chan LogEntry, 2048),
		flushCh:  make(chan chan struct{}, 8),
		stopCh:   make(chan struct{}),
		loopDone: make(chan struct{}),
	}
	if err := store.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	go store.writeLoop()
	return store, nil
}

// Sync blocks until all writes queued before the call have been committed.
// Intended for tests that need deterministic read-after-write behaviour.
func (s *AccessLogStore) Sync() {
	done := make(chan struct{})
	s.flushCh <- done
	<-done
}

func (s *AccessLogStore) writeLoop() {
	defer close(s.loopDone)
	for {
		select {
		case entry := <-s.writeCh:
			_ = s.insertDirect(context.Background(), entry)
		case done := <-s.flushCh:
			// Drain all pending writes then signal the caller.
			for len(s.writeCh) > 0 {
				_ = s.insertDirect(context.Background(), <-s.writeCh)
			}
			close(done)
		case <-s.stopCh:
			for len(s.writeCh) > 0 {
				_ = s.insertDirect(context.Background(), <-s.writeCh)
			}
			return
		}
	}
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
	// stopped.Do ensures Close() is idempotent — closing stopCh twice panics.
	// We also wait for writeLoop to drain and exit before closing the DB so
	// no in-flight insert races against db.Close().
	var dbErr error
	s.stopped.Do(func() {
		done := make(chan struct{})
		// Signal writeLoop to stop and tell it to notify us when it exits.
		s.flushCh <- done // drain first
		<-done
		close(s.stopCh)   // then stop
		<-s.loopDone      // wait for writeLoop to fully exit before closing DB
		dbErr = s.db.Close()
	})
	return dbErr
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

// Insert enqueues an entry for async write.  It never blocks the caller —
// if the channel is full the entry is silently dropped rather than stalling
// the HTTP response path.
func (s *AccessLogStore) Insert(_ context.Context, entry LogEntry) error {
	if s == nil || s.db == nil {
		return nil
	}
	// Become a no-op once the store is closed so callers that race with
	// Close() don't enqueue entries that will never be written.
	select {
	case <-s.stopCh:
		return nil
	default:
	}
	if entry.Kind == "" {
		entry.Kind = "access"
	}
	select {
	case s.writeCh <- entry:
	default:
		// Channel full — drop rather than block.
	}
	return nil
}

func (s *AccessLogStore) insertDirect(ctx context.Context, entry LogEntry) error {
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
			&entry.ID, &entry.StartedAt, &entry.CompletedAt, &entry.Kind,
			&entry.Method, &entry.Path, &entry.Query, &entry.Status,
			&entry.DurationMS, &entry.CorrelationID, &entry.RemoteAddr,
			&entry.UserAgent, &entry.BytesWritten, &entry.ErrorCode, &entry.ErrorMessage,
		); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

