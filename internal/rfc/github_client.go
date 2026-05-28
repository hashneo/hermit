package rfc

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type GitHubRFCClient interface {
	ListRFCs(ctx context.Context, baseURL, owner, name, branch, docsPath, token string) ([]CatalogItem, error)
	GetRFC(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (DocumentView, error)
	ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, rfcLabel, token string) ([]ReviewReadyRFCItem, error)
	GetRFCFromPullRequest(ctx context.Context, baseURL, owner, name string, prNumber int, filePath, token string) (DocumentView, error)

	// Write path — used by SubmitForReview and AcceptRFC.
	EnsureLabel(ctx context.Context, baseURL, owner, name, label, color, description, token string) error
	GetMainBranchSHA(ctx context.Context, baseURL, owner, name, branch, token string) (string, error)
	CreateBranch(ctx context.Context, baseURL, owner, name, branchName, fromSHA, token string) error
	CommitFile(ctx context.Context, baseURL, owner, name, branch, filePath, content, message, token string) (string, error)
	CreatePR(ctx context.Context, baseURL, owner, name, title, body, head, base string, labels []string, token string) (CreatedPR, error)

	// Accept path — rewrite status, merge PR, poll CI.
	GetPRHeadRef(ctx context.Context, baseURL, owner, name string, prNumber int, token string) (headRef string, err error)
	GetPRHead(ctx context.Context, baseURL, owner, name string, prNumber int, token string) (headRef, headSHA string, err error)
	CommitFileOnBranch(ctx context.Context, baseURL, owner, name, branch, filePath, content, message, token string) (sha string, err error)
	MergePR(ctx context.Context, baseURL, owner, name string, prNumber int, token string) (merged bool, blockedByCI bool, err error)
	GetCIStatus(ctx context.Context, baseURL, owner, name, commitSHA, token string) (status string, err error) // "pending" | "success" | "failure"
	// DismissBotReviews dismisses any pending or approved reviews submitted by bot accounts
	// (login suffix "[bot]") on the given PR. This prevents copilot/automation reviews from
	// blocking a merge after the RFC has been accepted. Non-bot reviews are left untouched.
	DismissBotReviews(ctx context.Context, baseURL, owner, name string, prNumber int, token string) error
	// DismissHumanRequestChangesReviews dismisses all CHANGES_REQUESTED reviews from human
	// accounts (i.e. not ending in "[bot]"). Called during AcceptRFC so that outstanding
	// reviewer objections are cleared before the squash-merge.
	DismissHumanRequestChangesReviews(ctx context.Context, baseURL, owner, name string, prNumber int, token string) error

	// Ironhide path — check whether labels exist on the repo, then apply them to a PR.
	// LabelExists returns true when the label is already defined on the repository.
	LabelExists(ctx context.Context, baseURL, owner, name, label, token string) (bool, error)
	// AddLabels appends labels to a pull request (issues API).
	AddLabels(ctx context.Context, baseURL, owner, name string, prNumber int, labels []string, token string) error

	// Access control — returns "admin", "maintain", "write", "triage", "read", or "none".
	GetCollaboratorPermission(ctx context.Context, baseURL, owner, name, username, token string) (string, error)
	// GetAuthenticatedUser returns the GitHub login for the token owner.
	GetAuthenticatedUser(ctx context.Context, baseURL, token string) (string, error)

	// Lifecycle transitions on main-branch RFCs.
	ApproveRFCFile(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (string, error)
	MarkRFCFileImplemented(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (string, error)
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
	HeadRef  string
	HTMLURL  string
	Title    string
	Path     string
	Labels   []string
}

type HTTPGitHubRFCClient struct {
	client *http.Client
}

func NewHTTPGitHubRFCClient() *HTTPGitHubRFCClient {
	return &HTTPGitHubRFCClient{client: &http.Client{Timeout: 20 * time.Second}}
}

func (c *HTTPGitHubRFCClient) ListRFCs(ctx context.Context, baseURL, owner, name, branch, docsPath, token string) ([]CatalogItem, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	if items, ok, err := c.listDocuchangoProjectRFCs(ctx, apiBase, owner, name, branch, token); err != nil {
		return nil, err
	} else if ok {
		return items, nil
	}

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
	rfcRoots, rfcPatterns, ok, err := c.docuchangoRFCPaths(ctx, apiBase, owner, name, "", token)
	if err != nil {
		return nil, err
	}
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
			Ref string `json:"ref"`
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

		// Pick the single RFC file with the most additions — this is the primary RFC
		// being introduced or substantially revised by this PR. Other RFC files in
		// the diff are incidental edits (e.g. index.md, changelog, status bumps).
		// Fall back to the first matching file when additions are equal (e.g. in tests).
		var primaryFile struct {
			Filename  string
			Additions int
		}
		for _, prFile := range prFiles {
			if ok {
				if !isRFCPathInDocuchangoProject(prFile.Filename, rfcRoots, rfcPatterns) {
					continue
				}
			} else if !isRFCPathInDocs(prFile.Filename, docsPath) {
				continue
			}
			if primaryFile.Filename == "" || prFile.Additions > primaryFile.Additions {
				primaryFile.Filename = prFile.Filename
				primaryFile.Additions = prFile.Additions
			}
		}
		if primaryFile.Filename == "" {
			continue // no RFC file in this PR
		}

		title := strings.TrimSuffix(path.Base(primaryFile.Filename), ".md")
		view, err := c.GetRFC(ctx, baseURL, owner, name, pr.Head.SHA, primaryFile.Filename, token)
		if err == nil {
			title = view.Title
		}

		items = append(items, ReviewReadyRFCItem{
			PRNumber: pr.Number,
			HeadSHA:  pr.Head.SHA,
			HeadRef:  pr.Head.Ref,
			HTMLURL:  pr.HTMLURL,
			Title:    title,
			Path:     primaryFile.Filename,
			Labels:   labelNames,
		})
	}

	sort.Slice(items, func(i, j int) bool {
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
		User struct {
			Login string `json:"login"`
		} `json:"user"`
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

	view, err := c.GetRFC(ctx, baseURL, owner, name, pull.Head.SHA, requestedPath, token)
	if err != nil {
		return DocumentView{}, err
	}
	view.PRAuthorLogin = pull.User.Login
	return view, nil
}

func (c *HTTPGitHubRFCClient) listPullRequestFiles(ctx context.Context, apiBase, owner, name string, prNumber int, token string) ([]struct {
	Filename  string `json:"filename"`
	Status    string `json:"status"`
	Additions int    `json:"additions"`
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
		Filename  string `json:"filename"`
		Status    string `json:"status"`
		Additions int    `json:"additions"`
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

type docuchangoProjectConfig struct {
	Project struct {
		ID   string `yaml:"id"`
		Name string `yaml:"name"`
	} `yaml:"project"`
	Structure struct {
		RFCDir       string                       `yaml:"rfc_dir"`
		DocsRoots    []string                     `yaml:"docs_roots"`
		DocTypes     map[string]docuchangoDocType `yaml:"doc_types"`
		DocumentDirs []string                     `yaml:"document_folders"`
	} `yaml:"structure"`
	Indexes     []docuchangoIndex      `yaml:"indexes"`
	Subprojects []docuchangoSubproject `yaml:"subprojects"`
	Security    struct {
		AllowExternalPaths bool `yaml:"allow_external_paths"`
	} `yaml:"security"`
}

type docuchangoDocType struct {
	Schema  string   `yaml:"schema"`
	Folders []string `yaml:"folders"`
}

type docuchangoIndex struct {
	Targets []string `yaml:"targets"`
}

type docuchangoSubproject struct {
	Path string `yaml:"path"`
}

func (s *docuchangoSubproject) UnmarshalYAML(value *yaml.Node) error {
	if value.Kind == yaml.ScalarNode {
		return value.Decode(&s.Path)
	}
	type alias docuchangoSubproject
	var out alias
	if err := value.Decode(&out); err != nil {
		return err
	}
	s.Path = out.Path
	return nil
}

type docuchangoProjectContext struct {
	config docuchangoProjectConfig
	path   string
	base   string
}

func (c *HTTPGitHubRFCClient) listDocuchangoProjectRFCs(ctx context.Context, apiBase, owner, name, branch, token string) ([]CatalogItem, bool, error) {
	contexts, ok, err := c.loadDocuchangoProjectContexts(ctx, apiBase, owner, name, branch, token)
	if err != nil || !ok {
		return nil, ok, err
	}

	seen := map[string]struct{}{}
	items := make([]CatalogItem, 0)
	for _, root := range rfcRootsFromDocuchangoContexts(contexts) {
		paths, err := c.listMarkdownFiles(ctx, apiBase, owner, name, branch, root, token)
		if err != nil {
			return nil, true, err
		}
		for _, filePath := range paths {
			if !isDocuchangoRFCFilename(path.Base(filePath)) {
				continue
			}
			if _, ok := seen[filePath]; ok {
				continue
			}
			seen[filePath] = struct{}{}
			items = append(items, CatalogItem{ID: filePath, Title: strings.TrimSuffix(path.Base(filePath), ".md"), Path: filePath})
		}
	}

	for _, target := range indexTargetsFromDocuchangoContexts(contexts) {
		prefix := globLiteralPrefix(target)
		if prefix == "" {
			continue
		}
		paths, err := c.listMarkdownFiles(ctx, apiBase, owner, name, branch, prefix, token)
		if err != nil {
			return nil, true, err
		}
		for _, filePath := range paths {
			if !isDocuchangoRFCFilename(path.Base(filePath)) || !matchDocuchangoGlob(target, filePath) {
				continue
			}
			if _, ok := seen[filePath]; ok {
				continue
			}
			seen[filePath] = struct{}{}
			items = append(items, CatalogItem{ID: filePath, Title: strings.TrimSuffix(path.Base(filePath), ".md"), Path: filePath})
		}
	}

	sort.Slice(items, func(i, j int) bool { return items[i].Path < items[j].Path })
	return items, true, nil
}

func (c *HTTPGitHubRFCClient) docuchangoRFCPaths(ctx context.Context, apiBase, owner, name, branch, token string) ([]string, []string, bool, error) {
	contexts, ok, err := c.loadDocuchangoProjectContexts(ctx, apiBase, owner, name, branch, token)
	if err != nil || !ok {
		return nil, nil, ok, err
	}
	return rfcRootsFromDocuchangoContexts(contexts), indexTargetsFromDocuchangoContexts(contexts), true, nil
}

func (c *HTTPGitHubRFCClient) loadDocuchangoProjectContexts(ctx context.Context, apiBase, owner, name, branch, token string) ([]docuchangoProjectContext, bool, error) {
	if branch == "" {
		branch = "HEAD"
	}
	rootCandidates := []string{"docs-project.yaml", "docs-cms/docs-project.yaml", "docs/docs-project.yaml"}
	var root docuchangoProjectContext
	found := false
	for _, candidate := range rootCandidates {
		config, err := c.getDocuchangoProjectConfig(ctx, apiBase, owner, name, branch, candidate, token)
		if err != nil {
			return nil, false, err
		}
		if config == nil {
			continue
		}
		root = docuchangoProjectContext{config: *config, path: candidate, base: path.Dir(candidate)}
		if root.base == "." {
			root.base = ""
		}
		found = true
		break
	}
	if !found {
		return nil, false, nil
	}

	contexts := []docuchangoProjectContext{root}
	seen := map[string]struct{}{root.path: {}}
	for i := 0; i < len(contexts); i++ {
		parent := contexts[i]
		for _, subproject := range parent.config.Subprojects {
			subPath := resolveDocuchangoConfigPath(parent.base, subproject.Path, parent.config.Security.AllowExternalPaths)
			if subPath == "" {
				continue
			}
			candidates := []string{subPath}
			if path.Base(subPath) != "docs-project.yaml" {
				candidates = []string{path.Join(subPath, "docs-project.yaml")}
			}
			for _, candidate := range candidates {
				if _, ok := seen[candidate]; ok {
					continue
				}
				config, err := c.getDocuchangoProjectConfig(ctx, apiBase, owner, name, branch, candidate, token)
				if err != nil {
					return nil, false, err
				}
				if config == nil {
					continue
				}
				base := path.Dir(candidate)
				if base == "." {
					base = ""
				}
				seen[candidate] = struct{}{}
				contexts = append(contexts, docuchangoProjectContext{config: *config, path: candidate, base: base})
			}
		}
	}

	return contexts, true, nil
}

func (c *HTTPGitHubRFCClient) getDocuchangoProjectConfig(ctx context.Context, apiBase, owner, name, branch, filePath, token string) (*docuchangoProjectConfig, error) {
	content, ok, err := c.getRepositoryFile(ctx, apiBase, owner, name, branch, filePath, token)
	if err != nil || !ok {
		return nil, err
	}
	var config docuchangoProjectConfig
	if err := yaml.Unmarshal([]byte(content), &config); err != nil {
		return nil, fmt.Errorf("parse Docuchango project config %s: %w", filePath, err)
	}
	if strings.TrimSpace(config.Project.ID) == "" || strings.TrimSpace(config.Project.Name) == "" {
		return nil, nil
	}
	return &config, nil
}

func (c *HTTPGitHubRFCClient) getRepositoryFile(ctx context.Context, apiBase, owner, name, branch, filePath, token string) (string, bool, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/contents/%s?ref=%s", apiBase, owner, name, path.Clean(strings.Trim(filePath, "/")), url.QueryEscape(branch))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", false, err
	}
	setGitHubHeaders(req, token)

	resp, err := c.client.Do(req)
	if err != nil {
		return "", false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		return "", false, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", false, fmt.Errorf("get repository file failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var raw json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return "", false, err
	}
	if len(raw) > 0 && raw[0] == '[' {
		return "", false, nil
	}

	var payload struct {
		Content string `json:"content"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", false, err
	}
	if strings.TrimSpace(payload.Content) == "" {
		return "", false, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(payload.Content, "\n", ""))
	if err != nil {
		return "", false, err
	}
	return string(decoded), true, nil
}

func (c *HTTPGitHubRFCClient) listMarkdownFiles(ctx context.Context, apiBase, owner, name, branch, dirPath, token string) ([]string, error) {
	dirPath = strings.Trim(path.Clean(strings.Trim(dirPath, "/")), "/")
	url := fmt.Sprintf("%s/repos/%s/%s/contents/%s?ref=%s", apiBase, owner, name, dirPath, url.QueryEscape(branch))
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
	if resp.StatusCode == http.StatusNotFound {
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		return nil, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("list markdown files failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload []struct {
		Path string `json:"path"`
		Type string `json:"type"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}

	var files []string
	for _, item := range payload {
		switch item.Type {
		case "file":
			if strings.HasSuffix(item.Path, ".md") {
				files = append(files, item.Path)
			}
		case "dir":
			childFiles, err := c.listMarkdownFiles(ctx, apiBase, owner, name, branch, item.Path, token)
			if err != nil {
				return nil, err
			}
			files = append(files, childFiles...)
		}
	}
	return files, nil
}

func rfcRootsFromDocuchangoContexts(contexts []docuchangoProjectContext) []string {
	seen := map[string]struct{}{}
	var roots []string
	for _, context := range contexts {
		if len(context.config.Structure.DocTypes) > 0 {
			docsRoots := context.config.Structure.DocsRoots
			if len(docsRoots) == 0 {
				docsRoots = []string{"."}
			}
			for name, docType := range context.config.Structure.DocTypes {
				if name != "rfc" && docType.Schema != "rfc" {
					continue
				}
				for _, docsRoot := range docsRoots {
					for _, folder := range docType.Folders {
						root := resolveDocuchangoConfigPath(path.Join(context.base, docsRoot), folder, context.config.Security.AllowExternalPaths)
						if root == "" {
							continue
						}
						if _, ok := seen[root]; !ok {
							seen[root] = struct{}{}
							roots = append(roots, root)
						}
					}
				}
			}
			continue
		}

		rfcDir := strings.TrimSpace(context.config.Structure.RFCDir)
		if rfcDir == "" {
			rfcDir = "rfcs"
		}
		root := resolveDocuchangoConfigPath(context.base, rfcDir, context.config.Security.AllowExternalPaths)
		if root == "" {
			continue
		}
		if _, ok := seen[root]; !ok {
			seen[root] = struct{}{}
			roots = append(roots, root)
		}
	}
	return roots
}

func indexTargetsFromDocuchangoContexts(contexts []docuchangoProjectContext) []string {
	seen := map[string]struct{}{}
	var targets []string
	for _, context := range contexts {
		for _, index := range context.config.Indexes {
			for _, target := range index.Targets {
				resolved := resolveDocuchangoConfigPath(context.base, target, context.config.Security.AllowExternalPaths)
				if resolved == "" {
					continue
				}
				if _, ok := seen[resolved]; !ok {
					seen[resolved] = struct{}{}
					targets = append(targets, resolved)
				}
			}
		}
	}
	return targets
}

func resolveDocuchangoConfigPath(base, rel string, allowExternal bool) string {
	rel = strings.Trim(strings.TrimSpace(rel), "/")
	if rel == "" || rel == "." {
		return strings.Trim(path.Clean(base), "/")
	}
	if !allowExternal && (rel == ".." || strings.HasPrefix(rel, "../") || strings.Contains(rel, "/../")) {
		return ""
	}
	joined := path.Clean(path.Join(base, rel))
	if joined == "." {
		return ""
	}
	return strings.Trim(joined, "/")
}

func globLiteralPrefix(pattern string) string {
	idx := strings.IndexAny(pattern, "*?[")
	if idx == -1 {
		return path.Dir(pattern)
	}
	prefix := pattern[:idx]
	prefix = strings.TrimSuffix(prefix, "/")
	if strings.HasSuffix(prefix, ".md") {
		prefix = path.Dir(prefix)
	}
	return strings.Trim(path.Clean(prefix), "/")
}

func matchDocuchangoGlob(pattern, filePath string) bool {
	matched, err := path.Match(pattern, filePath)
	if err == nil && matched {
		return true
	}
	if strings.Contains(pattern, "**") {
		parts := strings.Split(pattern, "**")
		if !strings.HasPrefix(filePath, parts[0]) {
			return false
		}
		suffix := strings.TrimPrefix(parts[len(parts)-1], "/")
		if suffix == "*.md" {
			return strings.HasSuffix(filePath, ".md")
		}
		return strings.HasSuffix(filePath, suffix)
	}
	return false
}

func isRFCPathInDocuchangoProject(filePath string, roots, patterns []string) bool {
	normalizedPath := strings.Trim(strings.TrimSpace(filePath), "/")
	if !isDocuchangoRFCFilename(path.Base(normalizedPath)) {
		return false
	}
	for _, root := range roots {
		root = strings.Trim(strings.TrimSpace(root), "/")
		if root != "" && strings.HasPrefix(normalizedPath, root+"/") {
			return true
		}
	}
	for _, pattern := range patterns {
		if matchDocuchangoGlob(pattern, normalizedPath) {
			return true
		}
	}
	return false
}

func prHasLabel(labels []struct {
	Name string `json:"name"`
}, target string) bool {
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

// GetPRHeadRef returns the head branch name and head commit SHA for the given PR number.
func (c *HTTPGitHubRFCClient) GetPRHeadRef(ctx context.Context, baseURL, owner, name string, prNumber int, token string) (string, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d", apiBase, owner, name, prNumber)
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
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", fmt.Errorf("get PR failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var pr struct {
		Head struct {
			Ref string `json:"ref"`
			SHA string `json:"sha"`
		} `json:"head"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return "", err
	}
	return pr.Head.Ref, nil
}

// GetPRHead returns both the head branch ref and head commit SHA for a PR.
func (c *HTTPGitHubRFCClient) GetPRHead(ctx context.Context, baseURL, owner, name string, prNumber int, token string) (ref, sha string, err error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d", apiBase, owner, name, prNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", "", err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", "", fmt.Errorf("get PR failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var pr struct {
		Head struct {
			Ref string `json:"ref"`
			SHA string `json:"sha"`
		} `json:"head"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return "", "", err
	}
	return pr.Head.Ref, pr.Head.SHA, nil
}

// CommitFileOnBranch commits content to filePath on branch, returning the new commit SHA.
func (c *HTTPGitHubRFCClient) CommitFileOnBranch(ctx context.Context, baseURL, owner, name, branch, filePath, content, message, token string) (string, error) {
	return c.CommitFile(ctx, baseURL, owner, name, branch, filePath, content, message, token)
}

// MergePR merges the PR using the first merge method accepted by the repository.
//
// Methods are tried in preference order: merge → squash → rebase.
// A 405 with "not allowed" in the body means the method is disabled on the
// repository — the next method is tried.  A 405 without "not allowed" signals
// a branch-protection block (pending CI, unresolved conversations, etc.) and
// is returned as merged=false, blockedByCI=true without further retries.
//
// Returns:
//   - merged=true, blockedByCI=false on success
//   - merged=false, blockedByCI=true when GitHub rejects with 405 for a non-method reason
//   - error for other failures, including unresolved conversations or exhausted methods
func (c *HTTPGitHubRFCClient) MergePR(ctx context.Context, baseURL, owner, name string, prNumber int, token string) (bool, bool, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/merge", apiBase, owner, name, prNumber)

	// Try merge methods in order.  "merge" (merge commit) is attempted first
	// because it is the most widely enabled method; "squash" is common but some
	// repositories disable it; "rebase" is a valid fallback.
	methods := []string{"merge", "squash", "rebase"}
	for _, method := range methods {
		payload, err := json.Marshal(map[string]string{"merge_method": method})
		if err != nil {
			return false, false, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPut, u, strings.NewReader(string(payload)))
		if err != nil {
			return false, false, err
		}
		setGitHubHeaders(req, token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := c.client.Do(req)
		if err != nil {
			return false, false, err
		}
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()

		switch resp.StatusCode {
		case http.StatusOK, http.StatusCreated:
			return true, false, nil
		case http.StatusMethodNotAllowed:
			msg := strings.ToLower(strings.TrimSpace(string(b)))
			if strings.Contains(msg, "conversation") || strings.Contains(msg, "unresolved") {
				return false, false, fmt.Errorf("merge blocked: unresolved review conversations must be resolved before merging")
			}
			if strings.Contains(msg, "not allowed") {
				// This specific merge method is disabled on the repository; try the next one.
				continue
			}
			// Some other branch-protection block (required checks, approvals, etc.)
			return false, true, nil
		case http.StatusConflict:
			return false, false, fmt.Errorf("merge conflict: %s", strings.TrimSpace(string(b)))
		default:
			return false, false, fmt.Errorf("merge PR failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
		}
	}
	// All three methods returned 405 "not allowed".
	return false, false, fmt.Errorf("merge PR failed: no merge method is enabled on this repository (tried merge, squash, rebase)")
}

// DismissBotReviews lists all reviews on the PR and dismisses any submitted by bot
// accounts (login ends with "[bot]"). The dismiss message explains that the RFC was
// accepted and the automated review is no longer relevant.
// Non-bot reviews and reviews in a state that cannot be dismissed (e.g. COMMENTED) are
// skipped silently.
func (c *HTTPGitHubRFCClient) DismissBotReviews(ctx context.Context, baseURL, owner, name string, prNumber int, token string) error {
	apiBase := strings.TrimRight(baseURL, "/")

	// 1. List all reviews for the PR.
	listURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews", apiBase, owner, name, prNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, listURL, nil)
	if err != nil {
		return err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("list reviews failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	var reviews []struct {
		ID    int64  `json:"id"`
		State string `json:"state"` // APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING
		User  struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&reviews); err != nil {
		return fmt.Errorf("decode reviews: %w", err)
	}

	// 2. Dismiss any bot reviews that are in a dismissible state (APPROVED or CHANGES_REQUESTED).
	for _, r := range reviews {
		if !strings.HasSuffix(r.User.Login, "[bot]") {
			continue
		}
		if r.State != "APPROVED" && r.State != "CHANGES_REQUESTED" {
			continue
		}
		dismissURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews/%d/dismissals", apiBase, owner, name, prNumber, r.ID)
		body, _ := json.Marshal(map[string]string{
			"message": "RFC accepted — automated review dismissed.",
		})
		dreq, err := http.NewRequestWithContext(ctx, http.MethodPut, dismissURL, strings.NewReader(string(body)))
		if err != nil {
			return err
		}
		setGitHubHeaders(dreq, token)
		dreq.Header.Set("Content-Type", "application/json")
		dresp, err := c.client.Do(dreq)
		if err != nil {
			return err
		}
		dresp.Body.Close()
		// 200 = dismissed; anything else we surface as an error.
		if dresp.StatusCode != http.StatusOK {
			return fmt.Errorf("dismiss review %d (user %s) failed: %d", r.ID, r.User.Login, dresp.StatusCode)
		}
	}
	return nil
}

// DismissHumanRequestChangesReviews dismisses all CHANGES_REQUESTED reviews from human
// accounts (not bots) on the given PR. Called during AcceptRFC so that reviewer
// objections that were formally addressed are cleared before the squash-merge.
func (c *HTTPGitHubRFCClient) DismissHumanRequestChangesReviews(ctx context.Context, baseURL, owner, name string, prNumber int, token string) error {
	apiBase := strings.TrimRight(baseURL, "/")

	// List all reviews.
	listURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews", apiBase, owner, name, prNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, listURL, nil)
	if err != nil {
		return err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("list reviews failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	var reviews []struct {
		ID    int64  `json:"id"`
		State string `json:"state"`
		User  struct {
			Login string `json:"login"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&reviews); err != nil {
		return fmt.Errorf("decode reviews: %w", err)
	}

	for _, r := range reviews {
		// Skip bots — those are handled by DismissBotReviews.
		if strings.HasSuffix(r.User.Login, "[bot]") {
			continue
		}
		if r.State != "CHANGES_REQUESTED" {
			continue
		}
		dismissURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/reviews/%d/dismissals", apiBase, owner, name, prNumber, r.ID)
		body, _ := json.Marshal(map[string]string{
			"message": "RFC accepted — changes requested review dismissed.",
		})
		dreq, err := http.NewRequestWithContext(ctx, http.MethodPut, dismissURL, strings.NewReader(string(body)))
		if err != nil {
			return err
		}
		setGitHubHeaders(dreq, token)
		dreq.Header.Set("Content-Type", "application/json")
		dresp, err := c.client.Do(dreq)
		if err != nil {
			return err
		}
		dresp.Body.Close()
		if dresp.StatusCode != http.StatusOK {
			return fmt.Errorf("dismiss review %d (user %s) failed: %d", r.ID, r.User.Login, dresp.StatusCode)
		}
	}
	return nil
}

// GetCIStatus returns the aggregate check status for a commit SHA.
// Returns "success", "failure", or "pending".
func (c *HTTPGitHubRFCClient) GetCIStatus(ctx context.Context, baseURL, owner, name, commitSHA, token string) (string, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/commits/%s/check-runs", apiBase, owner, name, commitSHA)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "pending", err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return "pending", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "pending", fmt.Errorf("get check-runs failed: %d", resp.StatusCode)
	}
	var result struct {
		TotalCount int `json:"total_count"`
		CheckRuns  []struct {
			Status     string `json:"status"`
			Conclusion string `json:"conclusion"`
		} `json:"check_runs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "pending", err
	}
	if result.TotalCount == 0 {
		return "success", nil
	}
	for _, run := range result.CheckRuns {
		if run.Status != "completed" {
			return "pending", nil
		}
		if run.Conclusion == "failure" || run.Conclusion == "timed_out" || run.Conclusion == "cancelled" {
			return "failure", nil
		}
	}
	return "success", nil
}

// LabelExists reports whether the given label name is defined on the repository.
func (c *HTTPGitHubRFCClient) LabelExists(ctx context.Context, baseURL, owner, name, label, token string) (bool, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/labels/%s", apiBase, owner, name, url.PathEscape(label))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return false, err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return false, err
	}
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return true, nil
	}
	if resp.StatusCode == http.StatusNotFound {
		return false, nil
	}
	return false, fmt.Errorf("check label failed: %d", resp.StatusCode)
}

// AddLabels appends labels to a pull request via the GitHub Issues API.
func (c *HTTPGitHubRFCClient) AddLabels(ctx context.Context, baseURL, owner, name string, prNumber int, labels []string, token string) error {
	if len(labels) == 0 {
		return nil
	}
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/issues/%d/labels", apiBase, owner, name, prNumber)
	payload, _ := json.Marshal(map[string]any{"labels": labels})
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
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("add labels failed: %d", resp.StatusCode)
	}
	return nil
}

// GetCollaboratorPermission returns the permission level for username on the
// given repository using the GitHub collaborator permission API.
// Returns one of: "admin", "maintain", "write", "triage", "read", "none".
func (c *HTTPGitHubRFCClient) GetCollaboratorPermission(ctx context.Context, baseURL, owner, name, username, token string) (string, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/collaborators/%s/permission", apiBase, owner, name, username)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "none", err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return "none", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		// Not a collaborator at all.
		return "none", nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "none", fmt.Errorf("get collaborator permission failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var payload struct {
		Permission string `json:"permission"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "none", err
	}
	if payload.Permission == "" {
		return "none", nil
	}
	return payload.Permission, nil
}

// GetAuthenticatedUser returns the GitHub login for the token owner.
func (c *HTTPGitHubRFCClient) GetAuthenticatedUser(ctx context.Context, baseURL, token string) (string, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	// GitHub: /user. Gitea-compatible: same endpoint.
	u := fmt.Sprintf("%s/user", apiBase)
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
		return "", fmt.Errorf("get authenticated user failed: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var payload struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	return payload.Login, nil
}

// ApproveRFCFile rewrites the RFC frontmatter status to "accepted" on the main branch.
// Returns the commit SHA.
func (c *HTTPGitHubRFCClient) ApproveRFCFile(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (string, error) {
	view, err := c.GetRFC(ctx, baseURL, owner, name, branch, filePath, token)
	if err != nil {
		return "", fmt.Errorf("fetch rfc for approve: %w", err)
	}
	meta, _ := parseFrontmatter(view.MarkdownSource)
	current := normalizeLifecycleStatus(meta["status"])
	if current != "draft" {
		return "", fmt.Errorf("cannot approve: RFC status is %q (only draft RFCs may be approved)", current)
	}
	updated := rewriteFrontmatterStatus(view.MarkdownSource, "accepted")
	commitMsg := fmt.Sprintf("docs(rfc): approve %s", path.Base(filePath))
	sha, err := c.CommitFile(ctx, baseURL, owner, name, branch, filePath, updated, commitMsg, token)
	if err != nil {
		return "", fmt.Errorf("commit approved rfc: %w", err)
	}
	return sha, nil
}

// MarkRFCFileImplemented rewrites the RFC frontmatter status to "implemented" on the main branch.
// Returns the commit SHA.
func (c *HTTPGitHubRFCClient) MarkRFCFileImplemented(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (string, error) {
	view, err := c.GetRFC(ctx, baseURL, owner, name, branch, filePath, token)
	if err != nil {
		return "", fmt.Errorf("fetch rfc for mark-implemented: %w", err)
	}
	meta, _ := parseFrontmatter(view.MarkdownSource)
	current := normalizeLifecycleStatus(meta["status"])
	if current != "accepted" {
		return "", fmt.Errorf("cannot mark implemented: RFC status is %q (only accepted RFCs may be marked implemented)", current)
	}
	updated := rewriteFrontmatterStatus(view.MarkdownSource, "implemented")
	commitMsg := fmt.Sprintf("docs(rfc): mark %s implemented", path.Base(filePath))
	sha, err := c.CommitFile(ctx, baseURL, owner, name, branch, filePath, updated, commitMsg, token)
	if err != nil {
		return "", fmt.Errorf("commit implemented rfc: %w", err)
	}
	return sha, nil
}
