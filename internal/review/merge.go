package review

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// MergeStatus describes whether a PR branch is behind its base branch.
type MergeStatus struct {
	Behind bool `json:"behind"`
}

// MergeClient is the interface for merge-status and update-branch operations.
type MergeClient interface {
	GetMergeStatus(ctx context.Context, repositoryID string, prNumber int) (MergeStatus, error)
	UpdateBranch(ctx context.Context, repositoryID string, prNumber int) error
}

// HTTPMergeClient implements MergeClient against the GitHub REST API.
type HTTPMergeClient struct {
	client       *http.Client
	repoResolver RepositoryAccessResolver
	registryBase map[string]string
}

// RepositoryAccessResolver is the same interface used by the thread package.
// Re-declared here so the review package has no import cycle with thread.
type RepositoryAccessResolver interface {
	ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool)
}

func NewHTTPMergeClient(resolver RepositoryAccessResolver, registryBase map[string]string) *HTTPMergeClient {
	return &HTTPMergeClient{
		client:       &http.Client{},
		repoResolver: resolver,
		registryBase: registryBase,
	}
}

// GetMergeStatus calls GET /repos/{owner}/{repo}/pulls/{number} and inspects
// mergeable_state.  A value of "behind" means the branch needs updating.
func (c *HTTPMergeClient) GetMergeStatus(ctx context.Context, repositoryID string, prNumber int) (MergeStatus, error) {
	owner, repo, base, token, err := c.resolve(repositoryID)
	if err != nil {
		return MergeStatus{}, err
	}

	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d", strings.TrimRight(base, "/"), owner, repo, prNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return MergeStatus{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := c.client.Do(req)
	if err != nil {
		return MergeStatus{}, fmt.Errorf("github get pr: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return MergeStatus{}, fmt.Errorf("github get pr: unexpected status %d", resp.StatusCode)
	}

	var pr struct {
		MergeableState string `json:"mergeable_state"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return MergeStatus{}, fmt.Errorf("github get pr: decode: %w", err)
	}

	return MergeStatus{Behind: pr.MergeableState == "behind"}, nil
}

// UpdateBranch calls PUT /repos/{owner}/{repo}/pulls/{number}/update-branch
// which triggers GitHub to merge the base branch into the PR head.
func (c *HTTPMergeClient) UpdateBranch(ctx context.Context, repositoryID string, prNumber int) error {
	owner, repo, base, token, err := c.resolve(repositoryID)
	if err != nil {
		return err
	}

	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/update-branch", strings.TrimRight(base, "/"), owner, repo, prNumber)

	body, _ := json.Marshal(map[string]any{})
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("github update branch: %w", err)
	}
	defer resp.Body.Close()

	// 202 Accepted is the success response from GitHub.
	if resp.StatusCode != http.StatusAccepted && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("github update branch: unexpected status %d", resp.StatusCode)
	}
	return nil
}

func (c *HTTPMergeClient) resolve(repositoryID string) (owner, repo, baseURL, token string, err error) {
	if c.repoResolver == nil {
		return "", "", "", "", fmt.Errorf("repository resolver not configured")
	}
	resolvedOwner, resolvedRepo, registry, _, _, _, resolvedToken, ok := c.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return "", "", "", "", fmt.Errorf("repository not found")
	}
	if strings.TrimSpace(resolvedToken) == "" {
		return "", "", "", "", fmt.Errorf("repository token unavailable")
	}
	base := "https://api.github.com"
	if c.registryBase != nil {
		if configured, found := c.registryBase[registry]; found && strings.TrimSpace(configured) != "" {
			base = configured
		}
	}
	return resolvedOwner, resolvedRepo, base, resolvedToken, nil
}

// InMemoryMergeClient is used in tests / when no resolver is wired up.
type InMemoryMergeClient struct{}

func (c *InMemoryMergeClient) GetMergeStatus(_ context.Context, _ string, _ int) (MergeStatus, error) {
	return MergeStatus{Behind: false}, nil
}

func (c *InMemoryMergeClient) UpdateBranch(_ context.Context, _ string, _ int) error {
	return nil
}
