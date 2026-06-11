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
	ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool)
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

// prComment is the JSON shape returned by GET /repos/{owner}/{repo}/pulls/{pr}/comments.
type prComment struct {
	ID               int64     `json:"id"`
	InReplyToID      int64     `json:"in_reply_to_id"`
	Body             string    `json:"body"`
	User             struct{ Login string `json:"login"` } `json:"user"`
	Path             string    `json:"path"`
	Line             *int      `json:"line"`           // file line number (null when outdated)
	OriginalLine     *int      `json:"original_line"`  // file line at time of comment
	Position         int       `json:"position"`
	OriginalPosition int       `json:"original_position"`
	CreatedAt        time.Time `json:"created_at"`
	UpdatedAt        time.Time `json:"updated_at"`
}

func (c *HTTPGitHubClient) ListThreads(ctx context.Context, repositoryID string, prNumber int) ([]Thread, error) {
	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return nil, err
	}

	// Fetch all inline PR review comments in one call.
	// GET /repos/{owner}/{repo}/pulls/{pr}/comments returns every comment
	// including replies (which have in_reply_to_id set).  This is the only
	// endpoint that includes replies — the reviews/{id}/comments sub-endpoint
	// only returns root comments that were submitted as part of a formal review.
	allComments, err := c.fetchAllPRComments(ctx, baseURL, owner, repo, prNumber, token)
	if err != nil {
		return nil, fmt.Errorf("list pr comments: %w", err)
	}

	// Separate roots from replies and index both by ID.
	roots   := make([]prComment, 0)
	replies := make(map[int64][]prComment) // keyed by root comment ID
	byID    := make(map[int64]prComment)

	for _, c := range allComments {
		byID[c.ID] = c
		if c.InReplyToID == 0 {
			roots = append(roots, c)
		} else {
			// Walk up to find the true root (replies can be nested > 1 level deep).
			rootID := c.InReplyToID
			for {
				if parent, ok := byID[rootID]; ok && parent.InReplyToID != 0 {
					rootID = parent.InReplyToID
				} else {
					break
				}
			}
			replies[rootID] = append(replies[rootID], c)
		}
	}

	// Fetch resolved status for every review thread from GitHub GraphQL.
	// Map: root comment database ID → isResolved.  Best-effort; on failure
	// we fall back to treating everything as open (ResolvedStore overlay still applies).
	resolvedByRootID, _ := c.fetchResolvedThreadIDs(ctx, baseURL, owner, repo, prNumber, token)

	threads := make([]Thread, 0, len(roots))
	for _, root := range roots {
		commentID  := strconv.FormatInt(root.ID, 10)
		threadHandle := makeThreadHandle(repositoryID, prNumber, commentID)

		visibleBody := strings.TrimSpace(anchorRE.ReplaceAllString(root.Body, ""))

		anchor := Anchor{FilePath: root.Path}
		outdated := false
		if m := anchorRE.FindStringSubmatch(root.Body); m != nil {
			if ls, err2 := strconv.Atoi(m[1]); err2 == nil { anchor.LineStart = ls }
			if le, err2 := strconv.Atoi(m[2]); err2 == nil { anchor.LineEnd   = le }
			anchor.TextFingerprint = m[3]
		} else {
			// Prefer the current file line number; fall back to original_line for
			// outdated comments (where line is null because the code was changed).
			if root.Line != nil && *root.Line > 0 {
				anchor.LineStart = *root.Line
				anchor.LineEnd   = *root.Line
			} else if root.OriginalLine != nil && *root.OriginalLine > 0 {
				anchor.LineStart = *root.OriginalLine
				anchor.LineEnd   = *root.OriginalLine
				outdated = true
			} else {
				// Truly unanchored — pin to line 1 so it always appears.
				anchor.LineStart = 1
				anchor.LineEnd   = 1
				outdated = true
			}
		}

		msgs := []Message{{
			ID:              fmt.Sprintf("ghc-%s", commentID),
			Author:          root.User.Login,
			Body:            visibleBody,
			SourceSystem:    "github",
			GitHubCommentID: commentID,
			CreatedAt:       root.CreatedAt,
		}}

		// Append replies in chronological order.
		for _, r := range replies[root.ID] {
			rID := strconv.FormatInt(r.ID, 10)
			msgs = append(msgs, Message{
				ID:              fmt.Sprintf("ghc-%s", rID),
				Author:          r.User.Login,
				Body:            strings.TrimSpace(anchorRE.ReplaceAllString(r.Body, "")),
				SourceSystem:    "github",
				GitHubCommentID: rID,
				CreatedAt:       r.CreatedAt,
			})
		}
		// Sort replies by created time.
		for i := 1; i < len(msgs); i++ {
			for j := i; j > 1 && msgs[j].CreatedAt.Before(msgs[j-1].CreatedAt); j-- {
				msgs[j], msgs[j-1] = msgs[j-1], msgs[j]
			}
		}

		status := ThreadStatusOpen
		if resolvedByRootID[root.ID] {
			status = ThreadStatusResolved
		}

		threads = append(threads, Thread{
			ID:                    threadHandle,
			RepositoryID:          repositoryID,
			PRNumber:              prNumber,
			Status:                status,
			Outdated:              outdated,
			Anchor:                anchor,
			GitHubThreadID:        threadHandle,
			Messages:              msgs,
			Sync:                  Sync{State: SyncStateSynced},
			CreatedAt:             root.CreatedAt,
			UpdatedAt:             root.UpdatedAt,
			upstreamResolvedKnown: resolvedByRootID != nil,
		})
	}

	return threads, nil
}

