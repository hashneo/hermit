package thread

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
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
	AnchorID        string `json:"anchor_id"`
	LineStart       int    `json:"line_start"`
	LineEnd         int    `json:"line_end"`
	TextFingerprint string `json:"text_fingerprint"`
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
	CreateThread(ctx context.Context, thread Thread) (threadID string, messageID string, err error)
	ReplyThread(ctx context.Context, githubThreadID string, message Message) (commentID string, err error)
	ResolveThread(ctx context.Context, githubThreadID string) error
}

type Service struct {
	mu      sync.RWMutex
	threads map[string]Thread
	client  GitHubClient
	now     func() time.Time
	idSeq   atomic.Int64
}

func NewService(client GitHubClient) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}

	s := &Service{
		threads: make(map[string]Thread),
		client:  client,
		now:     time.Now,
	}
	s.idSeq.Store(1000)
	return s
}

func (s *Service) List(repositoryID string, prNumber int) []Thread {
	s.mu.RLock()
	defer s.mu.RUnlock()

	threads := make([]Thread, 0)
	for _, t := range s.threads {
		if t.RepositoryID == repositoryID && t.PRNumber == prNumber {
			threads = append(threads, t)
		}
	}

	return threads
}

func (s *Service) Create(ctx context.Context, req CreateRequest) (Thread, error) {
	now := s.now().UTC()
	threadID := s.newID("thr")
	messageID := s.newID("msg")

	author := req.Author
	if author == "" {
		author = "hermit-bot"
	}

	thread := Thread{
		ID:           threadID,
		RepositoryID: req.RepositoryID,
		PRNumber:     req.PRNumber,
		Status:       ThreadStatusOpen,
		Anchor: Anchor{
			AnchorID:        s.newID("anc"),
			LineStart:       req.Anchor.LineStart,
			LineEnd:         req.Anchor.LineEnd,
			TextFingerprint: req.Anchor.TextFingerprint,
		},
		Messages: []Message{{
			ID:           messageID,
			Author:       author,
			Body:         req.Body,
			SourceSystem: "hermit",
			CreatedAt:    now,
		}},
		Sync:      Sync{State: SyncStatePending},
		CreatedAt: now,
		UpdatedAt: now,
	}

	ghThreadID, ghCommentID, err := s.client.CreateThread(ctx, thread)
	if err != nil {
		thread.Sync = Sync{State: SyncStateFailed, LastError: "github_create_failed", RetryCount: 1}
		s.mu.Lock()
		s.threads[thread.ID] = thread
		s.mu.Unlock()
		return thread, fmt.Errorf("create github thread: %w", err)
	}

	thread.GitHubThreadID = ghThreadID
	thread.Messages[0].GitHubCommentID = ghCommentID
	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &now}

	s.mu.Lock()
	s.threads[thread.ID] = thread
	s.mu.Unlock()

	return thread, nil
}

func (s *Service) Reply(ctx context.Context, req ReplyRequest) (Thread, error) {
	s.mu.Lock()
	thread, ok := s.threads[req.ThreadID]
	if !ok || thread.RepositoryID != req.RepositoryID || thread.PRNumber != req.PRNumber {
		s.mu.Unlock()
		return Thread{}, fmt.Errorf("thread not found")
	}

	now := s.now().UTC()
	author := req.Author
	if author == "" {
		author = "hermit-bot"
	}
	msg := Message{
		ID:           s.newID("msg"),
		Author:       author,
		Body:         req.Body,
		SourceSystem: "hermit",
		CreatedAt:    now,
	}
	thread.Messages = append(thread.Messages, msg)
	thread.UpdatedAt = now
	thread.Sync = Sync{State: SyncStatePending}
	s.threads[req.ThreadID] = thread
	s.mu.Unlock()

	commentID, err := s.client.ReplyThread(ctx, thread.GitHubThreadID, msg)
	if err != nil {
		s.mu.Lock()
		thread = s.threads[req.ThreadID]
		thread.Sync = Sync{State: SyncStateFailed, LastError: "github_reply_failed", RetryCount: thread.Sync.RetryCount + 1}
		s.threads[req.ThreadID] = thread
		s.mu.Unlock()
		return thread, fmt.Errorf("reply github thread: %w", err)
	}

	s.mu.Lock()
	thread = s.threads[req.ThreadID]
	thread.Messages[len(thread.Messages)-1].GitHubCommentID = commentID
	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &now}
	s.threads[req.ThreadID] = thread
	s.mu.Unlock()

	return thread, nil
}

func (s *Service) Resolve(ctx context.Context, req ResolveRequest) (Thread, error) {
	s.mu.Lock()
	thread, ok := s.threads[req.ThreadID]
	if !ok || thread.RepositoryID != req.RepositoryID || thread.PRNumber != req.PRNumber {
		s.mu.Unlock()
		return Thread{}, fmt.Errorf("thread not found")
	}

	now := s.now().UTC()
	thread.Status = ThreadStatusResolved
	thread.UpdatedAt = now
	thread.Sync = Sync{State: SyncStatePending}
	s.threads[req.ThreadID] = thread
	s.mu.Unlock()

	if err := s.client.ResolveThread(ctx, thread.GitHubThreadID); err != nil {
		s.mu.Lock()
		thread = s.threads[req.ThreadID]
		thread.Sync = Sync{State: SyncStateFailed, LastError: "github_resolve_failed", RetryCount: thread.Sync.RetryCount + 1}
		s.threads[req.ThreadID] = thread
		s.mu.Unlock()
		return thread, fmt.Errorf("resolve github thread: %w", err)
	}

	s.mu.Lock()
	thread = s.threads[req.ThreadID]
	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &now}
	s.threads[req.ThreadID] = thread
	s.mu.Unlock()

	return thread, nil
}

func (s *Service) newID(prefix string) string {
	return fmt.Sprintf("%s_%d", prefix, s.idSeq.Add(1))
}
