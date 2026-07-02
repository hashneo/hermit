package rfc

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pelletier/go-toml/v2"
	"gopkg.in/yaml.v3"
)

type GitHubRFCClient interface {
	ListRFCs(ctx context.Context, baseURL, owner, name, branch, docsPath, token string) ([]CatalogItem, error)
	GetRFC(ctx context.Context, baseURL, owner, name, branch, filePath, token string) (DocumentView, error)
	ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, rfcLabel, token string) (ReviewReadyRFCResult, error)
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

	// LabelExists returns true when the label is already defined on the repository.
	LabelExists(ctx context.Context, baseURL, owner, name, label, token string) (bool, error)
	// AddLabels appends labels to a pull request (issues API).
	AddLabels(ctx context.Context, baseURL, owner, name string, prNumber int, labels []string, token string) error
	// RemoveLabel removes a label from a pull request (issues API). Missing labels are treated as success.
	RemoveLabel(ctx context.Context, baseURL, owner, name string, prNumber int, label, token string) error

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
const RFCReadyLabel = ""

type ReviewReadyRFCItem struct {
	PRNumber       int
	PRTitle        string
	PRBody         string
	PRState        string
	PRMerged       bool
	HeadSHA        string
	HeadRef        string
	Mergeable      *bool
	MergeableState string
	HTMLURL        string
	Title          string
	Path           string
	DocumentType   string
	Labels         []string
	ChangedFiles   int
	Additions      int
	Deletions      int
	IssueComments  int
	ReviewComments int
}

type ReviewReadyRFCResult struct {
	Items       []ReviewReadyRFCItem
	OpenPRCount int
	PRStates    PRStateCounts
}

type PRStateCounts struct {
	Ready       int `json:"ready"`
	Conflicted  int `json:"conflicted"`
	Failed      int `json:"failed"`
	NeedsReview int `json:"needs_review"`
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

	if resp.StatusCode == http.StatusNotFound {
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		return nil, nil
	}
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

// fetchPaginatedPRs fetches all pull requests for the given state, following
// Link header pagination.  When label is non-empty only PRs carrying that label
// are returned (uses the issues list endpoint which supports label filtering).
func (c *HTTPGitHubRFCClient) fetchPaginatedPRs(ctx context.Context, apiBase, owner, name, state, label, token string) ([]struct {
	Number         int    `json:"number"`
	Title          string `json:"title"`
	Body           string `json:"body"`
	HTMLURL        string `json:"html_url"`
	State          string `json:"state"`
	Draft          bool   `json:"draft"`
	Merged         bool   `json:"merged"`
	Mergeable      *bool  `json:"mergeable"`
	MergeableState string `json:"mergeable_state"`
	Comments       int    `json:"comments"`
	ReviewComments int    `json:"review_comments"`
	Head           struct {
		SHA string `json:"sha"`
		Ref string `json:"ref"`
	} `json:"head"`
	Labels []struct {
		Name string `json:"name"`
	} `json:"labels"`
}, error) {
	type pr = struct {
		Number         int    `json:"number"`
		Title          string `json:"title"`
		Body           string `json:"body"`
		HTMLURL        string `json:"html_url"`
		State          string `json:"state"`
		Draft          bool   `json:"draft"`
		Merged         bool   `json:"merged"`
		Mergeable      *bool  `json:"mergeable"`
		MergeableState string `json:"mergeable_state"`
		Comments       int    `json:"comments"`
		ReviewComments int    `json:"review_comments"`
		Head           struct {
			SHA string `json:"sha"`
			Ref string `json:"ref"`
		} `json:"head"`
		Labels []struct {
			Name string `json:"name"`
		} `json:"labels"`
	}

	var all []pr
	nextURL := fmt.Sprintf("%s/repos/%s/%s/pulls?state=%s&per_page=100", apiBase, owner, name, state)
	if label != "" {
		nextURL += "&labels=" + url.QueryEscape(label)
	}

	for nextURL != "" {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, nextURL, nil)
		if err != nil {
			return nil, err
		}
		setGitHubHeaders(req, token)
		resp, err := c.client.Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
			resp.Body.Close()
			return nil, fmt.Errorf("list pull requests (%s) failed: %d %s", state, resp.StatusCode, strings.TrimSpace(string(body)))
		}
		var page []pr
		if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
			resp.Body.Close()
			return nil, err
		}
		resp.Body.Close()
		all = append(all, page...)
		nextURL = githubNextPageURL(resp.Header.Get("Link"))
	}
	return all, nil
}

