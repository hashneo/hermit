package thread

import (
	"context"
	"fmt"
	"log/slog"
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
	Outdated       bool      `json:"outdated,omitempty"`
	Anchor         Anchor    `json:"anchor"`
	Messages       []Message `json:"messages"`
	GitHubThreadID string    `json:"github_thread_id,omitempty"`
	Sync           Sync      `json:"sync"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`

	// upstreamResolvedKnown is true when the resolved state was obtained
	// directly from the upstream platform (GitHub GraphQL fetchResolvedThreadIDs).
	// When true the ResolvedStore local overlay must NOT override it — GitHub
	// is authoritative.  When false (Gitea or failed GraphQL fetch) the local
	// overlay is applied to supply resolved state that the platform cannot
	// report itself.  This field is intentionally unexported and never
	// serialised to JSON.
	upstreamResolvedKnown bool
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

type DeleteRequest struct {
	RepositoryID string
	PRNumber     int
	ThreadID     string
	// MessageID is the specific message to delete (format "ghc-{commentID}").
	// If empty the entire thread root is deleted (legacy behaviour).
	MessageID string
	// Actor is the GitHub login of the requesting user. The service enforces
	// that the caller may only delete their own messages.
	Actor string
}

type GitHubClient interface {
	ListThreads(ctx context.Context, repositoryID string, prNumber int) ([]Thread, error)
	CreateThread(ctx context.Context, thread Thread) (threadID string, messageID string, err error)
	ReplyThread(ctx context.Context, githubThreadID string, anchor Anchor, message Message) (commentID string, err error)
	ResolveThread(ctx context.Context, githubThreadID string) error
	UnresolveThread(ctx context.Context, githubThreadID string) error
	DeleteComment(ctx context.Context, githubCommentID string) error
}

// Service is a stateless pass-through to the GitHub client.
// GitHub is the sole source of truth — no in-memory cache, no file store.
// resolved is an optional local overlay for thread IDs marked resolved by
// Hermit when the upstream platform (Gitea) has no native resolve concept.
type Service struct {
	client   GitHubClient
	resolved *ResolvedStore
	now      func() time.Time
}

func NewService(client GitHubClient) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}
	return &Service{client: client, now: time.Now}
}

