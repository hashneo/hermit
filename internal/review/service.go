package review

import (
	"context"
	"fmt"
	"sync"
	"time"
)

const (
	StateApproved = "approved"
	StatePending  = "pending"
)

type State struct {
	RepositoryID   string    `json:"repository_id"`
	PRNumber       int       `json:"pr_number"`
	State          string    `json:"state"`
	Reviewer       string    `json:"reviewer,omitempty"`
	GitHubReviewID string    `json:"github_review_id,omitempty"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type ApprovalRequest struct {
	RepositoryID string
	PRNumber     int
	Body         string
	Reviewer     string
}

type ApprovalResult struct {
	State          string
	Reviewer       string
	GitHubReviewID string
}

type GitHubClient interface {
	SubmitApproval(ctx context.Context, req ApprovalRequest) (ApprovalResult, error)
}

type Service struct {
	mu     sync.RWMutex
	state  map[string]State
	client GitHubClient
	now    func() time.Time
}

func NewService(client GitHubClient) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}

	return &Service{
		state:  make(map[string]State),
		client: client,
		now:    time.Now,
	}
}

func (s *Service) Approve(ctx context.Context, req ApprovalRequest) (State, error) {
	result, err := s.client.SubmitApproval(ctx, req)
	if err != nil {
		return State{}, fmt.Errorf("submit approval to github: %w", err)
	}

	status := State{
		RepositoryID:   req.RepositoryID,
		PRNumber:       req.PRNumber,
		State:          result.State,
		Reviewer:       result.Reviewer,
		GitHubReviewID: result.GitHubReviewID,
		UpdatedAt:      s.now().UTC(),
	}

	s.mu.Lock()
	s.state[s.key(req.RepositoryID, req.PRNumber)] = status
	s.mu.Unlock()

	return status, nil
}

func (s *Service) Get(repositoryID string, prNumber int) State {
	key := s.key(repositoryID, prNumber)

	s.mu.RLock()
	status, ok := s.state[key]
	s.mu.RUnlock()
	if ok {
		return status
	}

	return State{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		State:        StatePending,
		UpdatedAt:    s.now().UTC(),
	}
}

func (s *Service) key(repositoryID string, prNumber int) string {
	return fmt.Sprintf("%s:%d", repositoryID, prNumber)
}
