package workset

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

func (s *Store) GetRenderedReviewDocument(ctx context.Context, repositoryID, commitSHA, filePath string) ([]byte, bool, error) {
	repositoryID, commitSHA, filePath, err := normalizeRenderedReviewDocumentKey(repositoryID, commitSHA, filePath)
	if err != nil {
		return nil, false, err
	}

	var payload string
	err = s.db.QueryRowContext(ctx, `
		SELECT payload_json
		FROM rendered_review_documents
		WHERE repository_id = ? AND commit_sha = ? AND file_path = ?
	`, repositoryID, commitSHA, filePath).Scan(&payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return []byte(payload), true, nil
}

func (s *Store) PutRenderedReviewDocument(ctx context.Context, repositoryID, commitSHA, filePath string, payload []byte) error {
	repositoryID, commitSHA, filePath, err := normalizeRenderedReviewDocumentKey(repositoryID, commitSHA, filePath)
	if err != nil {
		return err
	}
	if len(payload) == 0 {
		return errors.New("payload is required")
	}

	nowText := s.now().UTC().Format(time.RFC3339)
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO rendered_review_documents (
			repository_id, commit_sha, file_path, payload_json, rendered_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(repository_id, commit_sha, file_path) DO UPDATE SET
			payload_json = excluded.payload_json,
			updated_at = excluded.updated_at
	`, repositoryID, commitSHA, filePath, string(payload), nowText, nowText)
	return err
}

func normalizeRenderedReviewDocumentKey(repositoryID, commitSHA, filePath string) (string, string, string, error) {
	repositoryID = strings.TrimSpace(repositoryID)
	commitSHA = strings.ToLower(strings.TrimSpace(commitSHA))
	filePath = strings.Trim(strings.TrimSpace(filePath), "/")
	if repositoryID == "" {
		return "", "", "", errors.New("repository id is required")
	}
	if commitSHA == "" {
		return "", "", "", errors.New("commit sha is required")
	}
	if filePath == "" {
		return "", "", "", errors.New("file path is required")
	}
	return repositoryID, commitSHA, filePath, nil
}