// fetchAllPRComments pages through GET /repos/{owner}/{repo}/pulls/{pr}/comments
// returning all inline review comments including replies.
func (c *HTTPGitHubClient) fetchAllPRComments(ctx context.Context, baseURL, owner, repo string, prNumber int, token string) ([]prComment, error) {
	var all []prComment
	page := 1
	for {
		u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/comments?per_page=100&page=%d",
			strings.TrimRight(baseURL, "/"), owner, repo, prNumber, page)
		data, err := c.getJSON(ctx, u, token)
		if err != nil {
			return nil, err
		}
		var batch []prComment
		if err := json.Unmarshal(data, &batch); err != nil {
			return nil, err
		}
		all = append(all, batch...)
		if len(batch) < 100 {
			break
		}
		page++
	}
	return all, nil
}

// fetchResolvedThreadIDs queries GitHub GraphQL for all review threads on the PR
// and returns a map of root-comment database ID → isResolved.
// This allows ListThreads to reflect resolved state set on GitHub.com, not just
// via Hermit's local ResolvedStore.
func (c *HTTPGitHubClient) fetchResolvedThreadIDs(ctx context.Context, baseURL, owner, repo string, prNumber int, token string) (map[int64]bool, error) {
	query := `
query($owner:String!, $repo:String!, $pr:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          comments(first:1) {
            nodes { databaseId }
          }
        }
      }
    }
  }
}`

	type pageInfo struct {
		HasNextPage bool   `json:"hasNextPage"`
		EndCursor   string `json:"endCursor"`
	}
	type threadNode struct {
		IsResolved bool `json:"isResolved"`
		Comments   struct {
			Nodes []struct {
				DatabaseID int64 `json:"databaseId"`
			} `json:"nodes"`
		} `json:"comments"`
	}
	type gqlResp struct {
		Data struct {
			Repository struct {
				PullRequest struct {
					ReviewThreads struct {
						PageInfo pageInfo     `json:"pageInfo"`
						Nodes    []threadNode `json:"nodes"`
					} `json:"reviewThreads"`
				} `json:"pullRequest"`
			} `json:"repository"`
		} `json:"data"`
		Errors []struct{ Message string `json:"message"` } `json:"errors"`
	}

	result := make(map[int64]bool)
	var cursor *string

	for {
		vars := map[string]any{
			"owner": owner, "repo": repo, "pr": prNumber,
		}
		if cursor != nil {
			vars["cursor"] = *cursor
		}

		var resp gqlResp
		if err := c.graphqlRequest(ctx, baseURL, token, query, vars, &resp); err != nil {
			return nil, err
		}
		if len(resp.Errors) > 0 {
			return nil, fmt.Errorf("graphql: %s", resp.Errors[0].Message)
		}

		for _, node := range resp.Data.Repository.PullRequest.ReviewThreads.Nodes {
			if len(node.Comments.Nodes) > 0 {
				result[node.Comments.Nodes[0].DatabaseID] = node.IsResolved
			}
		}

		pi := resp.Data.Repository.PullRequest.ReviewThreads.PageInfo
		if !pi.HasNextPage {
			break
		}
		cursor = &pi.EndCursor
	}

	return result, nil
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
		// GitHub returns 422 when the line is not part of the diff (e.g. unchanged
		// lines outside the ±context shown in the PR). Return the error so the
		// caller can surface a clear message — silently posting a general PR
		// comment would lose the line anchor and confuse reviewers.
		if strings.Contains(err.Error(), "422") {
			return "", "", fmt.Errorf("line %d of %s is not part of the PR diff; comments can only be anchored to changed lines: %w", commentLine, thread.Anchor.FilePath, err)
		}
		return "", "", fmt.Errorf("create inline comment: %w", err)
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
	repositoryID, prNumber, commentID, ok := parseThreadHandle(githubThreadID)
	if !ok {
		return fmt.Errorf("invalid github thread handle")
	}

	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return err
	}

	// GitHub has a native GraphQL mutation for resolving review threads.
	// Use it when talking to api.github.com so the thread shows as resolved
	// on github.com. Gitea has no equivalent — we skip the upstream call
	// there and rely on the local ResolvedStore overlay in Service.
	if strings.Contains(baseURL, "api.github.com") {
		nodeID, err := c.findThreadNodeID(ctx, baseURL, owner, repo, prNumber, commentID, token)
		if err != nil {
			return fmt.Errorf("find thread node id: %w", err)
		}
		return c.resolveThreadGraphQL(ctx, baseURL, token, nodeID)
	}

	// Gitea: no-op at the API level; Service.Resolve persists state locally.
	return nil
}

