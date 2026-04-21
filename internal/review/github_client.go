package review

import (
	"context"
	"fmt"
	"sync/atomic"
)

type InMemoryGitHubClient struct {
	nextID atomic.Int64
}

func NewInMemoryGitHubClient() *InMemoryGitHubClient {
	client := &InMemoryGitHubClient{}
	client.nextID.Store(1000)
	return client
}

func (c *InMemoryGitHubClient) SubmitApproval(_ context.Context, req ApprovalRequest) (ApprovalResult, error) {
	if req.RepositoryID == "" {
		return ApprovalResult{}, fmt.Errorf("repository id is required")
	}
	if req.PRNumber <= 0 {
		return ApprovalResult{}, fmt.Errorf("pr number must be greater than zero")
	}

	reviewer := req.Reviewer
	if reviewer == "" {
		reviewer = "hermit-bot"
	}

	reviewID := fmt.Sprintf("ghr_%d", c.nextID.Add(1))

	return ApprovalResult{
		State:          StateApproved,
		Reviewer:       reviewer,
		GitHubReviewID: reviewID,
	}, nil
}
