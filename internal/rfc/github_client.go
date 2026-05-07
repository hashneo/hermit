package rfc

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path"
	"sort"
	"strings"
)

type GitHubRFCClient interface {
	ListRFCs(ctx context.Context, baseURL, owner, name, branch, docsPath, token string) ([]CatalogItem, error)
	GetRFC(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (DocumentView, error)
	ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, rfcLabel, token string) ([]ReviewReadyRFCItem, error)
	GetRFCFromPullRequest(ctx context.Context, baseURL, owner, name string, prNumber int, filePath, token string) (DocumentView, error)

	// Write path — used by SubmitForReview.
	EnsureLabel(ctx context.Context, baseURL, owner, name, label, color, description, token string) error
	GetMainBranchSHA(ctx context.Context, baseURL, owner, name, branch, token string) (string, error)
	CreateBranch(ctx context.Context, baseURL, owner, name, branchName, fromSHA, token string) error
	CommitFile(ctx context.Context, baseURL, owner, name, branch, filePath, content, message, token string) (string, error)
	CreatePR(ctx context.Context, baseURL, owner, name, title, body, head, base string, labels []string, token string) (CreatedPR, error)
}

// CreatedPR is the minimal response from a PR creation call.
type CreatedPR struct {
	Number  int    `json:"number"`
	HTMLURL string `json:"html_url"`
	Title   string `json:"title"`
}

// RFCReadyLabel is the GitHub label that marks a PR as ready for RFC review.
const RFCReadyLabel = "hermit:rfc-ready"

type ReviewReadyRFCItem struct {
	PRNumber int
	HeadSHA  string
	HTMLURL  string
	Title    string
	Path     string
	Labels   []string
}

type HTTPGitHubRFCClient struct {
	client *http.Client
}

func NewHTTPGitHubRFCClient() *HTTPGitHubRFCClient {
	return &HTTPGitHubRFCClient{client: &http.Client{}}
}

func (c *HTTPGitHubRFCClient) ListRFCs(ctx context.Context, baseURL, owner, name, branch, docsPath, token string) ([]CatalogItem, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	docsPath = strings.Trim(strings.TrimSpace(docsPath), "/")
	if docsPath == "" {
		docsPath = "docs-cms/rfcs"
	}

	url := fmt.Sprintf("%s/repos/%s/%s/contents/%s?ref=%s", apiBase, owner, name, path.Clean(docsPath), branch)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	setGitHubHeaders(req, token)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("list RFCs failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload []struct {
		Name    string `json:"name"`
		Path    string `json:"path"`
		Type    string `json:"type"`
		HTMLURL string `json:"html_url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}

	items := make([]CatalogItem, 0)
	for _, item := range payload {
		if item.Type != "file" || !isDocuchangoRFCFilename(item.Name) {
			continue
		}
		items = append(items, CatalogItem{
			ID:      item.Path,
			Title:   strings.TrimSuffix(item.Name, ".md"),
			Path:    item.Path,
			HTMLURL: item.HTMLURL,
		})
	}

	return items, nil
}

func (c *HTTPGitHubRFCClient) GetRFC(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (DocumentView, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	url := fmt.Sprintf("%s/repos/%s/%s/contents/%s?ref=%s", apiBase, owner, name, path.Clean(strings.TrimPrefix(filePath, "/")), branch)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return DocumentView{}, err
	}
	setGitHubHeaders(req, token)

	resp, err := c.client.Do(req)
	if err != nil {
		return DocumentView{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return DocumentView{}, fmt.Errorf("get RFC failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload struct {
		Name    string `json:"name"`
		Path    string `json:"path"`
		Content string `json:"content"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return DocumentView{}, err
	}

	decoded, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(payload.Content, "\n", ""))
	if err != nil {
		return DocumentView{}, err
	}

	markdown := string(decoded)
	meta, body := parseFrontmatter(markdown)
	title := strings.TrimSpace(meta["title"])
	if title == "" {
		title = extractFirstHeading(body)
	}
	if title == "" {
		title = strings.TrimSuffix(payload.Name, ".md")
	}

	return DocumentView{
		ID:             payload.Path,
		Title:          title,
		Path:           payload.Path,
		MarkdownSource: markdown,
	}, nil
}

