package workset

import (
	"context"
	"errors"
	"time"
)

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
