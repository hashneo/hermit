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
	ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, token string) ([]ReviewReadyRFCItem, error)
	GetRFCFromPullRequest(ctx context.Context, baseURL, owner, name string, prNumber int, filePath, token string) (DocumentView, error)
}

type ReviewReadyRFCItem struct {
	PRNumber int
	HeadSHA  string
	Title    string
	Path     string
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
		Name string `json:"name"`
		Path string `json:"path"`
		Type string `json:"type"`
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
			ID:    item.Path,
			Title: strings.TrimSuffix(item.Name, ".md"),
			Path:  item.Path,
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
		RenderedHTML:   markdownToHTMLWithFrontmatter(meta, body),
		MarkdownSource: markdown,
	}, nil
}

func (c *HTTPGitHubRFCClient) ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, token string) ([]ReviewReadyRFCItem, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	docsPath = strings.Trim(strings.TrimSpace(docsPath), "/")
	if docsPath == "" {
		docsPath = "docs-cms/rfcs"
	}

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
		Number int  `json:"number"`
		Draft  bool `json:"draft"`
		Head   struct {
			SHA string `json:"sha"`
		} `json:"head"`
	}
	if err := json.NewDecoder(prResp.Body).Decode(&pulls); err != nil {
		return nil, err
	}

	items := make([]ReviewReadyRFCItem, 0)
	for _, pr := range pulls {
		if pr.Draft {
			continue
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
				Title:    title,
				Path:     prFile.Filename,
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