func (c *HTTPGitHubRFCClient) ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, rfcLabel, token string) ([]ReviewReadyRFCItem, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	docsPath = strings.Trim(strings.TrimSpace(docsPath), "/")
	if docsPath == "" {
		docsPath = "docs-cms/rfcs"
	}
	if rfcLabel == "" {
		rfcLabel = RFCReadyLabel
	}

	// Query open PRs then filter by label client-side.
	// Some providers (for example Gitea) do not support string label filters on this endpoint.
	prURL := fmt.Sprintf("%s/repos/%s/%s/pulls?state=open&per_page=100", apiBase, owner, name)
	prReq, err := http.NewRequestWithContext(ctx, http.MethodGet, prURL, nil)
	if err != nil {
		return nil, err
	}
	setGitHubHeaders(prReq, token)

	prResp, err := c.client.Do(prReq)
	if err != nil {
		return nil, err
	}
	defer prResp.Body.Close()

	if prResp.StatusCode < 200 || prResp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(prResp.Body, 2048))
		return nil, fmt.Errorf("list pull requests failed: %d %s", prResp.StatusCode, strings.TrimSpace(string(body)))
	}

	var pulls []struct {
		Number  int    `json:"number"`
		HTMLURL string `json:"html_url"`
		Draft   bool   `json:"draft"`
		Head    struct {
			SHA string `json:"sha"`
		} `json:"head"`
		Labels []struct {
			Name string `json:"name"`
		} `json:"labels"`
	}
	if err := json.NewDecoder(prResp.Body).Decode(&pulls); err != nil {
		return nil, err
	}

	items := make([]ReviewReadyRFCItem, 0)
	for _, pr := range pulls {
		if pr.Draft {
			continue
		}

		// Confirm the RFC-ready label is present in the decoded response.
		if !prHasLabel(pr.Labels, rfcLabel) {
			continue
		}

		labelNames := make([]string, 0, len(pr.Labels))
		for _, l := range pr.Labels {
			labelNames = append(labelNames, l.Name)
		}

		prFiles, err := c.listPullRequestFiles(ctx, apiBase, owner, name, pr.Number, token)
		if err != nil {
			return nil, err
		}

		for _, prFile := range prFiles {
			if !isRFCPathInDocs(prFile.Filename, docsPath) {
				continue
			}

			title := strings.TrimSuffix(path.Base(prFile.Filename), ".md")
			view, err := c.GetRFC(ctx, baseURL, owner, name, pr.Head.SHA, prFile.Filename, token)
			if err == nil {
				title = view.Title
			}

			items = append(items, ReviewReadyRFCItem{
				PRNumber: pr.Number,
				HeadSHA:  pr.Head.SHA,
				HTMLURL:  pr.HTMLURL,
				Title:    title,
				Path:     prFile.Filename,
				Labels:   labelNames,
			})
		}
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].PRNumber == items[j].PRNumber {
			return items[i].Path < items[j].Path
		}
		return items[i].PRNumber < items[j].PRNumber
	})

	return items, nil
}

func (c *HTTPGitHubRFCClient) GetRFCFromPullRequest(ctx context.Context, baseURL, owner, name string, prNumber int, filePath, token string) (DocumentView, error) {
	apiBase := strings.TrimRight(baseURL, "/")

	prURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d", apiBase, owner, name, prNumber)
	prReq, err := http.NewRequestWithContext(ctx, http.MethodGet, prURL, nil)
	if err != nil {
		return DocumentView{}, err
	}
	setGitHubHeaders(prReq, token)

	prResp, err := c.client.Do(prReq)
	if err != nil {
		return DocumentView{}, err
	}
	defer prResp.Body.Close()

	if prResp.StatusCode < 200 || prResp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(prResp.Body, 2048))
		return DocumentView{}, fmt.Errorf("get pull request failed: %d %s", prResp.StatusCode, strings.TrimSpace(string(body)))
	}

	var pull struct {
		Head struct {
			SHA string `json:"sha"`
		} `json:"head"`
	}
	if err := json.NewDecoder(prResp.Body).Decode(&pull); err != nil {
		return DocumentView{}, err
	}

	prFiles, err := c.listPullRequestFiles(ctx, apiBase, owner, name, prNumber, token)
	if err != nil {
		return DocumentView{}, err
	}

	requestedPath := strings.Trim(strings.TrimSpace(filePath), "/")
	allowed := false
	for _, prFile := range prFiles {
		if strings.Trim(strings.TrimSpace(prFile.Filename), "/") == requestedPath {
			allowed = true
			break
		}
	}
	if !allowed {
		return DocumentView{}, fmt.Errorf("rfc file not found in pull request")
	}

	return c.GetRFC(ctx, baseURL, owner, name, pull.Head.SHA, requestedPath, token)
}

