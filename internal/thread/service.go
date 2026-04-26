package thread

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	ThreadStatusOpen     = "open"
	ThreadStatusResolved = "resolved"

	SyncStateSynced  = "synced"
	SyncStateFailed  = "failed"
	SyncStatePending = "pending"
)

type Anchor struct {
	AnchorID           string `json:"anchor_id"`
	LineStart          int    `json:"line_start"`
	LineEnd            int    `json:"line_end"`
	FormattedLineStart int    `json:"formatted_line_start,omitempty"`
	FormattedLineEnd   int    `json:"formatted_line_end,omitempty"`
	TextFingerprint    string `json:"text_fingerprint"`
	FilePath           string `json:"file_path,omitempty"`
}

type Message struct {
	ID              string    `json:"id"`
	Author          string    `json:"author"`
	Body            string    `json:"body"`
	SourceSystem    string    `json:"source_system"`
	GitHubCommentID string    `json:"github_comment_id,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
}

type Sync struct {
	State      string     `json:"state"`
	LastSynced *time.Time `json:"last_synced_at"`
	LastError  string     `json:"last_error_code,omitempty"`
	RetryCount int        `json:"retry_count"`
}

type Thread struct {
	ID             string    `json:"id"`
	RepositoryID   string    `json:"repository_id"`
	PRNumber       int       `json:"pr_number"`
	Status         string    `json:"status"`
	Anchor         Anchor    `json:"anchor"`
	Messages       []Message `json:"messages"`
	GitHubThreadID string    `json:"github_thread_id,omitempty"`
	Sync           Sync      `json:"sync"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type CreateRequest struct {
	RepositoryID string
	PRNumber     int
	Anchor       Anchor
	Body         string
	Author       string
}

type ReplyRequest struct {
	RepositoryID string
	PRNumber     int
	ThreadID     string
	Body         string
	Author       string
}

type ResolveRequest struct {
	RepositoryID string
	PRNumber     int
	ThreadID     string
}

type GitHubClient interface {
	ListThreads(ctx context.Context, repositoryID string, prNumber int) ([]Thread, error)
	CreateThread(ctx context.Context, thread Thread) (threadID string, messageID string, err error)
	ReplyThread(ctx context.Context, githubThreadID string, message Message) (commentID string, err error)
	ResolveThread(ctx context.Context, githubThreadID string) error
}

// Service is a stateless pass-through to the GitHub client.
// GitHub is the sole source of truth — no in-memory cache, no file store.
type Service struct {
	client GitHubClient
	now    func() time.Time
}

func NewService(client GitHubClient) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}
	return &Service{client: client, now: time.Now}
}

// NewServiceWithStore exists only for test compatibility — store is ignored.
func NewServiceWithStore(client GitHubClient, store ThreadStore) *Service {
	return NewService(client)
}

func (s *Service) List(repositoryID string, prNumber int) []Thread {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	threads, err := s.client.ListThreads(ctx, repositoryID, prNumber)
	if err != nil {
		return nil
	}
	return threads
}

func (s *Service) Create(ctx context.Context, req CreateRequest) (Thread, error) {
	now := s.now().UTC()

	author := req.Author
	if author == "" {
		author = "hermit-bot"
	}

	thread := Thread{
		RepositoryID: req.RepositoryID,
		PRNumber:     req.PRNumber,
		Status:       ThreadStatusOpen,
		Anchor:       req.Anchor,
		Messages: []Message{{
			Author:       author,
			Body:         req.Body,
			SourceSystem: "hermit",
			CreatedAt:    now,
		}},
		CreatedAt: now,
		UpdatedAt: now,
	}

	ghThreadID, ghCommentID, err := s.client.CreateThread(ctx, thread)
	if err != nil {
		return Thread{}, fmt.Errorf("create github comment: %w", err)
	}

	thread.ID = ghThreadID
	thread.GitHubThreadID = ghThreadID
	thread.Messages[0].ID = ghCommentID
	thread.Messages[0].GitHubCommentID = ghCommentID
	synced := now
	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &synced}

	return thread, nil
}

func (s *Service) Reply(ctx context.Context, req ReplyRequest) (Thread, error) {
	now := s.now().UTC()

	author := req.Author
	if author == "" {
		author = "hermit-bot"
	}

	msg := Message{
		Author:       author,
		Body:         req.Body,
		SourceSystem: "hermit",
		CreatedAt:    now,
	}

	commentID, err := s.client.ReplyThread(ctx, req.ThreadID, msg)
	if err != nil {
		return Thread{}, fmt.Errorf("reply github comment: %w", err)
	}

	msg.ID = commentID
	msg.GitHubCommentID = commentID

	// Return the full updated thread by re-fetching from GitHub.
	threads, err := s.client.ListThreads(ctx, req.RepositoryID, req.PRNumber)
	if err != nil {
		// Can't re-fetch — return a minimal thread with the new message.
		return Thread{
			ID:           req.ThreadID,
			RepositoryID: req.RepositoryID,
			PRNumber:     req.PRNumber,
			Status:       ThreadStatusOpen,
			Messages:     []Message{msg},
			Sync:         Sync{State: SyncStateSynced},
		}, nil
	}
	now2 := s.now().UTC()
	for _, t := range threads {
		if t.GitHubThreadID == req.ThreadID {
			t.Sync = Sync{State: SyncStateSynced, LastSynced: &now2}
			return t, nil
		}
	}
	return Thread{}, fmt.Errorf("thread not found after reply")
}

func (s *Service) Resolve(ctx context.Context, req ResolveRequest) (Thread, error) {
	if err := s.client.ResolveThread(ctx, req.ThreadID); err != nil {
		return Thread{}, fmt.Errorf("resolve github thread: %w", err)
	}

	threads, err := s.client.ListThreads(ctx, req.RepositoryID, req.PRNumber)
	if err == nil {
		now2 := s.now().UTC()
		for _, t := range threads {
			if t.GitHubThreadID == req.ThreadID {
				t.Status = ThreadStatusResolved
				t.Sync = Sync{State: SyncStateSynced, LastSynced: &now2}
				return t, nil
			}
		}
	}
	return Thread{
		ID:           req.ThreadID,
		RepositoryID: req.RepositoryID,
		PRNumber:     req.PRNumber,
		Status:       ThreadStatusResolved,
		Sync:         Sync{State: SyncStateSynced},
	}, nil
}

func extractSequence(id string) int64 {
	id = strings.TrimSpace(id)
	if id == "" {
		return 0
	}
	parts := strings.Split(id, "_")
	if len(parts) < 2 {
		return 0
	}
	value, err := strconv.ParseInt(parts[len(parts)-1], 10, 64)
	if err != nil || value <= 0 {
		return 0
	}
	return value
}
