package rfc

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"
)

type GitHubRFCClient interface {
	ListRFCs(ctx context.Context, baseURL, owner, name, branch, docsPath, token string) ([]CatalogItem, error)
	GetRFC(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (DocumentView, error)
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

func setGitHubHeaders(req *http.Request, token string) {
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
}