// githubNextPageURL extracts the URL for the next page from a GitHub Link header.
// Returns "" when there is no next page.
func githubNextPageURL(link string) string {
	// Link: <https://...?page=2>; rel="next", <https://...?page=5>; rel="last"
	for _, part := range strings.Split(link, ",") {
		part = strings.TrimSpace(part)
		segments := strings.Split(part, ";")
		if len(segments) < 2 {
			continue
		}
		rel := strings.TrimSpace(segments[1])
		if rel == `rel="next"` {
			u := strings.TrimSpace(segments[0])
			u = strings.TrimPrefix(u, "<")
			u = strings.TrimSuffix(u, ">")
			return u
		}
	}
	return ""
}

func (c *HTTPGitHubRFCClient) ListReviewReadyRFCs(ctx context.Context, baseURL, owner, name, docsPath, rfcLabel, token string) (ReviewReadyRFCResult, error) {
	apiBase := strings.TrimRight(baseURL, "/")
	docMatcher, hasDocuchangoProject, err := c.docuchangoDocumentMatcher(ctx, apiBase, owner, name, "", token)
	if err != nil {
		return ReviewReadyRFCResult{}, err
	}
	docsPath = strings.Trim(strings.TrimSpace(docsPath), "/")
	if docsPath == "" {
		docsPath = "docs-cms/rfcs"
	}
	

	// Query PRs and inspect changed files client-side. Some providers
	// (for example Gitea) do not support string label filters on this endpoint.
	// Hermit also auto-applies workflow labels for Docuchango document changes,
	// Fetch all open PRs (paginated) and closed/merged PRs that still carry a
	// review workflow label.  Using state=all with a fixed per_page cap misses
	// open PRs that are older than the page boundary — on busy repos this
	// silently drops legitimate RFC review requests.
	//
	// Strategy:
	//   1. GET /pulls?state=open   — all open PRs, paginated; no label required.
	//   2. GET /pulls?state=closed — closed/merged PRs, paginated; kept only
	//      when they carry a review label so stale history stays out of the queue.
	// Fetch open and closed PRs in parallel.
	type prFetchErr struct {
		prs []struct {
			Number         int    `json:"number"`
			Title          string `json:"title"`
			Body           string `json:"body"`
			HTMLURL        string `json:"html_url"`
			State          string `json:"state"`
			Draft          bool   `json:"draft"`
			Merged         bool   `json:"merged"`
			Mergeable      *bool  `json:"mergeable"`
			MergeableState string `json:"mergeable_state"`
			Comments       int    `json:"comments"`
			ReviewComments int    `json:"review_comments"`
			Head           struct {
				SHA string `json:"sha"`
				Ref string `json:"ref"`
			} `json:"head"`
			Labels []struct {
				Name string `json:"name"`
			} `json:"labels"`
		}
		err error
	}
	openCh   := make(chan prFetchErr, 1)
	closedCh := make(chan prFetchErr, 1)
	go func() {
		prs, err := c.fetchPaginatedPRs(ctx, apiBase, owner, name, "open", "", token)
		openCh <- prFetchErr{prs, err}
	}()
	go func() {
		if rfcLabel == "" {
			closedCh <- prFetchErr{}
			return
		}
		prs, err := c.fetchPaginatedPRs(ctx, apiBase, owner, name, "closed", rfcLabel, token)
		closedCh <- prFetchErr{prs, err}
	}()
	openFetch   := <-openCh
	closedFetch := <-closedCh
	if openFetch.err != nil {
		return ReviewReadyRFCResult{}, openFetch.err
	}
	if closedFetch.err != nil {
		return ReviewReadyRFCResult{}, closedFetch.err
	}
	pulls := append(openFetch.prs, closedFetch.prs...)

	// Pre-filter candidates.
	type prEntry struct {
		idx   int
		pr    struct {
			Number         int    `json:"number"`
			Title          string `json:"title"`
			Body           string `json:"body"`
			HTMLURL        string `json:"html_url"`
			State          string `json:"state"`
			Draft          bool   `json:"draft"`
			Merged         bool   `json:"merged"`
			Mergeable      *bool  `json:"mergeable"`
			MergeableState string `json:"mergeable_state"`
			Comments       int    `json:"comments"`
			ReviewComments int    `json:"review_comments"`
			Head           struct {
				SHA string `json:"sha"`
				Ref string `json:"ref"`
			} `json:"head"`
			Labels []struct {
				Name string `json:"name"`
			} `json:"labels"`
		}
		prState string
	}
	var candidates []prEntry
	for _, pr := range pulls {
		prState := strings.ToLower(strings.TrimSpace(pr.State))
		if prState == "" {
			prState = "open"
		}
		if prState != "open" && !prHasReviewWorkflowLabel(pr.Labels, rfcLabel) {
			continue
		}
		if pr.Draft {
			continue
		}
		candidates = append(candidates, prEntry{pr: pr, prState: prState})
	}

	// Process PRs in parallel with a bounded worker pool (8 concurrent).
	type prOutcome struct {
		items      []ReviewReadyRFCItem
		openPR     bool
		mergeable  *bool
		mergeState string
		draft      bool
	}
	outcomes := make([]prOutcome, len(candidates))
	sem      := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for i, cand := range candidates {
		wg.Add(1)
		go func(idx int, cand prEntry) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			pr      := cand.pr
			prState := cand.prState
			mergeable     := pr.Mergeable
			mergeableState := strings.TrimSpace(pr.MergeableState)
			merged        := pr.Merged
			if (mergeable == nil && mergeableState == "") || prState != "open" {
				if dm, ds, dmerged, derr := c.getPullRequestMergeState(ctx, apiBase, owner, name, pr.Number, token); derr == nil {
					mergeable, mergeableState, merged = dm, ds, dmerged
				}
			}
			labelNames := make([]string, 0, len(pr.Labels))
			for _, l := range pr.Labels {
				labelNames = append(labelNames, l.Name)
			}

			prFiles, err := c.listPullRequestFiles(ctx, apiBase, owner, name, pr.Number, token)
			if err != nil {
				slog.Warn("list PR files failed", "pr", pr.Number, "error", err)
				return
			}

			workflowLabels := map[string]struct{}{}
			type reviewDocument struct {
				Filename     string
				Additions    int
				DocumentType string
			}
			var documents  []reviewDocument
			documentSeen  := map[string]struct{}{}
			prAdditions, prDeletions := 0, 0
			for _, prFile := range prFiles {
				prAdditions += prFile.Additions
				prDeletions += prFile.Deletions
				if isReviewSessionMarkerPath(prFile.Filename) {
					marker, err := c.getReviewSessionMarker(ctx, apiBase, owner, name, pr.Head.SHA, prFile.Filename, token)
					if err != nil {
						slog.Warn("read review session marker failed", "pr", pr.Number, "file", prFile.Filename, "error", err)
						continue
					}
					sourcePath := strings.Trim(strings.TrimSpace(marker.SourcePath), "/")
					if sourcePath == "" {
						continue
					}
					docTypes := uniqueDocuchangoDocTypes(append(append([]string{marker.DocumentType}, docMatcher.Match(sourcePath)...), fallbackDocuchangoDocTypes(sourcePath, docsPath)...))
					for _, dt := range docTypes {
						workflowLabels[docuchangoWorkflowLabel(dt, docuchangoWorkflowStateNeedsReview)] = struct{}{}
					}
					docType := primaryReviewDocumentType(docTypes)
					_, seenSrc := documentSeen[sourcePath]; if docType == "" || seenSrc {
						continue
					}
					documentSeen[sourcePath] = struct{}{}
					documents = append(documents, reviewDocument{Filename: sourcePath, Additions: prFile.Additions, DocumentType: docType})
					continue
				}
				docTypes := docMatcher.Match(prFile.Filename)
				if !hasDocuchangoProject && isRFCPathInDocs(prFile.Filename, docsPath) {
					docTypes = append(docTypes, "rfc")
				}
				docTypes = uniqueDocuchangoDocTypes(append(docTypes, fallbackDocuchangoDocTypes(prFile.Filename, docsPath)...))
				for _, dt := range docTypes {
					workflowLabels[docuchangoWorkflowLabel(dt, docuchangoWorkflowStateNeedsReview)] = struct{}{}
				}
				docType := primaryReviewDocumentType(docTypes)
				_, seenPR := documentSeen[prFile.Filename]; if docType == "" || seenPR {
					continue
				}
				documentSeen[prFile.Filename] = struct{}{}
				documents = append(documents, reviewDocument{Filename: prFile.Filename, Additions: prFile.Additions, DocumentType: docType})
			}
			if prState == "open" && len(workflowLabels) > 0 {
				if applied, err := c.ensureAndApplyWorkflowLabels(ctx, baseURL, owner, name, pr.Number, workflowLabels, labelNames, token); err != nil {
					slog.Warn("auto-apply workflow labels failed", "pr", pr.Number, "error", err)
				} else {
					labelNames = applied
				}
			}
			if len(documents) == 0 {
				return
			}
			sort.SliceStable(documents, func(i, j int) bool {
				if documents[i].DocumentType != documents[j].DocumentType {
					return docuchangoReviewTypeSortOrder(documents[i].DocumentType) < docuchangoReviewTypeSortOrder(documents[j].DocumentType)
				}
				if documents[i].Additions != documents[j].Additions {
					return documents[i].Additions > documents[j].Additions
				}
				return documents[i].Filename < documents[j].Filename
			})
			var prItems []ReviewReadyRFCItem
			for _, doc := range documents {
				title := strings.TrimSuffix(path.Base(doc.Filename), ".md")
				if view, err := c.GetRFC(ctx, baseURL, owner, name, pr.Head.SHA, doc.Filename, token); err == nil {
					title = view.Title
				}
				prItems = append(prItems, ReviewReadyRFCItem{
					PRNumber: pr.Number, PRTitle: pr.Title, PRBody: pr.Body,
					PRState: prState, PRMerged: merged,
					HeadSHA: pr.Head.SHA, HeadRef: pr.Head.Ref,
					Mergeable: mergeable, MergeableState: mergeableState,
					HTMLURL: pr.HTMLURL, Title: title, Path: doc.Filename,
					DocumentType: doc.DocumentType, Labels: labelNames,
					ChangedFiles: len(prFiles), Additions: prAdditions, Deletions: prDeletions,
					IssueComments: pr.Comments, ReviewComments: pr.ReviewComments,
				})
			}
			outcomes[idx] = prOutcome{
				items: prItems, openPR: prState == "open",
				mergeable: mergeable, mergeState: mergeableState, draft: pr.Draft,
			}
		}(i, cand)
	}
	wg.Wait()

	// Collect results preserving original PR order.
	var items []ReviewReadyRFCItem
	openPRCount := 0
	var prStates PRStateCounts
	for i, out := range outcomes {
		if len(out.items) == 0 {
			continue
		}
		items = append(items, out.items...)
		if out.openPR {
			openPRCount++
			prStates.add(classifyPRState(candidates[i].pr.Draft, out.mergeable, out.mergeState))
		}
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].PRNumber != items[j].PRNumber {
			return items[i].PRNumber < items[j].PRNumber
		}
		if items[i].DocumentType != items[j].DocumentType {
			return docuchangoReviewTypeSortOrder(items[i].DocumentType) < docuchangoReviewTypeSortOrder(items[j].DocumentType)
		}
		return items[i].Path < items[j].Path
	})

	return ReviewReadyRFCResult{Items: items, OpenPRCount: openPRCount, PRStates: prStates}, nil
}