func (c *HTTPGitHubRFCClient) listPullRequestFiles(ctx context.Context, apiBase, owner, name string, prNumber int, token string) ([]struct {
	Filename string `json:"filename"`
	Status   string `json:"status"`
}, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/files?per_page=100", apiBase, owner, name, prNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	setGitHubHeaders(req, token)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("list pull request files failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var files []struct {
		Filename string `json:"filename"`
		Status   string `json:"status"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&files); err != nil {
		return nil, err
	}

	return files, nil
}

// EnsureLabel creates the label on the repo if it does not already exist.
// A 422 response (label already exists on GitHub) is treated as success.
func (c *HTTPGitHubRFCClient) EnsureLabel(ctx context.Context, baseURL, owner, name, label, color, description, token string) error {
	apiBase := strings.TrimRight(baseURL, "/")

	// Check whether the label already exists.
	checkURL := fmt.Sprintf("%s/repos/%s/%s/labels/%s", apiBase, owner, name, label)
	checkReq, err := http.NewRequestWithContext(ctx, http.MethodGet, checkURL, nil)
	if err != nil {
		return err
	}
	setGitHubHeaders(checkReq, token)
	checkResp, err := c.client.Do(checkReq)
	if err != nil {
		return err
	}
	defer checkResp.Body.Close()
	io.Copy(io.Discard, checkResp.Body) //nolint:errcheck
	if checkResp.StatusCode == http.StatusOK {
		return nil // already exists
	}

	// Create it.
	if color == "" {
		color = "0075ca" // GitHub's default blue
	}
	createBody, _ := json.Marshal(map[string]string{
		"name":        label,
		"color":       color,
		"description": description,
	})
	createURL := fmt.Sprintf("%s/repos/%s/%s/labels", apiBase, owner, name)
	createReq, err := http.NewRequestWithContext(ctx, http.MethodPost, createURL, strings.NewReader(string(createBody)))
	if err != nil {
		return err
	}
	setGitHubHeaders(createReq, token)
	createReq.Header.Set("Content-Type", "application/json")
	createResp, err := c.client.Do(createReq)
	if err != nil {
		return err
	}
	defer createResp.Body.Close()
	io.Copy(io.Discard, createResp.Body) //nolint:errcheck
	// 201 = created, 422 = already exists (race) — both are fine.
	if createResp.StatusCode != http.StatusCreated && createResp.StatusCode != http.StatusUnprocessableEntity {
		return fmt.Errorf("create label failed: %d", createResp.StatusCode)
	}
	return nil
}

// GetMainBranchSHA returns the HEAD SHA of the given branch.
func (c *HTTPGitHubRFCClient) GetMainBranchSHA(ctx context.Context, baseURL, owner, name, branch, token string) (string, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/git/refs/heads/%s", apiBase, owner, name, branch)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", fmt.Errorf("get branch SHA failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ref); err != nil {
		return "", err
	}
	return ref.Object.SHA, nil
}

// CreateBranch creates a new branch from an existing SHA.
func (c *HTTPGitHubRFCClient) CreateBranch(ctx context.Context, baseURL, owner, name, branchName, fromSHA, token string) error {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/git/refs", apiBase, owner, name)
	payload, _ := json.Marshal(map[string]string{
		"ref": "refs/heads/" + branchName,
		"sha": fromSHA,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(string(payload)))
	if err != nil {
		return err
	}
	setGitHubHeaders(req, token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
	if resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("create branch failed: %d", resp.StatusCode)
	}
	return nil
}

// CommitFile creates or updates a file on a branch via the GitHub Contents API.
// Returns the commit SHA.
func (c *HTTPGitHubRFCClient) CommitFile(ctx context.Context, baseURL, owner, name, branch, filePath, content, message, token string) (string, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	cleanPath := strings.TrimPrefix(filePath, "/")

	// Supply the blob SHA if the file already exists (required for updates).
	var existingSHA string
	getURL := fmt.Sprintf("%s/repos/%s/%s/contents/%s?ref=%s", apiBase, owner, name, cleanPath, branch)
	getReq, err := http.NewRequestWithContext(ctx, http.MethodGet, getURL, nil)
	if err != nil {
		return "", err
	}
	setGitHubHeaders(getReq, token)
	getResp, err := c.client.Do(getReq)
	if err != nil {
		return "", err
	}
	defer getResp.Body.Close()
	if getResp.StatusCode == http.StatusOK {
		var existing struct {
			SHA string `json:"sha"`
		}
		if jsonErr := json.NewDecoder(getResp.Body).Decode(&existing); jsonErr == nil {
			existingSHA = existing.SHA
		}
	} else {
		io.Copy(io.Discard, getResp.Body) //nolint:errcheck
	}

	payloadMap := map[string]string{
		"message": message,
		"content": base64.StdEncoding.EncodeToString([]byte(content)),
		"branch":  branch,
	}
	if existingSHA != "" {
		payloadMap["sha"] = existingSHA
	}
	payloadBytes, _ := json.Marshal(payloadMap)

	putURL := fmt.Sprintf("%s/repos/%s/%s/contents/%s", apiBase, owner, name, cleanPath)
	putReq, err := http.NewRequestWithContext(ctx, http.MethodPut, putURL, strings.NewReader(string(payloadBytes)))
	if err != nil {
		return "", err
	}
	setGitHubHeaders(putReq, token)
	putReq.Header.Set("Content-Type", "application/json")
	putResp, err := c.client.Do(putReq)
	if err != nil {
		return "", err
	}
	defer putResp.Body.Close()
	if putResp.StatusCode != http.StatusOK && putResp.StatusCode != http.StatusCreated {
		b, _ := io.ReadAll(io.LimitReader(putResp.Body, 2048))
		return "", fmt.Errorf("commit file failed: %d %s", putResp.StatusCode, strings.TrimSpace(string(b)))
	}
	var result struct {
		Commit struct {
			SHA string `json:"sha"`
		} `json:"commit"`
	}
	if err := json.NewDecoder(putResp.Body).Decode(&result); err != nil {
		return "", err
	}
	return result.Commit.SHA, nil
}

// CreatePR opens a pull request and applies the given labels via the Issues API.
func (c *HTTPGitHubRFCClient) CreatePR(ctx context.Context, baseURL, owner, name, title, body, head, base string, labels []string, token string) (CreatedPR, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	payload, _ := json.Marshal(map[string]any{
		"title": title,
		"body":  body,
		"head":  head,
		"base":  base,
	})
	prURL := fmt.Sprintf("%s/repos/%s/%s/pulls", apiBase, owner, name)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, prURL, strings.NewReader(string(payload)))
	if err != nil {
		return CreatedPR{}, err
	}
	setGitHubHeaders(req, token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		return CreatedPR{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return CreatedPR{}, fmt.Errorf("create PR failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var pr struct {
		Number  int    `json:"number"`
		HTMLURL string `json:"html_url"`
		Title   string `json:"title"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return CreatedPR{}, err
	}

	// Apply labels via the Issues API (GitHub PRs are issues).
	if len(labels) > 0 {
		labelsPayload, _ := json.Marshal(map[string]any{"labels": labels})
		labelsURL := fmt.Sprintf("%s/repos/%s/%s/issues/%d/labels", apiBase, owner, name, pr.Number)
		lReq, lErr := http.NewRequestWithContext(ctx, http.MethodPost, labelsURL, strings.NewReader(string(labelsPayload)))
		if lErr == nil {
			setGitHubHeaders(lReq, token)
			lReq.Header.Set("Content-Type", "application/json")
			if lResp, lErr := c.client.Do(lReq); lErr == nil {
				io.Copy(io.Discard, lResp.Body) //nolint:errcheck
				lResp.Body.Close()
			}
		}
	}

	return CreatedPR{Number: pr.Number, HTMLURL: pr.HTMLURL, Title: pr.Title}, nil
}

func prHasLabel(labels []struct{ Name string `json:"name"` }, target string) bool {
	for _, l := range labels {
		if l.Name == target {
			return true
		}
	}
	return false
}

func isRFCPathInDocs(filePath, docsPath string) bool {
	normalizedPath := strings.Trim(strings.TrimSpace(filePath), "/")
	normalizedDocsPath := strings.Trim(strings.TrimSpace(docsPath), "/")
	if normalizedDocsPath == "" {
		normalizedDocsPath = "docs-cms/rfcs"
	}

	if !strings.HasPrefix(normalizedPath, normalizedDocsPath+"/") {
		return false
	}

	return isDocuchangoRFCFilename(path.Base(normalizedPath))
}

func setGitHubHeaders(req *http.Request, token string) {
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
}
