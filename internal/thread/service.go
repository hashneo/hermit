package thread

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

const githubThreadWaitTimeout = 2 * time.Second

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
	FilePath        string `json:"file_path,omitempty"`
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
			FilePath:        req.Anchor.FilePath,
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

	s.mu.Lock()
	s.threads[thread.ID] = thread
	s.mu.Unlock()

	go s.syncCreateThread(thread.ID)

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

	go s.syncReply(req.ThreadID, msg.ID)

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

	go s.syncResolve(req.ThreadID)

	return thread, nil
}

func (s *Service) syncCreateThread(threadID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s.mu.RLock()
	thread, ok := s.threads[threadID]
	s.mu.RUnlock()
	if !ok {
		return
	}

	ghThreadID, ghCommentID, err := s.client.CreateThread(ctx, thread)
	if err != nil {
		s.markSyncFailed(threadID, "github_create_failed")
		return
	}

	now := s.now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()

	thread, ok = s.threads[threadID]
	if !ok {
		return
	}

	thread.GitHubThreadID = ghThreadID
	if len(thread.Messages) > 0 {
		thread.Messages[0].GitHubCommentID = ghCommentID
	}
	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &now}
	thread.UpdatedAt = now
	s.threads[threadID] = thread
}

func (s *Service) syncReply(threadID, messageID string) {
	githubThreadID, ok := s.waitForGitHubThreadID(threadID, githubThreadWaitTimeout)
	if !ok {
		s.markSyncFailed(threadID, "github_thread_unavailable")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	msg, ok := s.messageByID(threadID, messageID)
	if !ok {
		return
	}

	commentID, err := s.client.ReplyThread(ctx, githubThreadID, msg)
	if err != nil {
		s.markSyncFailed(threadID, "github_reply_failed")
		return
	}

	now := s.now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()

	thread, ok := s.threads[threadID]
	if !ok {
		return
	}

	for i := range thread.Messages {
		if thread.Messages[i].ID == messageID {
			thread.Messages[i].GitHubCommentID = commentID
			break
		}
	}
	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &now}
	thread.UpdatedAt = now
	s.threads[threadID] = thread
}

func (s *Service) syncResolve(threadID string) {
	githubThreadID, ok := s.waitForGitHubThreadID(threadID, githubThreadWaitTimeout)
	if !ok {
		s.markSyncFailed(threadID, "github_thread_unavailable")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := s.client.ResolveThread(ctx, githubThreadID); err != nil {
		s.markSyncFailed(threadID, "github_resolve_failed")
		return
	}

	now := s.now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()

	thread, ok := s.threads[threadID]
	if !ok {
		return
	}

	thread.Sync = Sync{State: SyncStateSynced, LastSynced: &now}
	thread.UpdatedAt = now
	s.threads[threadID] = thread
}

func (s *Service) markSyncFailed(threadID, code string) {
	now := s.now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()

	thread, ok := s.threads[threadID]
	if !ok {
		return
	}

	retryCount := thread.Sync.RetryCount + 1
	thread.Sync = Sync{State: SyncStateFailed, LastError: code, RetryCount: retryCount}
	thread.UpdatedAt = now
	s.threads[threadID] = thread
}

func (s *Service) waitForGitHubThreadID(threadID string, timeout time.Duration) (string, bool) {
	deadline := time.Now().Add(timeout)
	for {
		s.mu.RLock()
		thread, ok := s.threads[threadID]
		s.mu.RUnlock()
		if !ok {
			return "", false
		}
		if thread.GitHubThreadID != "" {
			return thread.GitHubThreadID, true
		}
		if time.Now().After(deadline) {
			return "", false
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func (s *Service) messageByID(threadID, messageID string) (Message, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	thread, ok := s.threads[threadID]
	if !ok {
		return Message{}, false
	}
	for _, msg := range thread.Messages {
		if msg.ID == messageID {
			return msg, true
		}
	}

	return Message{}, false
}

func (s *Service) newID(prefix string) string {
	return fmt.Sprintf("%s_%d", prefix, s.idSeq.Add(1))
}