func (counts *PRStateCounts) add(state string) {
	switch state {
	case "ready":
		counts.Ready++
	case "conflicted":
		counts.Conflicted++
	case "failed":
		counts.Failed++
	default:
		counts.NeedsReview++
	}
}

func classifyPRState(draft bool, mergeable *bool, mergeableState string) string {
	normalizedState := strings.ToLower(strings.TrimSpace(mergeableState))
	if draft {
		return "needs_review"
	}
	if strings.Contains(normalizedState, "dirty") || strings.Contains(normalizedState, "conflict") {
		return "conflicted"
	}
	switch normalizedState {
	case "clean":
		return "ready"
	case "unstable":
		return "failed"
	case "blocked", "behind", "has_hooks", "unknown":
		return "needs_review"
	case "":
		if mergeable != nil {
			if *mergeable {
				return "ready"
			}
			return "conflicted"
		}
		return "needs_review"
	default:
		if mergeable != nil {
			if *mergeable {
				return "ready"
			}
			return "conflicted"
		}
		return "needs_review"
	}
}

func (c *HTTPGitHubRFCClient) getPullRequestMergeState(ctx context.Context, apiBase, owner, name string, prNumber int, token string) (*bool, string, bool, error) {
	prURL := fmt.Sprintf("%s/repos/%s/%s/pulls/%d", apiBase, owner, name, prNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, prURL, nil)
	if err != nil {
		return nil, "", false, err
	}
	setGitHubHeaders(req, token)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, "", false, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, "", false, fmt.Errorf("get pull request merge state failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload struct {
		Mergeable      *bool  `json:"mergeable"`
		MergeableState string `json:"mergeable_state"`
		Merged         bool   `json:"merged"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, "", false, err
	}

	return payload.Mergeable, strings.TrimSpace(payload.MergeableState), payload.Merged, nil
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
		fileName := strings.Trim(strings.TrimSpace(prFile.Filename), "/")
		if fileName == requestedPath {
			allowed = true
			break
		}
		if !isReviewSessionMarkerPath(fileName) {
			continue
		}
		marker, markerErr := c.getReviewSessionMarker(ctx, apiBase, owner, name, pull.Head.SHA, fileName, token)
		if markerErr == nil && strings.Trim(strings.TrimSpace(marker.SourcePath), "/") == requestedPath {
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

func isReviewSessionMarkerPath(filePath string) bool {
	filePath = strings.Trim(strings.TrimSpace(filePath), "/")
	return strings.HasPrefix(filePath, ".hermit/reviews/") && strings.HasSuffix(filePath, ".json")
}

func (c *HTTPGitHubRFCClient) getReviewSessionMarker(ctx context.Context, apiBase, owner, name, ref, filePath, token string) (reviewSessionMarker, error) {
	content, err := c.getFileText(ctx, apiBase, owner, name, ref, filePath, token)
	if err != nil {
		return reviewSessionMarker{}, err
	}
	var marker reviewSessionMarker
	if err := json.Unmarshal([]byte(content), &marker); err != nil {
		return reviewSessionMarker{}, err
	}
	marker.SourcePath = strings.Trim(strings.TrimSpace(marker.SourcePath), "/")
	marker.DocumentType = normalizeDocuchangoDocType(marker.DocumentType)
	return marker, nil
}

func (c *HTTPGitHubRFCClient) getFileText(ctx context.Context, apiBase, owner, name, ref, filePath, token string) (string, error) {
	contentURL := fmt.Sprintf("%s/repos/%s/%s/contents/%s?ref=%s",
		strings.TrimRight(apiBase, "/"),
		owner,
		name,
		path.Clean(strings.TrimPrefix(filePath, "/")),
		url.QueryEscape(ref),
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, contentURL, nil)
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
		return "", fmt.Errorf("get file failed: %d %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(payload.Content, "\n", ""))
	if err != nil {
		return "", err
	}
	return string(decoded), nil
}

func (c *HTTPGitHubRFCClient) listPullRequestFiles(ctx context.Context, apiBase, owner, name string, prNumber int, token string) ([]struct {
	Filename  string `json:"filename"`
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
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
		Deletions int    `json:"deletions"`
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
		ID   string `yaml:"id" json:"id" toml:"id"`
		Name string `yaml:"name" json:"name" toml:"name"`
	} `yaml:"project" json:"project" toml:"project"`
	Structure struct {
		RFCDir       string                       `yaml:"rfc_dir" json:"rfc_dir" toml:"rfc_dir"`
		ADRDir       string                       `yaml:"adr_dir" json:"adr_dir" toml:"adr_dir"`
		MemoDir      string                       `yaml:"memo_dir" json:"memo_dir" toml:"memo_dir"`
		PRDDir       string                       `yaml:"prd_dir" json:"prd_dir" toml:"prd_dir"`
		DocsRoots    []string                     `yaml:"docs_roots" json:"docs_roots" toml:"docs_roots"`
		DocTypes     map[string]docuchangoDocType `yaml:"doc_types" json:"doc_types" toml:"doc_types"`
		DocumentDirs []string                     `yaml:"document_folders" json:"document_folders" toml:"document_folders"`
	} `yaml:"structure" json:"structure" toml:"structure"`
	Indexes     []docuchangoIndex      `yaml:"indexes" json:"indexes" toml:"indexes"`
	Subprojects []docuchangoSubproject `yaml:"subprojects" json:"subprojects" toml:"subprojects"`
	Security    struct {
		AllowExternalPaths bool `yaml:"allow_external_paths" json:"allow_external_paths" toml:"allow_external_paths"`
	} `yaml:"security" json:"security" toml:"security"`
}

type docuchangoDocType struct {
	Schema  string   `yaml:"schema" json:"schema" toml:"schema"`
	Folders []string `yaml:"folders" json:"folders" toml:"folders"`
}

type docuchangoIndex struct {
	Targets []string `yaml:"targets" json:"targets" toml:"targets"`
}

type docuchangoSubproject struct {
	Path string `yaml:"path" json:"path" toml:"path"`
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

func (s *docuchangoSubproject) UnmarshalJSON(data []byte) error {
	var raw string
	if err := json.Unmarshal(data, &raw); err == nil {
		s.Path = raw
		return nil
	}
	type alias docuchangoSubproject
	var out alias
	if err := json.Unmarshal(data, &out); err != nil {
		return err
	}
	s.Path = out.Path
	return nil
}

func (s *docuchangoSubproject) UnmarshalText(text []byte) error {
	s.Path = string(text)
	return nil
}

type docuchangoProjectContext struct {
	config docuchangoProjectConfig
	path   string
	base   string
}

type docuchangoDocumentMatcher struct {
	rules []docuchangoDocumentRule
}

type docuchangoDocumentRule struct {
	docType string
	root    string
	pattern string
}

func (m docuchangoDocumentMatcher) Match(filePath string) []string {
	normalizedPath := strings.Trim(strings.TrimSpace(filePath), "/")
	if normalizedPath == "" || !strings.HasSuffix(normalizedPath, ".md") {
		return nil
	}
	seen := map[string]struct{}{}
	var docTypes []string
	for _, rule := range m.rules {
		if rule.matches(normalizedPath) {
			if _, ok := seen[rule.docType]; ok {
				continue
			}
			seen[rule.docType] = struct{}{}
			docTypes = append(docTypes, rule.docType)
		}
	}
	sort.Strings(docTypes)
	return docTypes
}

func (r docuchangoDocumentRule) matches(filePath string) bool {
	if r.pattern != "" {
		return matchDocuchangoGlob(r.pattern, filePath)
	}
	if r.root == "" {
		return false
	}
	return filePath == r.root || strings.HasPrefix(filePath, r.root+"/")
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

func (c *HTTPGitHubRFCClient) docuchangoDocumentMatcher(ctx context.Context, apiBase, owner, name, branch, token string) (docuchangoDocumentMatcher, bool, error) {
	contexts, ok, err := c.loadDocuchangoProjectContexts(ctx, apiBase, owner, name, branch, token)
	if err != nil || !ok {
		return docuchangoDocumentMatcher{}, ok, err
	}
	return docuchangoMatcherFromContexts(contexts), true, nil
}

func (c *HTTPGitHubRFCClient) loadDocuchangoProjectContexts(ctx context.Context, apiBase, owner, name, branch, token string) ([]docuchangoProjectContext, bool, error) {
	if branch == "" {
		branch = "HEAD"
	}
	rootCandidates := docuchangoProjectConfigCandidates("", "docs-cms", "docs")
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
			candidates := docuchangoProjectConfigCandidates(subPath)
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
	if err := decodeDocuchangoProjectConfig([]byte(content), filePath, &config); err != nil {
		return nil, fmt.Errorf("parse Docuchango project config %s: %w", filePath, err)
	}
	if strings.TrimSpace(config.Project.ID) == "" || strings.TrimSpace(config.Project.Name) == "" {
		return nil, nil
	}
	return &config, nil
}

func docuchangoProjectConfigCandidates(paths ...string) []string {
	const baseName = "docs-project"
	exts := []string{".yaml", ".yml", ".json", ".toml"}
	seen := map[string]struct{}{}
	candidates := make([]string, 0, len(paths)*len(exts))
	for _, raw := range paths {
		cleaned := strings.Trim(path.Clean(strings.Trim(raw, "/")), "/")
		if cleaned == "." {
			cleaned = ""
		}
		base := path.Base(cleaned)
		if strings.TrimSuffix(base, path.Ext(base)) == baseName {
			if _, ok := seen[cleaned]; !ok {
				seen[cleaned] = struct{}{}
				candidates = append(candidates, cleaned)
			}
			continue
		}
		for _, ext := range exts {
			candidate := path.Join(cleaned, baseName+ext)
			if _, ok := seen[candidate]; ok {
				continue
			}
			seen[candidate] = struct{}{}
			candidates = append(candidates, candidate)
		}
	}
	return candidates
}

func decodeDocuchangoProjectConfig(data []byte, filePath string, config *docuchangoProjectConfig) error {
	switch strings.ToLower(filepath.Ext(filePath)) {
	case ".json":
		return json.Unmarshal(data, config)
	case ".toml":
		return toml.Unmarshal(data, config)
	default:
		return yaml.Unmarshal(data, config)
	}
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

func docuchangoMatcherFromContexts(contexts []docuchangoProjectContext) docuchangoDocumentMatcher {
	seen := map[string]struct{}{}
	var rules []docuchangoDocumentRule
	addRule := func(docType, root, pattern string) {
		docType = normalizeDocuchangoDocType(docType)
		root = strings.Trim(strings.TrimSpace(root), "/")
		pattern = strings.Trim(strings.TrimSpace(pattern), "/")
		if docType == "" || (root == "" && pattern == "") {
			return
		}
		key := docType + "\x00" + root + "\x00" + pattern
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		rules = append(rules, docuchangoDocumentRule{docType: docType, root: root, pattern: pattern})
	}

	for _, context := range contexts {
		if len(context.config.Structure.DocTypes) > 0 {
			docsRoots := context.config.Structure.DocsRoots
			if len(docsRoots) == 0 {
				docsRoots = []string{"."}
			}
			for name, docType := range context.config.Structure.DocTypes {
				labelType := firstNonEmpty(docType.Schema, name)
				for _, docsRoot := range docsRoots {
					for _, folder := range docType.Folders {
						root := resolveDocuchangoConfigPath(path.Join(context.base, docsRoot), folder, context.config.Security.AllowExternalPaths)
						addRule(labelType, root, "")
					}
				}
			}
		} else {
			for docType, dir := range legacyDocuchangoDocDirs(context.config) {
				root := resolveDocuchangoConfigPath(context.base, dir, context.config.Security.AllowExternalPaths)
				addRule(docType, root, "")
			}
		}

		for _, folder := range context.config.Structure.DocumentDirs {
			root := resolveDocuchangoConfigPath(context.base, folder, context.config.Security.AllowExternalPaths)
			docType := normalizeDocuchangoDocType(path.Base(root))
			if docType == "rfcs" {
				docType = "rfc"
			}
			if docType == "memos" {
				docType = "memo"
			}
			addRule(docType, root, "")
		}
		for _, index := range context.config.Indexes {
			for _, target := range index.Targets {
				resolved := resolveDocuchangoConfigPath(context.base, target, context.config.Security.AllowExternalPaths)
				addRule("rfc", "", resolved)
			}
		}
	}

	return docuchangoDocumentMatcher{rules: rules}
}

func legacyDocuchangoDocDirs(config docuchangoProjectConfig) map[string]string {
	dirs := map[string]string{
		"adr":  firstNonEmpty(config.Structure.ADRDir, "adr"),
		"rfc":  firstNonEmpty(config.Structure.RFCDir, "rfcs"),
		"memo": firstNonEmpty(config.Structure.MemoDir, "memos"),
		"prd":  firstNonEmpty(config.Structure.PRDDir, "prd"),
	}
	return dirs
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

func prHasReviewWorkflowLabel(labels []struct {
	Name string `json:"name"`
}, rfcLabel string) bool {
	for _, label := range labels {
		name := strings.ToLower(strings.TrimSpace(label.Name))
		if name == strings.ToLower(strings.TrimSpace(rfcLabel)) {
			return true
		}
		_, state, ok := docuchangoWorkflowLabelParts(name)
		if ok && docuchangoWorkflowStateKeepsReviewQueued(state) {
			return true
		}
	}
	return false
}

func (c *HTTPGitHubRFCClient) ensureAndApplyWorkflowLabels(ctx context.Context, baseURL, owner, name string, prNumber int, labels map[string]struct{}, existing []string, token string) ([]string, error) {
	existingSet := map[string]struct{}{}
	for _, label := range existing {
		existingSet[strings.ToLower(strings.TrimSpace(label))] = struct{}{}
	}

	desiredDocTypes := map[string]struct{}{}
	desiredLabels := map[string]struct{}{}
	for label := range labels {
		docType, _, ok := docuchangoWorkflowLabelParts(label)
		if ok {
			desiredDocTypes[docType] = struct{}{}
			desiredLabels[strings.ToLower(strings.TrimSpace(label))] = struct{}{}
		}
	}

	missing := make([]string, 0, len(labels))
	for label := range labels {
		if label == "" {
			continue
		}
		if _, ok := existingSet[strings.ToLower(strings.TrimSpace(label))]; ok {
			continue
		}
		if err := c.EnsureLabel(ctx, baseURL, owner, name, label, "0075ca", docuchangoWorkflowLabelDescription(label), token); err != nil {
			return existing, err
		}
		missing = append(missing, label)
	}
	sort.Strings(missing)
	out := append([]string{}, existing...)
	if len(missing) > 0 {
		if err := c.AddLabels(ctx, baseURL, owner, name, prNumber, missing, token); err != nil {
			return existing, err
		}
		out = append(out, missing...)
	}
	for _, label := range existing {
		docType, _, ok := docuchangoWorkflowLabelParts(label)
		if !ok {
			continue
		}
		if _, ok := desiredDocTypes[docType]; !ok {
			continue
		}
		if _, ok := desiredLabels[strings.ToLower(strings.TrimSpace(label))]; ok {
			continue
		}
		if err := c.RemoveLabel(ctx, baseURL, owner, name, prNumber, label, token); err != nil {
			return existing, err
		}
		out = removeStringFold(out, label)
	}
	sort.Strings(out)
	return out, nil
}

const (
	docuchangoWorkflowStateNeedsReview  = "needs-review"
	docuchangoWorkflowStateReview       = "review"
	docuchangoWorkflowStateNeedsChanges = "needs-changes"
	docuchangoWorkflowStateReviewed     = "reviewed"
	docuchangoWorkflowStateReady        = "ready"
)

func docuchangoWorkflowLabel(docType, state string) string {
	docType = normalizeDocuchangoDocType(docType)
	state = normalizeDocuchangoWorkflowState(state)
	if docType == "" {
		return ""
	}
	return docType + ":" + state
}

func normalizeDocuchangoWorkflowState(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	switch value {
	case docuchangoWorkflowStateNeedsReview:
		return docuchangoWorkflowStateNeedsReview
	case docuchangoWorkflowStateReview:
		return docuchangoWorkflowStateReview
	case docuchangoWorkflowStateNeedsChanges:
		return docuchangoWorkflowStateNeedsChanges
	case docuchangoWorkflowStateReviewed:
		return docuchangoWorkflowStateReviewed
	case docuchangoWorkflowStateReady:
		return docuchangoWorkflowStateReady
	default:
		return docuchangoWorkflowStateNeedsReview
	}
}

func docuchangoWorkflowLabelParts(label string) (docType, state string, ok bool) {
	docType, state, ok = strings.Cut(strings.ToLower(strings.TrimSpace(label)), ":")
	if !ok {
		return "", "", false
	}
	docType = normalizeDocuchangoDocType(docType)
	state = strings.ToLower(strings.TrimSpace(state))
	if docType == "" || !isDocuchangoWorkflowState(state) {
		return "", "", false
	}
	return docType, state, true
}

func isDocuchangoWorkflowState(state string) bool {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case docuchangoWorkflowStateNeedsReview, docuchangoWorkflowStateReview, docuchangoWorkflowStateNeedsChanges, docuchangoWorkflowStateReviewed, docuchangoWorkflowStateReady:
		return true
	default:
		return false
	}
}

func docuchangoWorkflowStateKeepsReviewQueued(state string) bool {
	switch normalizeDocuchangoWorkflowState(state) {
	case docuchangoWorkflowStateNeedsReview, docuchangoWorkflowStateReview, docuchangoWorkflowStateNeedsChanges:
		return true
	default:
		return false
	}
}

func removeStringFold(values []string, target string) []string {
	out := values[:0]
	for _, value := range values {
		if strings.EqualFold(value, target) {
			continue
		}
		out = append(out, value)
	}
	return out
}

func docuchangoWorkflowLabelDescription(label string) string {
	docType, state, ok := strings.Cut(label, ":")
	if !ok || docType == "" || state == "" {
		return "Docuchango workflow state"
	}
	return fmt.Sprintf("%s document is in %s state", strings.ToUpper(docType), state)
}

func normalizeDocuchangoDocType(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimSuffix(value, "s")
	var b strings.Builder
	lastDash := false
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}

func fallbackDocuchangoDocTypes(filePath, docsPath string) []string {
	normalizedPath := strings.Trim(strings.TrimSpace(filePath), "/")
	base := path.Base(normalizedPath)
	docsRoot := strings.Trim(strings.TrimSpace(docsPath), "/")
	if docsRoot == "" {
		docsRoot = "docs-cms/rfcs"
	}
	docsRoot = strings.TrimSuffix(docsRoot, "/rfcs")
	if docsRoot == "" || docsRoot == "." {
		docsRoot = "docs-cms"
	}

	type rule struct {
		docType string
		dir     string
		prefix  string
	}
	rules := []rule{
		{docType: "adr", dir: "adr", prefix: "adr-"},
		{docType: "memo", dir: "memos", prefix: "memo-"},
		{docType: "prd", dir: "prd", prefix: "prd-"},
		{docType: "rfc", dir: "rfcs", prefix: "rfc-"},
	}

	for _, rule := range rules {
		if !strings.HasPrefix(normalizedPath, docsRoot+"/"+rule.dir+"/") {
			continue
		}
		if strings.HasPrefix(base, rule.prefix) && strings.HasSuffix(base, ".md") {
			return []string{rule.docType}
		}
	}
	return nil
}

func uniqueDocuchangoDocTypes(docTypes []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(docTypes))
	for _, docType := range docTypes {
		docType = normalizeDocuchangoDocType(docType)
		if docType == "" {
			continue
		}
		if _, ok := seen[docType]; ok {
			continue
		}
		seen[docType] = struct{}{}
		out = append(out, docType)
	}
	return out
}

func primaryReviewDocumentType(docTypes []string) string {
	docTypes = uniqueDocuchangoDocTypes(docTypes)
	if len(docTypes) == 0 {
		return ""
	}
	sort.SliceStable(docTypes, func(i, j int) bool {
		return docuchangoReviewTypeSortOrder(docTypes[i]) < docuchangoReviewTypeSortOrder(docTypes[j])
	})
	return docTypes[0]
}

func docuchangoReviewTypeSortOrder(docType string) int {
	switch normalizeDocuchangoDocType(docType) {
	case "adr":
		return 10
	case "prd":
		return 20
	case "rfc":
		return 30
	case "memo":
		return 40
	default:
		return 100
	}
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
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

// RemoveLabel removes a label from a pull request via the GitHub Issues API.
func (c *HTTPGitHubRFCClient) RemoveLabel(ctx context.Context, baseURL, owner, name string, prNumber int, label, token string) error {
	label = strings.TrimSpace(label)
	if label == "" {
		return nil
	}
	apiBase := strings.TrimRight(baseURL, "/")
	u := fmt.Sprintf("%s/repos/%s/%s/issues/%d/labels/%s", apiBase, owner, name, prNumber, url.PathEscape(label))
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, u, nil)
	if err != nil {
		return err
	}
	setGitHubHeaders(req, token)
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
	resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("remove label failed: %d", resp.StatusCode)
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
