package thread

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

type RepositoryAccessResolver interface {
	ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, token string, ok bool)
}

type HTTPGitHubClient struct {
	client       *http.Client
	repoResolver RepositoryAccessResolver
	registryBase map[string]string
}

func NewHTTPGitHubClient(resolver RepositoryAccessResolver, registryBase map[string]string) *HTTPGitHubClient {
	return &HTTPGitHubClient{client: &http.Client{}, repoResolver: resolver, registryBase: registryBase}
}

func (c *HTTPGitHubClient) CreateThread(ctx context.Context, thread Thread) (string, string, error) {
	owner, repo, baseURL, token, err := c.resolve(thread.RepositoryID)
	if err != nil {
		return "", "", err
	}
	if strings.TrimSpace(thread.Anchor.FilePath) == "" {
		return "", "", fmt.Errorf("anchor file path is required for inline PR comments")
	}
	if thread.Anchor.LineStart <= 0 {
		return "", "", fmt.Errorf("anchor line start must be greater than zero")
	}

	body := thread.Messages[0].Body
	commentBody := fmt.Sprintf("%s\n\n<!-- hermit-anchor lines:%d-%d fp:%s -->", body, thread.Anchor.LineStart, thread.Anchor.LineEnd, thread.Anchor.TextFingerprint)
	commentLine := thread.Anchor.LineEnd
	if commentLine <= 0 {
		commentLine = thread.Anchor.LineStart
	}
	commentID, err := c.postPullRequestInlineComment(ctx, baseURL, owner, repo, thread.PRNumber, token, thread.Anchor.FilePath, commentLine, commentBody)
	if err != nil {
		return "", "", err
	}

	threadHandle := makeThreadHandle(thread.RepositoryID, thread.PRNumber, commentID)
	return threadHandle, commentID, nil
}

func (c *HTTPGitHubClient) ReplyThread(ctx context.Context, githubThreadID string, message Message) (string, error) {
	repositoryID, prNumber, _, ok := parseThreadHandle(githubThreadID)
	if !ok {
		return "", fmt.Errorf("invalid github thread handle")
	}

	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return "", err
	}

	return c.postIssueComment(ctx, baseURL, owner, repo, prNumber, token, message.Body)
}

func (c *HTTPGitHubClient) ResolveThread(ctx context.Context, githubThreadID string) error {
	repositoryID, prNumber, originalCommentID, ok := parseThreadHandle(githubThreadID)
	if !ok {
		return fmt.Errorf("invalid github thread handle")
	}

	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return err
	}

	resolveBody := "Marked resolved in Hermit."
	if originalCommentID != "" {
		resolveBody = fmt.Sprintf("Marked resolved in Hermit for root comment %s.", originalCommentID)
	}
	_, err = c.postIssueComment(ctx, baseURL, owner, repo, prNumber, token, resolveBody)
	return err
}

func (c *HTTPGitHubClient) postIssueComment(ctx context.Context, baseURL, owner, repo string, prNumber int, token, body string) (string, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/issues/%d/comments", strings.TrimRight(baseURL, "/"), owner, repo, prNumber)
	payload, err := json.Marshal(map[string]string{"body": body})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := c.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", fmt.Errorf("github comment create failed: %d %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var result struct {
		ID int64 `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}

	if result.ID == 0 {
		return "", fmt.Errorf("github comment create returned no id")
	}

	return strconv.FormatInt(result.ID, 10), nil
}

func (c *HTTPGitHubClient) postPullRequestInlineComment(ctx context.Context, baseURL, owner, repo string, prNumber int, token, filePath string, bodyLine int, body string) (string, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews", strings.TrimRight(baseURL, "/"), owner, repo, prNumber)
	payload, err := json.Marshal(map[string]any{
		"event": "COMMENT",
		"comments": []map[string]any{{
			"path":         strings.TrimPrefix(filePath, "/"),
			"body":         body,
			"new_position": bodyLine,
			"old_position": 0,
		}},
	})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := c.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("github inline review comment create failed: %d %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var result struct {
		ID int64 `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.ID == 0 {
		return "", fmt.Errorf("github inline review response returned no id")
	}

	return strconv.FormatInt(result.ID, 10), nil
}

func (c *HTTPGitHubClient) resolve(repositoryID string) (owner, repo, baseURL, token string, err error) {
	if c.repoResolver == nil {
		return "", "", "", "", fmt.Errorf("repository resolver not configured")
	}

	resolvedOwner, resolvedRepo, registry, _, _, resolvedToken, ok := c.repoResolver.ResolveRepositoryAccess(repositoryID)
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

func makeThreadHandle(repositoryID string, prNumber int, commentID string) string {
	return fmt.Sprintf("%s:%d:%s", repositoryID, prNumber, commentID)
}

func parseThreadHandle(value string) (string, int, string, bool) {
	parts := strings.SplitN(value, ":", 3)
	if len(parts) < 2 {
		return "", 0, "", false
	}
	prNumber, err := strconv.Atoi(parts[1])
	if err != nil || prNumber <= 0 {
		return "", 0, "", false
	}
	if strings.TrimSpace(parts[0]) == "" {
		return "", 0, "", false
	}
	commentID := ""
	if len(parts) == 3 {
		commentID = strings.TrimSpace(parts[2])
	}
	return parts[0], prNumber, commentID, true
}
