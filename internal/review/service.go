package review

import (
	"context"
	"fmt"
	"sync"
	"time"
)

const (
	StateApproved        = "approved"
	StatePending         = "pending"
	StateChangesRequested = "changes_requested"
)

// State is the in-memory approval record (kept for the Approve flow).
type State struct {
	RepositoryID   string    `json:"repository_id"`
	PRNumber       int       `json:"pr_number"`
	State          string    `json:"state"`
	Reviewer       string    `json:"reviewer,omitempty"`
	GitHubReviewID string    `json:"github_review_id,omitempty"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// ReviewStateResponse is the JSON shape returned by GetReviewState.
// Matches what the Swift client expects: { approved, reviewers }.
type ReviewStateResponse struct {
	Approved  bool     `json:"approved"`
	Reviewers []string `json:"reviewers"`
}

type ApprovalRequest struct {
	RepositoryID string
	PRNumber     int
	Body         string
	Reviewer     string
	// Fields required by HTTPGitHubReviewClient (filled by service from repo resolver).
	BaseURL string
	Owner   string
	Name    string
	Token   string
}

type ApprovalResult struct {
	State          string
	Reviewer       string
	GitHubReviewID string
}

// RequestChangesResult is returned by RequestChanges.
type RequestChangesResult struct {
	GitHubReviewID string `json:"github_review_id"`
	Reviewer       string `json:"reviewer"`
}

// ListReviewsResult is returned by ListReviews.
type ListReviewsResult struct {
	Items []ReviewItem `json:"items"`
}

type Service struct {
	mu          sync.RWMutex
	state       map[string]State
	client      GitHubClient
	mergeClient MergeClient
	resolver    RepositoryAccessResolver
	registryBase map[string]string
	now         func() time.Time
}

func NewService(client GitHubClient) *Service {
	return NewServiceWithMergeClient(client, nil)
}

func NewServiceWithMergeClient(client GitHubClient, mergeClient MergeClient) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}
	if mergeClient == nil {
		mergeClient = &InMemoryMergeClient{}
	}
	return &Service{
		state:       make(map[string]State),
		client:      client,
		mergeClient: mergeClient,
		now:         time.Now,
	}
}

// NewServiceWithResolver creates a Service wired with a real HTTP review client
// and repository resolver so it can make real GitHub API calls.
func NewServiceWithResolver(resolver RepositoryAccessResolver, registryBase map[string]string, mergeClient MergeClient) *Service {
	if mergeClient == nil {
		mergeClient = &InMemoryMergeClient{}
	}
	return &Service{
		state:        make(map[string]State),
		client:       NewHTTPGitHubReviewClient(),
		mergeClient:  mergeClient,
		resolver:     resolver,
		registryBase: registryBase,
		now:          time.Now,
	}
}

func (s *Service) resolveRepo(repositoryID string) (baseURL, owner, name, token string, err error) {
	if s.resolver == nil {
		return "", "", "", "", fmt.Errorf("repository resolver not configured")
	}
	resolvedOwner, resolvedName, registry, _, _, _, _, resolvedToken, ok := s.resolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return "", "", "", "", fmt.Errorf("repository not found: %s", repositoryID)
	}
	if resolvedToken == "" {
		return "", "", "", "", fmt.Errorf("repository token unavailable")
	}
	base := "https://api.github.com"
	if s.registryBase != nil {
		if configured, found := s.registryBase[registry]; found && configured != "" {
			base = configured
		}
	}
	return base, resolvedOwner, resolvedName, resolvedToken, nil
}

func (s *Service) Approve(ctx context.Context, req ApprovalRequest) (State, error) {
	// If we have a real resolver, fill in GitHub coordinates.
	if s.resolver != nil {
		baseURL, owner, name, token, err := s.resolveRepo(req.RepositoryID)
		if err != nil {
			return State{}, err
		}
		req.BaseURL = baseURL
		req.Owner = owner
		req.Name = name
		req.Token = token
	}

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

// RequestChanges submits a REQUEST_CHANGES review to GitHub.
func (s *Service) RequestChanges(ctx context.Context, repositoryID string, prNumber int, body, reviewer string) (RequestChangesResult, error) {
	baseURL, owner, name, token, err := s.resolveRepo(repositoryID)
	if err != nil {
		return RequestChangesResult{}, err
	}

	result, err := s.client.SubmitRequestChanges(ctx, baseURL, owner, name, prNumber, body, token)
	if err != nil {
		return RequestChangesResult{}, fmt.Errorf("submit request changes: %w", err)
	}
	return RequestChangesResult{GitHubReviewID: result.GitHubReviewID, Reviewer: reviewer}, nil
}

// ListReviews returns all reviews for a PR from GitHub.
func (s *Service) ListReviews(ctx context.Context, repositoryID string, prNumber int) (ListReviewsResult, error) {
	baseURL, owner, name, token, err := s.resolveRepo(repositoryID)
	if err != nil {
		return ListReviewsResult{}, err
	}

	items, err := s.client.ListReviews(ctx, baseURL, owner, name, prNumber, token)
	if err != nil {
		return ListReviewsResult{}, fmt.Errorf("list reviews: %w", err)
	}
	return ListReviewsResult{Items: items}, nil
}

// DismissReview dismisses a single review by its numeric GitHub review ID.
func (s *Service) DismissReview(ctx context.Context, repositoryID string, prNumber int, reviewID int64, message string) error {
	baseURL, owner, name, token, err := s.resolveRepo(repositoryID)
	if err != nil {
		return err
	}
	return s.client.DismissReview(ctx, baseURL, owner, name, prNumber, reviewID, message, token)
}

func (s *Service) Get(repositoryID string, prNumber int) ReviewStateResponse {
	key := s.key(repositoryID, prNumber)

	s.mu.RLock()
	status, ok := s.state[key]
	s.mu.RUnlock()

	if ok && status.State == StateApproved {
		reviewer := status.Reviewer
		var reviewers []string
		if reviewer != "" {
			reviewers = []string{reviewer}
		}
		return ReviewStateResponse{Approved: true, Reviewers: reviewers}
	}
	return ReviewStateResponse{Approved: false, Reviewers: nil}
}

func (s *Service) key(repositoryID string, prNumber int) string {
	return fmt.Sprintf("%s:%d", repositoryID, prNumber)
}

func (s *Service) GetMergeStatus(ctx context.Context, repositoryID string, prNumber int) (MergeStatus, error) {
	return s.mergeClient.GetMergeStatus(ctx, repositoryID, prNumber)
}

func (s *Service) UpdateBranch(ctx context.Context, repositoryID string, prNumber int) error {
	return s.mergeClient.UpdateBranch(ctx, repositoryID, prNumber)
}