func NewServiceWithDataDir(client GitHubClient, dataDir string) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}
	return &Service{client: client, resolved: NewResolvedStore(dataDir), now: time.Now}
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
		slog.Error("thread.Service.List: ListThreads failed",
			"repositoryID", repositoryID, "prNumber", prNumber, "error", err)
		return nil
	}
	// Overlay locally-stored resolved status, but ONLY for threads whose
	// resolved state was NOT obtained from the upstream platform.
	//
	// When upstreamResolvedKnown is true (GitHub GraphQL returned resolved
	// state), GitHub is authoritative and the local ResolvedStore must not
	// override it — doing so would hide threads that were re-opened on
	// GitHub directly, causing pre-merge resolution to silently skip them.
	//
	// When upstreamResolvedKnown is false (Gitea or a failed GraphQL fetch),
	// the local store is the only source of resolved state, so we apply it.
	if s.resolved != nil {
		for i := range threads {
			if threads[i].upstreamResolvedKnown {
				continue // GitHub is authoritative; never override with local cache
			}
			if s.resolved.IsResolved(threads[i].ID) {
				threads[i].Status = ThreadStatusResolved
			}
		}
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

	// Look up the existing thread to get its anchor (file path + line) so that
	// platform clients (e.g. Gitea) can post the reply at the correct location.
	var anchor Anchor
	threads, err := s.client.ListThreads(ctx, req.RepositoryID, req.PRNumber)
	if err == nil {
		for _, t := range threads {
			if t.GitHubThreadID == req.ThreadID {
				anchor = t.Anchor
				break
			}
		}
	}

	commentID, err := s.client.ReplyThread(ctx, req.ThreadID, anchor, msg)
	if err != nil {
		return Thread{}, fmt.Errorf("reply github comment: %w", err)
	}

	msg.ID = commentID
	msg.GitHubCommentID = commentID

	// Re-fetch to return the full updated thread.
	threads, err = s.client.ListThreads(ctx, req.RepositoryID, req.PRNumber)
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

	// Persist the resolved state locally so future ListThreads calls reflect it
	// even on platforms (e.g. Gitea) that have no native resolve concept.
	if s.resolved != nil {
		_ = s.resolved.MarkResolved(req.ThreadID)
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

func (s *Service) Unresolve(ctx context.Context, req ResolveRequest) (Thread, error) {
	if err := s.client.UnresolveThread(ctx, req.ThreadID); err != nil {
		return Thread{}, fmt.Errorf("unresolve github thread: %w", err)
	}

	// Clear local resolved state so the thread shows as open again.
	if s.resolved != nil {
		_ = s.resolved.MarkUnresolved(req.ThreadID)
	}

	threads, err := s.client.ListThreads(ctx, req.RepositoryID, req.PRNumber)
	if err == nil {
		now2 := s.now().UTC()
		for _, t := range threads {
			if t.GitHubThreadID == req.ThreadID {
				t.Status = ThreadStatusOpen
				t.Sync = Sync{State: SyncStateSynced, LastSynced: &now2}
				return t, nil
			}
		}
	}
	return Thread{
		ID:           req.ThreadID,
		RepositoryID: req.RepositoryID,
		PRNumber:     req.PRNumber,
		Status:       ThreadStatusOpen,
		Sync:         Sync{State: SyncStateSynced},
	}, nil
}

// Delete removes a single message from a thread on GitHub/Gitea.
//
// Rules enforced:
//   - The message must be the last one in the thread (preserves conversation history).
//   - If Actor is set, the message must have been authored by that user.
//
// If MessageID is empty the thread root comment ID is derived from ThreadID
// and the same rules apply (legacy single-comment delete path).
func (s *Service) Delete(ctx context.Context, req DeleteRequest) error {
	// Fetch the current thread state so we can apply guards.
	threads, err := s.client.ListThreads(ctx, req.RepositoryID, req.PRNumber)
	if err != nil {
		return fmt.Errorf("fetch threads for delete: %w", err)
	}

	var target *Thread
	for i := range threads {
		if threads[i].ID == req.ThreadID {
			target = &threads[i]
			break
		}
	}
	if target == nil {
		return fmt.Errorf("thread not found")
	}

	if len(target.Messages) == 0 {
		return fmt.Errorf("thread has no messages")
	}

	// Determine which message is being deleted.
	messageID := req.MessageID
	if messageID == "" {
		// Legacy: derive from root comment encoded in ThreadID.
		_, _, commentID, ok := parseThreadHandle(req.ThreadID)
		if !ok {
			return fmt.Errorf("invalid thread id")
		}
		messageID = fmt.Sprintf("ghc-%s", commentID)
	}

	// Find the message.
	msgIdx := -1
	for i, m := range target.Messages {
		if m.ID == messageID {
			msgIdx = i
			break
		}
	}
	if msgIdx < 0 {
		return fmt.Errorf("message not found in thread")
	}

	// Guard: must be the last message to preserve conversation history.
	if msgIdx != len(target.Messages)-1 {
		return fmt.Errorf("only the last message in a thread can be deleted")
	}

	msg := target.Messages[msgIdx]

	// Guard: caller may only delete their own messages.
	if req.Actor != "" && msg.Author != req.Actor {
		return fmt.Errorf("cannot delete a message authored by %q", msg.Author)
	}

	// Strip the "ghc-" prefix to get the raw GitHub comment ID.
	rawCommentID := strings.TrimPrefix(msg.GitHubCommentID, "ghc-")
	if rawCommentID == "" {
		rawCommentID = msg.GitHubCommentID
	}
	commentHandle := makeThreadHandle(req.RepositoryID, req.PRNumber, rawCommentID)

	if err := s.client.DeleteComment(ctx, commentHandle); err != nil {
		return fmt.Errorf("delete github comment: %w", err)
	}
	return nil
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