// findThreadNodeID queries GitHub GraphQL to find the PullRequestReviewThread
// node ID that contains the comment with the given database ID.
// GitHub REST comments carry a numeric databaseId; GraphQL threads have a
// base64 node ID (PRRT_...) that the resolveReviewThread mutation requires.
func (c *HTTPGitHubClient) findThreadNodeID(ctx context.Context, baseURL, owner, repo string, prNumber int, commentID, token string) (string, error) {
	dbID, err := strconv.ParseInt(commentID, 10, 64)
	if err != nil {
		return "", fmt.Errorf("comment id %q is not numeric: %w", commentID, err)
	}

	// Page through review threads until we find one whose first comment
	// matches our database ID. 100 threads per page is the GraphQL max.
	query := `
query($owner:String!, $repo:String!, $pr:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:100, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          comments(first:1) {
            nodes { databaseId }
          }
        }
      }
    }
  }
}`

	type pageInfo struct {
		HasNextPage bool   `json:"hasNextPage"`
		EndCursor   string `json:"endCursor"`
	}
	type threadNode struct {
		ID       string `json:"id"`
		Comments struct {
			Nodes []struct {
				DatabaseID int64 `json:"databaseId"`
			} `json:"nodes"`
		} `json:"comments"`
	}
	type gqlResp struct {
		Data struct {
			Repository struct {
				PullRequest struct {
					ReviewThreads struct {
						PageInfo pageInfo     `json:"pageInfo"`
						Nodes    []threadNode `json:"nodes"`
					} `json:"reviewThreads"`
				} `json:"pullRequest"`
			} `json:"repository"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}

	var cursor *string
	for {
		vars := map[string]any{
			"owner":  owner,
			"repo":   repo,
			"pr":     prNumber,
			"cursor": cursor,
		}
		var resp gqlResp
		if err := c.graphqlRequest(ctx, baseURL, token, query, vars, &resp); err != nil {
			return "", err
		}
		if len(resp.Errors) > 0 {
			return "", fmt.Errorf("graphql: %s", resp.Errors[0].Message)
		}

		threads := resp.Data.Repository.PullRequest.ReviewThreads
		for _, t := range threads.Nodes {
			if len(t.Comments.Nodes) > 0 && t.Comments.Nodes[0].DatabaseID == dbID {
				return t.ID, nil
			}
		}

		if !threads.PageInfo.HasNextPage {
			break
		}
		cursor = &threads.PageInfo.EndCursor
	}

	return "", fmt.Errorf("no review thread found containing comment %s", commentID)
}

// resolveThreadGraphQL calls the GitHub GraphQL resolveReviewThread mutation.
func (c *HTTPGitHubClient) resolveThreadGraphQL(ctx context.Context, baseURL, token, threadNodeID string) error {
	mutation := `
mutation($threadID:ID!) {
  resolveReviewThread(input:{threadId:$threadID}) {
    thread { id isResolved }
  }
}`
	vars := map[string]any{"threadID": threadNodeID}

	var resp struct {
		Data   json.RawMessage `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := c.graphqlRequest(ctx, baseURL, token, mutation, vars, &resp); err != nil {
		return err
	}
	if len(resp.Errors) > 0 {
		return fmt.Errorf("graphql resolveReviewThread: %s", resp.Errors[0].Message)
	}
	return nil
}

// UnresolveThread re-opens a previously resolved review thread on GitHub.
func (c *HTTPGitHubClient) UnresolveThread(ctx context.Context, githubThreadID string) error {
	repositoryID, prNumber, commentID, ok := parseThreadHandle(githubThreadID)
	if !ok {
		return fmt.Errorf("invalid github thread handle")
	}

	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return err
	}

	if strings.Contains(baseURL, "api.github.com") {
		nodeID, err := c.findThreadNodeID(ctx, baseURL, owner, repo, prNumber, commentID, token)
		if err != nil {
			return fmt.Errorf("find thread node id: %w", err)
		}
		return c.unresolveThreadGraphQL(ctx, baseURL, token, nodeID)
	}

	// Gitea: no-op at the API level; Service.Unresolve clears local state.
	return nil
}

// unresolveThreadGraphQL calls the GitHub GraphQL unresolveReviewThread mutation.
func (c *HTTPGitHubClient) unresolveThreadGraphQL(ctx context.Context, baseURL, token, threadNodeID string) error {
	mutation := `
mutation($threadID:ID!) {
  unresolveReviewThread(input:{threadId:$threadID}) {
    thread { id isResolved }
  }
}`
	vars := map[string]any{"threadID": threadNodeID}

	var resp struct {
		Data   json.RawMessage `json:"data"`
		Errors []struct{ Message string `json:"message"` } `json:"errors"`
	}
	if err := c.graphqlRequest(ctx, baseURL, token, mutation, vars, &resp); err != nil {
		return err
	}
	if len(resp.Errors) > 0 {
		return fmt.Errorf("graphql unresolveReviewThread: %s", resp.Errors[0].Message)
	}
	return nil
}

// graphqlRequest posts a GraphQL query/mutation to the GitHub GraphQL endpoint
// derived from the REST baseURL (e.g. https://api.github.com → https://api.github.com/graphql).
func (c *HTTPGitHubClient) graphqlRequest(ctx context.Context, baseURL, token, query string, variables map[string]any, out any) error {
	gqlURL := strings.TrimRight(baseURL, "/") + "/graphql"
	// api.github.com/graphql is the correct endpoint; normalise in case baseURL
	// already ends with /v3 or similar.
	gqlURL = strings.Replace(gqlURL, "/v3/graphql", "/graphql", 1)

	payload, err := json.Marshal(map[string]any{
		"query":     query,
		"variables": variables,
	})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, gqlURL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("graphql HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return json.NewDecoder(resp.Body).Decode(out)
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
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews", strings.TrimRight(baseURL, "/"), owner, repo, prNumber)

	// GitHub and Gitea use different field names for the line position.
	// GitHub: "line" + "side" (REST API for DraftPullRequestReviewComment).
	// Gitea:  "new_position" (Gitea review API).
	var comment map[string]any
	if strings.Contains(baseURL, "api.github.com") {
		comment = map[string]any{
			"path": strings.TrimPrefix(filePath, "/"),
			"line": bodyLine,
			"side": "RIGHT",
			"body": body,
		}
	} else {
		comment = map[string]any{
			"path":         strings.TrimPrefix(filePath, "/"),
			"new_position": bodyLine,
			"body":         body,
		}
	}

	payload, err := json.Marshal(map[string]any{
		"event":    "COMMENT",
		"comments": []map[string]any{comment},
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

// DeleteComment deletes a pull request review comment by its GitHub comment ID.
// The githubCommentID is the numeric comment ID extracted from the thread handle.
// GitHub API: DELETE /repos/{owner}/{repo}/pulls/comments/{comment_id}
// Gitea API:  DELETE /repos/{owner}/{repo}/issues/comments/{comment_id}  (same path structure)
func (c *HTTPGitHubClient) DeleteComment(ctx context.Context, githubCommentID string) error {
	repositoryID, _, commentID, ok := parseThreadHandle(githubCommentID)
	if !ok || commentID == "" {
		return fmt.Errorf("invalid thread handle for delete: %q", githubCommentID)
	}

	owner, repo, baseURL, token, err := c.resolve(repositoryID)
	if err != nil {
		return err
	}

	var deleteURL string
	if strings.Contains(baseURL, "api.github.com") {
		deleteURL = fmt.Sprintf("%s/repos/%s/%s/pulls/comments/%s", strings.TrimRight(baseURL, "/"), owner, repo, commentID)
	} else {
		// Gitea uses the issues/comments endpoint for PR review comments too.
		deleteURL = fmt.Sprintf("%s/repos/%s/%s/issues/comments/%s", strings.TrimRight(baseURL, "/"), owner, repo, commentID)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, deleteURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return fmt.Errorf("thread not found")
	}
	if resp.StatusCode != http.StatusNoContent {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("delete comment failed: %d %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return nil
}

func (c *HTTPGitHubClient) resolve(repositoryID string) (owner, repo, baseURL, token string, err error) {
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
