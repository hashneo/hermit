package thread

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
)

type InMemoryGitHubClient struct {
	mu      sync.RWMutex
	threads map[string]Thread // keyed by GitHubThreadID
	nextID  atomic.Int64
}

func NewInMemoryGitHubClient() *InMemoryGitHubClient {
	c := &InMemoryGitHubClient{threads: map[string]Thread{}}
	c.nextID.Store(5000)
	return c
}

func (c *InMemoryGitHubClient) ListThreads(_ context.Context, repositoryID string, prNumber int) ([]Thread, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	var out []Thread
	for _, t := range c.threads {
		if t.RepositoryID == repositoryID && t.PRNumber == prNumber {
			out = append(out, t)
		}
	}
	return out, nil
}

func (c *InMemoryGitHubClient) CreateThread(_ context.Context, thread Thread) (string, string, error) {
	if thread.RepositoryID == "" || thread.PRNumber <= 0 {
		return "", "", fmt.Errorf("invalid repository/pr values")
	}

	threadID := fmt.Sprintf("ght_%d", c.nextID.Add(1))
	commentID := fmt.Sprintf("ghc_%d", c.nextID.Add(1))

	thread.ID = threadID
	thread.GitHubThreadID = threadID
	if len(thread.Messages) > 0 {
		thread.Messages[0].ID = commentID
		thread.Messages[0].GitHubCommentID = commentID
	}

	c.mu.Lock()
	c.threads[threadID] = thread
	c.mu.Unlock()

	return threadID, commentID, nil
}

func (c *InMemoryGitHubClient) ReplyThread(_ context.Context, githubThreadID string, anchor Anchor, msg Message) (string, error) {
	if githubThreadID == "" {
		return "", fmt.Errorf("github thread id is required")
	}

	commentID := fmt.Sprintf("ghc_%d", c.nextID.Add(1))
	msg.ID = commentID
	msg.GitHubCommentID = commentID

	c.mu.Lock()
	if t, ok := c.threads[githubThreadID]; ok {
		t.Messages = append(t.Messages, msg)
		c.threads[githubThreadID] = t
	}
	c.mu.Unlock()

	return commentID, nil
}

func (c *InMemoryGitHubClient) ResolveThread(_ context.Context, githubThreadID string) error {
	if githubThreadID == "" {
		return fmt.Errorf("github thread id is required")
	}

	c.mu.Lock()
	if t, ok := c.threads[githubThreadID]; ok {
		t.Status = ThreadStatusResolved
		c.threads[githubThreadID] = t
	}
	c.mu.Unlock()

	return nil
}

func (c *InMemoryGitHubClient) DeleteComment(_ context.Context, githubCommentID string) error {
	if githubCommentID == "" {
		return fmt.Errorf("github comment id is required")
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// The threadID IS the comment ID in the in-memory store (see CreateThread).
	// Delete by matching GitHubThreadID or the root comment ID.
	for key, t := range c.threads {
		if t.GitHubThreadID == githubCommentID {
			delete(c.threads, key)
			return nil
		}
		if len(t.Messages) > 0 && t.Messages[0].GitHubCommentID == githubCommentID {
			delete(c.threads, key)
			return nil
		}
	}
	return fmt.Errorf("thread not found")
}
