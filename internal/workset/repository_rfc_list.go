package workset

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type RepositoryRFCListProjection struct {
	Payload []byte
	Cache   CacheMetadata
}

func (s *Store) GetFreshRepositoryRFCList(ctx context.Context, repositoryID string, ttl time.Duration) (RepositoryRFCListProjection, bool, error) {
	record, ok, err := s.getRepositoryRFCList(ctx, repositoryID)
	if err != nil || !ok {
		return RepositoryRFCListProjection{}, false, err
	}
	if record.LastSuccessfulRefreshAt.IsZero() {
		return RepositoryRFCListProjection{Cache: metadataFromRecord(record, false, time.Time{})}, false, nil
	}
	next := record.LastSuccessfulRefreshAt.Add(ttl)
	if s.now().Before(next) {
		return RepositoryRFCListProjection{Payload: record.Payload, Cache: metadataFromRecord(record, true, next)}, true, nil
	}
	return RepositoryRFCListProjection{Cache: metadataFromRecord(record, false, next)}, false, nil
}

func (s *Store) GetAnyRepositoryRFCList(ctx context.Context, repositoryID string, ttl time.Duration) (RepositoryRFCListProjection, bool, error) {
	record, ok, err := s.getRepositoryRFCList(ctx, repositoryID)
	if err != nil || !ok {
		return RepositoryRFCListProjection{}, false, err
	}
	if record.LastSuccessfulRefreshAt.IsZero() {
		return RepositoryRFCListProjection{Cache: metadataFromRecord(record, false, time.Time{})}, false, nil
	}
	return RepositoryRFCListProjection{
		Payload: record.Payload,
		Cache:   metadataFromRecord(record, true, record.LastSuccessfulRefreshAt.Add(ttl)),
	}, true, nil
}

func (s *Store) PutRepositoryRFCListSuccess(ctx context.Context, repositoryID string, payload []byte) (CacheMetadata, error) {
	if repositoryID == "" {
		return CacheMetadata{}, errors.New("repository id is required")
	}
	if len(payload) == 0 {
		payload = []byte("{}")
	}
	now := s.now().UTC()
	nowText := now.Format(time.RFC3339)
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO repository_rfc_lists (
			repository_id, payload_json, last_successful_refresh_at, last_attempted_refresh_at,
			last_error_code, last_error_message, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, '', '', ?, ?)
		ON CONFLICT(repository_id) DO UPDATE SET
			payload_json = excluded.payload_json,
			last_successful_refresh_at = excluded.last_successful_refresh_at,
			last_attempted_refresh_at = excluded.last_attempted_refresh_at,
			last_error_code = '',
			last_error_message = '',
			updated_at = excluded.updated_at
	`, repositoryID, string(payload), nowText, nowText, nowText, nowText)
	if err != nil {
		return CacheMetadata{}, err
	}
	return CacheMetadata{
		Cached:                  false,
		LastSuccessfulRefreshAt: nowText,
		LastAttemptedRefreshAt:  nowText,
	}, nil
}

func (s *Store) PutRepositoryRFCListError(ctx context.Context, repositoryID, code, message string) error {
	if repositoryID == "" {
		return errors.New("repository id is required")
	}
	nowText := s.now().UTC().Format(time.RFC3339)
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO repository_rfc_lists (
			repository_id, payload_json, last_attempted_refresh_at,
			last_error_code, last_error_message, created_at, updated_at
		)
		VALUES (?, '{}', ?, ?, ?, ?, ?)
		ON CONFLICT(repository_id) DO UPDATE SET
			last_attempted_refresh_at = excluded.last_attempted_refresh_at,
			last_error_code = excluded.last_error_code,
			last_error_message = excluded.last_error_message,
			updated_at = excluded.updated_at
	`, repositoryID, nowText, code, message, nowText, nowText)
	return err
}

func (s *Store) InvalidateRepositoryRFCList(ctx context.Context, repositoryID string) error {
	if repositoryID == "" {
		return errors.New("repository id is required")
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM repository_rfc_lists WHERE repository_id = ?`, repositoryID)
	return err
}

func (s *Store) getRepositoryRFCList(ctx context.Context, repositoryID string) (cacheRecord, bool, error) {
	var payload, successText, attemptedText, errorCode, errorMessage string
	err := s.db.QueryRowContext(ctx, `
		SELECT payload_json, COALESCE(last_successful_refresh_at, ''), COALESCE(last_attempted_refresh_at, ''),
		       COALESCE(last_error_code, ''), COALESCE(last_error_message, '')
		FROM repository_rfc_lists
		WHERE repository_id = ?
	`, repositoryID).Scan(&payload, &successText, &attemptedText, &errorCode, &errorMessage)
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
