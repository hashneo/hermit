package review

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

// ReviewItem is a single PR review as returned by the GitHub reviews API.
type ReviewItem struct {
	ID          int64     `json:"id"`
	State       string    `json:"state"`        // "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED" | "DISMISSED"
	Body        string    `json:"body"`
	User        string    `json:"user"`
	SubmittedAt time.Time `json:"submitted_at"`
}

// GitHubClient is the interface for PR review operations.
type GitHubClient interface {
	SubmitApproval(ctx context.Context, req ApprovalRequest) (ApprovalResult, error)
	SubmitRequestChanges(ctx context.Context, baseURL, owner, name string, prNumber int, body, token string) (ApprovalResult, error)
	ListReviews(ctx context.Context, baseURL, owner, name string, prNumber int, token string) ([]ReviewItem, error)
	DismissReview(ctx context.Context, baseURL, owner, name string, prNumber int, reviewID int64, message, token string) error
}

// HTTPGitHubReviewClient is the real GitHub REST implementation of GitHubClient.
type HTTPGitHubReviewClient struct {
	client *http.Client
}

func NewHTTPGitHubReviewClient() *HTTPGitHubReviewClient {
	return &HTTPGitHubReviewClient{client: &http.Client{Timeout: 20 * time.Second}}
}

func (c *HTTPGitHubReviewClient) setHeaders(req *http.Request, token string) {
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
}

// SubmitApproval posts an APPROVE review to GitHub.
func (c *HTTPGitHubReviewClient) SubmitApproval(ctx context.Context, req ApprovalRequest) (ApprovalResult, error) {
	if req.RepositoryID == "" {
		return ApprovalResult{}, fmt.Errorf("repository id is required")
	}
	if req.PRNumber <= 0 {
		return ApprovalResult{}, fmt.Errorf("pr number must be greater than zero")
	}
	if req.BaseURL == "" || req.Owner == "" || req.Name == "" || req.Token == "" {
		return ApprovalResult{}, fmt.Errorf("base_url, owner, name and token are required")
	}

	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews",
		strings.TrimRight(req.BaseURL, "/"), req.Owner, req.Name, req.PRNumber)

	body, _ := json.Marshal(map[string]string{
		"event": "APPROVE",
		"body":  req.Body,
	})
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return ApprovalResult{}, err
	}
	c.setHeaders(httpReq, req.Token)
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return ApprovalResult{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return ApprovalResult{}, fmt.Errorf("github approve failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	var result struct {
		ID   int64  `json:"id"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return ApprovalResult{}, fmt.Errorf("decode approve response: %w", err)
	}
	reviewer := result.User.Login
	if reviewer == "" {
		reviewer = req.Reviewer
	}
	return ApprovalResult{
		State:          StateApproved,
		Reviewer:       reviewer,
		GitHubReviewID: fmt.Sprintf("%d", result.ID),
	}, nil
}

// SubmitRequestChanges posts a REQUEST_CHANGES review to GitHub.
func (c *HTTPGitHubReviewClient) SubmitRequestChanges(ctx context.Context, baseURL, owner, name string, prNumber int, body, token string) (ApprovalResult, error) {
	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews",
		strings.TrimRight(baseURL, "/"), owner, name, prNumber)

	payload, _ := json.Marshal(map[string]string{
		"event": "REQUEST_CHANGES",
		"body":  body,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(payload))
	if err != nil {
		return ApprovalResult{}, err
	}
	c.setHeaders(req, token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return ApprovalResult{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return ApprovalResult{}, fmt.Errorf("github request changes failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	var result struct {
		ID   int64  `json:"id"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return ApprovalResult{}, fmt.Errorf("decode request-changes response: %w", err)
	}
	return ApprovalResult{
		State:          StateChangesRequested,
		Reviewer:       result.User.Login,
		GitHubReviewID: fmt.Sprintf("%d", result.ID),
	}, nil
}

// ListReviews returns all reviews for a PR, most recent first.
func (c *HTTPGitHubReviewClient) ListReviews(ctx context.Context, baseURL, owner, name string, prNumber int, token string) ([]ReviewItem, error) {
	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews",
		strings.TrimRight(baseURL, "/"), owner, name, prNumber)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req, token)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("list reviews failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	var raw []struct {
		ID          int64     `json:"id"`
		State       string    `json:"state"`
		Body        string    `json:"body"`
		SubmittedAt time.Time `json:"submitted_at"`
		User        struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, fmt.Errorf("decode reviews: %w", err)
	}

	items := make([]ReviewItem, 0, len(raw))
	for _, r := range raw {
		items = append(items, ReviewItem{
			ID:          r.ID,
			State:       r.State,
			Body:        r.Body,
			User:        r.User.Login,
			SubmittedAt: r.SubmittedAt,
		})
	}
	return items, nil
}

// DismissReview dismisses a specific review by ID.
func (c *HTTPGitHubReviewClient) DismissReview(ctx context.Context, baseURL, owner, name string, prNumber int, reviewID int64, message, token string) error {
	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews/%d/dismissals",
		strings.TrimRight(baseURL, "/"), owner, name, prNumber, reviewID)

	payload, _ := json.Marshal(map[string]string{"message": message})
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	c.setHeaders(req, token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("dismiss review %d failed: %d %s", reviewID, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

// InMemoryGitHubClient is used in tests / when no real client is wired.
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
	return ApprovalResult{State: StateApproved, Reviewer: reviewer, GitHubReviewID: reviewID}, nil
}

func (c *InMemoryGitHubClient) SubmitRequestChanges(_ context.Context, _, _, _ string, _ int, _ string, _ string) (ApprovalResult, error) {
	reviewID := fmt.Sprintf("ghr_%d", c.nextID.Add(1))
	return ApprovalResult{State: StateChangesRequested, Reviewer: "hermit-bot", GitHubReviewID: reviewID}, nil
}

func (c *InMemoryGitHubClient) ListReviews(_ context.Context, _, _, _ string, _ int, _ string) ([]ReviewItem, error) {
	return nil, nil
}

func (c *InMemoryGitHubClient) DismissReview(_ context.Context, _, _, _ string, _ int, _ int64, _, _ string) error {
	return nil
}

