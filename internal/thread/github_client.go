package thread

import (
	"context"
	"fmt"
	"sync/atomic"
)

type InMemoryGitHubClient struct {
	nextID atomic.Int64
}

func NewInMemoryGitHubClient() *InMemoryGitHubClient {
	c := &InMemoryGitHubClient{}
	c.nextID.Store(5000)
	return c
}

func (c *InMemoryGitHubClient) CreateThread(_ context.Context, thread Thread) (string, string, error) {
	if thread.RepositoryID == "" || thread.PRNumber <= 0 {
		return "", "", fmt.Errorf("invalid repository/pr values")
	}

	threadID := fmt.Sprintf("ght_%d", c.nextID.Add(1))
	messageID := fmt.Sprintf("ghc_%d", c.nextID.Add(1))
	return threadID, messageID, nil
}

func (c *InMemoryGitHubClient) ReplyThread(_ context.Context, githubThreadID string, _ Message) (string, error) {
	if githubThreadID == "" {
		return "", fmt.Errorf("github thread id is required")
	}

	commentID := fmt.Sprintf("ghc_%d", c.nextID.Add(1))
	return commentID, nil
}

func (c *InMemoryGitHubClient) ResolveThread(_ context.Context, githubThreadID string) error {
	if githubThreadID == "" {
		return fmt.Errorf("github thread id is required")
	}
	return nil
}
