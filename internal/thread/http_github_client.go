package thread

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
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

// anchorRE parses <!-- hermit-anchor lines:S-E fp:FP --> embedded in comment bodies.
// The fingerprint field is matched lazily up to --> so it tolerates embedded newlines
// (which can occur when the fingerprinted block text itself contains line breaks).
var anchorRE = regexp.MustCompile(`(?s)<!--\s*hermit-anchor\s+lines:(\d+)-(\d+)\s+fp:(.+?)\s*-->`)

func (c *HTTPGitHubClient) ListThreads(ctx context.Context, repositoryID string, prNumber int) ([]Thread, error) {
	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return nil, err
	}

	// Fetch all reviews for the PR.
	reviewsURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews", strings.TrimRight(baseURL, "/"), owner, repo, prNumber)
	reviewsData, err := c.getJSON(ctx, reviewsURL, token)
	if err != nil {
		return nil, fmt.Errorf("list reviews: %w", err)
	}

	var reviews []struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(reviewsData, &reviews); err != nil {
		return nil, fmt.Errorf("decode reviews: %w", err)
	}

	var threads []Thread
	for _, review := range reviews {
		commentsURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews/%d/comments",
			strings.TrimRight(baseURL, "/"), owner, repo, prNumber, review.ID)
		commentsData, err := c.getJSON(ctx, commentsURL, token)
		if err != nil {
			continue
		}

		var comments []struct {
			ID               int64     `json:"id"`
			Body             string    `json:"body"`
			User             struct{ Login string `json:"login"` } `json:"user"`
			Path             string    `json:"path"`
			Position         int       `json:"position"`
			OriginalPosition int       `json:"original_position"`
			CreatedAt        time.Time `json:"created_at"`
			UpdatedAt        time.Time `json:"updated_at"`
		}
		if err := json.Unmarshal(commentsData, &comments); err != nil {
			continue
		}

		for _, c := range comments {
			commentID := strconv.FormatInt(c.ID, 10)
			threadHandle := makeThreadHandle(repositoryID, prNumber, commentID)

			// Strip the hermit-anchor metadata from the visible body.
			visibleBody := strings.TrimSpace(anchorRE.ReplaceAllString(c.Body, ""))

			// Parse anchor metadata if present.
			anchor := Anchor{FilePath: c.Path}
			if m := anchorRE.FindStringSubmatch(c.Body); m != nil {
				if ls, err := strconv.Atoi(m[1]); err == nil {
					anchor.LineStart = ls
				}
				if le, err := strconv.Atoi(m[2]); err == nil {
					anchor.LineEnd = le
				}
				anchor.TextFingerprint = m[3]
			} else {
				// No hermit metadata — use the diff position from Gitea.
				// Gitea returns `position` (diff hunk position) for all inline
				// comments. Fall back to original_position if position is zero
				// (e.g. outdated comments on stale diffs).
				pos := c.Position
				if pos == 0 {
					pos = c.OriginalPosition
				}
				anchor.LineStart = pos
				anchor.LineEnd = pos
			}

			thread := Thread{
				ID:             threadHandle,
				RepositoryID:   repositoryID,
				PRNumber:       prNumber,
				Status:         ThreadStatusOpen,
				Anchor:         anchor,
				GitHubThreadID: threadHandle,
				Messages: []Message{{
					ID:              fmt.Sprintf("ghc-%s", commentID),
					Author:          c.User.Login,
					Body:            visibleBody,
					SourceSystem:    "github",
					GitHubCommentID: commentID,
					CreatedAt:       c.CreatedAt,
				}},
				Sync:      Sync{State: SyncStateSynced},
				CreatedAt: c.CreatedAt,
				UpdatedAt: c.UpdatedAt,
			}
			threads = append(threads, thread)
		}
	}

	return threads, nil
}

func (c *HTTPGitHubClient) getJSON(ctx context.Context, url, token string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return io.ReadAll(resp.Body)
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

func (c *HTTPGitHubClient) ReplyThread(ctx context.Context, githubThreadID string, anchor Anchor, message Message) (string, error) {
	repositoryID, prNumber, commentID, ok := parseThreadHandle(githubThreadID)
	if !ok {
		return "", fmt.Errorf("invalid github thread handle")
	}

	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return "", err
	}

	// GitHub has a native reply-to-comment endpoint; Gitea does not.
	// For GitHub: POST /repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies
	// For Gitea:  POST a new inline review at the same path+position (mirrors UI behaviour).
	if strings.Contains(baseURL, "api.github.com") {
		return c.postGitHubCommentReply(ctx, baseURL, owner, repo, prNumber, commentID, token, message.Body)
	}

	filePath := strings.TrimPrefix(anchor.FilePath, "/")
	position := anchor.LineEnd
	if position <= 0 {
		position = anchor.LineStart
	}
	return c.postPullRequestInlineComment(ctx, baseURL, owner, repo, prNumber, token, filePath, position, message.Body)
}

func (c *HTTPGitHubClient) postGitHubCommentReply(ctx context.Context, baseURL, owner, repo string, prNumber int, commentID, token, body string) (string, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/comments/%s/replies", strings.TrimRight(baseURL, "/"), owner, repo, prNumber, commentID)
	payload, err := json.Marshal(map[string]string{"body": body})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", fmt.Errorf("github comment reply failed: %d %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var result struct {
		ID int64 `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.ID == 0 {
		return "", fmt.Errorf("github comment reply returned no id")
	}

	return strconv.FormatInt(result.ID, 10), nil
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
	req.Header.Set("Content-Type", "application/json")

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
	// Gitea uses the review API for inline PR comments.
	// POST /repos/{owner}/{repo}/pulls/{index}/reviews
	// with event="COMMENT" and a single entry in comments[].
	// new_position is the line number in the new (right-side) file.
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews", strings.TrimRight(baseURL, "/"), owner, repo, prNumber)
	payload, err := json.Marshal(map[string]any{
		"event": "COMMENT",
		"comments": []map[string]any{
			{
				"path":         strings.TrimPrefix(filePath, "/"),
				"new_position": bodyLine,
				"body":         body,
			},
		},
	})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("github inline comment create failed: %d %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	// The response is the review object. Use the review ID as the thread handle
	// since Gitea doesn't return individual comment IDs in this response.
	var result struct {
		ID int64 `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.ID == 0 {
		return "", fmt.Errorf("github inline comment response returned no id")
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
