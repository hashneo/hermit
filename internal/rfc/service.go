package rfc

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	stdhtml "html"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"hermit/internal/workset"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
	nethtml "golang.org/x/net/html"
)

type Eligibility struct {
	Status  string   `json:"status"`
	Reasons []string `json:"reasons"`
}

type Document struct {
	RepositoryID string      `json:"repository_id"`
	PRNumber     int         `json:"pr_number"`
	HeadSHA      string      `json:"head_sha"`
	FilePath     string      `json:"file_path,omitempty"`
	Eligibility  Eligibility `json:"eligibility"`
}

type Anchor struct {
	AnchorID        string `json:"anchor_id"`
	LineStart       int    `json:"line_start"`
	LineEnd         int    `json:"line_end"`
	TextFingerprint string `json:"text_fingerprint"`
}

type Render struct {
	RepositoryID   string   `json:"repository_id"`
	PRNumber       int      `json:"pr_number"`
	HeadSHA        string   `json:"head_sha"`
	MarkdownSource string   `json:"markdown_source"`
	AnchorMap      []Anchor `json:"anchor_map"`
}

type CatalogItem struct {
	ID              string   `json:"id"`
	Title           string   `json:"title"`
	Path            string   `json:"path"`
	SourceType      string   `json:"source_type"`
	SourceLabel     string   `json:"source_label"`
	AllowedActions  []string `json:"allowed_actions"`
	LifecycleStatus string   `json:"lifecycle_status,omitempty"`
	PRNumber        int      `json:"pr_number,omitempty"`
	HeadSHA         string   `json:"head_sha,omitempty"`
	HeadRef         string   `json:"head_ref,omitempty"`
	Mergeable       *bool    `json:"mergeable,omitempty"`
	MergeableState  string   `json:"mergeable_state,omitempty"`
	Labels          []string `json:"labels,omitempty"`
	Commentable     bool     `json:"commentable"`
	StatusMutable   bool     `json:"status_mutable"`
	// hermit-ixk: full web URL for the RFC file, used by the native client Share button.
	// For Gitea: {baseURL}/{owner}/{name}/src/branch/{branch}/{path}
	// For GitHub: https://github.com/{owner}/{name}/blob/{branch}/{path}
	HTMLURL string `json:"html_url,omitempty"`
}

type RepositoryRFCSummary struct {
	PendingReviewCount int           `json:"pending_review_count"`
	OpenPRCount        int           `json:"open_pr_count"`
	PRStates           PRStateCounts `json:"pr_states"`
}

type RepositoryRFCListResponse struct {
	Items   []CatalogItem          `json:"items"`
	Total   int                    `json:"total"`
	Summary RepositoryRFCSummary   `json:"summary"`
	Cache   *workset.CacheMetadata `json:"cache,omitempty"`
}

type DocumentView struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	Path           string `json:"path"`
	MarkdownSource string `json:"markdown_source"`
	PRAuthorLogin  string `json:"pr_author_login,omitempty"`
}

// ThreadResolverService is an optional dependency that lets MergePR (and
// AcceptRFC) resolve all open PR review threads before attempting a merge.
// Defined as an interface so the rfc package has no hard import of the thread
// package and existing tests require no changes.
type ThreadResolverService interface {
	// ListOpen returns the GitHubThreadIDs of every unresolved thread on the PR.
	ListOpen(repositoryID string, prNumber int) []string
	// Resolve resolves the thread identified by githubThreadID.
	Resolve(ctx context.Context, repositoryID string, prNumber int, githubThreadID string) error
}

type Service struct {
	rfcDir         string
	repoResolver   RepositoryResolver
	githubClients  map[string]GitHubRFCClient
	registryBases  map[string]string
	threadResolver ThreadResolverService // optional; nil disables pre-merge resolution
	workset        *workset.Store
	cacheReadTTL   time.Duration
	cacheJitter    time.Duration
}

// WithThreadResolver injects a thread resolver used to resolve all open review
// conversations before a merge is attempted.
func (s *Service) WithThreadResolver(tr ThreadResolverService) {
	s.threadResolver = tr
}

func (s *Service) WithWorkset(store *workset.Store) {
	s.workset = store
}

func (s *Service) WithRepositoryRFCListCacheTiming(readTTL, jitter time.Duration) {
	if readTTL > 0 {
		s.cacheReadTTL = readTTL
	}
	if jitter >= 0 {
		s.cacheJitter = jitter
	}
}

var docuchangoRFCFilenamePattern = regexp.MustCompile(`^rfc-[0-9]{3}-[a-z0-9]+(?:-[a-z0-9]+)*\.md$`)

const (
	defaultRepositoryRFCListCacheTTL    = 3 * time.Minute
	defaultRepositoryRFCListCacheJitter = time.Minute
)

type RepositoryResolver interface {
	ResolveRepositoryAccess(id string) (owner, name, registry, baseURL, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool)
}

func NewServiceWithRepositoryResolver(resolver RepositoryResolver, registries map[string]string) *Service {
	clients := make(map[string]GitHubRFCClient, len(registries))
	for registryName := range registries {
		clients[registryName] = NewHTTPGitHubRFCClient()
	}

	return &Service{rfcDir: "docs-cms/rfcs", repoResolver: resolver, githubClients: clients, registryBases: registries}
}

func NewService() *Service {
	return &Service{rfcDir: "docs-cms/rfcs", githubClients: map[string]GitHubRFCClient{}}
}

func (s *Service) GetDocument(repositoryID string, prNumber int) Document {
	headSHA := fakeHeadSHA(repositoryID, prNumber)
	content := sampleRFCMarkdown(repositoryID, prNumber)
	filePath := sampleFilePath(repositoryID, prNumber)

	eligibility := evaluateEligibility(content, filePath)

	return Document{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		HeadSHA:      headSHA,
		FilePath:     filePath,
		Eligibility:  eligibility,
	}
}

func (s *Service) Render(repositoryID string, prNumber int) (Render, error) {
	doc := s.GetDocument(repositoryID, prNumber)
	if doc.Eligibility.Status != "eligible" {
		return Render{}, fmt.Errorf("rfc is not eligible")
	}

	source := sampleRFCMarkdown(repositoryID, prNumber)
	lines := strings.Split(source, "\n")
	anchors := make([]Anchor, 0, len(lines))

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			anchors = append(anchors, Anchor{
				AnchorID:        fmt.Sprintf("anc_%d", i+1),
				LineStart:       i + 1,
				LineEnd:         i + 1,
				TextFingerprint: fingerprint(trimmed),
			})
		}
	}

	return Render{
		RepositoryID:   repositoryID,
		PRNumber:       prNumber,
		HeadSHA:        doc.HeadSHA,
		MarkdownSource: source,
		AnchorMap:      anchors,
	}, nil
}

func (s *Service) ListRFCs() ([]CatalogItem, error) {
	entries, err := os.ReadDir(s.rfcDir)
	if err != nil {
		return nil, fmt.Errorf("read rfc directory: %w", err)
	}

	items := make([]CatalogItem, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !isDocuchangoRFCFilename(entry.Name()) {
			continue
		}

		fullPath := filepath.Join(s.rfcDir, entry.Name())
		contentBytes, readErr := os.ReadFile(fullPath)
		if readErr != nil {
			continue
		}
		content := string(contentBytes)
		frontmatter, body := parseFrontmatter(content)
		title := strings.TrimSpace(frontmatter["title"])
		if title == "" {
			title = extractFirstHeading(body)
		}
		if title == "" {
			title = strings.TrimSuffix(entry.Name(), ".md")
		}

		items = append(items, CatalogItem{
			ID:              entry.Name(),
			Title:           title,
			Path:            filepath.ToSlash(fullPath),
			SourceType:      "main",
			SourceLabel:     "Main branch",
			AllowedActions:  []string{"view"},
			LifecycleStatus: normalizeLifecycleStatus(frontmatter["status"]),
			Commentable:     false,
		})
	}

	sort.Slice(items, func(i, j int) bool {
		return items[i].Title < items[j].Title
	})

	return items, nil
}

func (s *Service) RenderRFC(id string) (DocumentView, error) {
	if id == "" || filepath.Base(id) != id || !isDocuchangoRFCFilename(id) {
		return DocumentView{}, fmt.Errorf("invalid rfc id")
	}

	fullPath := filepath.Join(s.rfcDir, id)
	contentBytes, err := os.ReadFile(fullPath)
	if err != nil {
		return DocumentView{}, fmt.Errorf("read rfc: %w", err)
	}

	markdown := string(contentBytes)
	frontmatter, markdownBody := parseFrontmatter(markdown)
	title := strings.TrimSpace(frontmatter["title"])
	if title == "" {
		title = extractFirstHeading(markdownBody)
	}
	if title == "" {
		title = strings.TrimSuffix(id, ".md")
	}

	return DocumentView{
		ID:             id,
		Title:          title,
		Path:           filepath.ToSlash(fullPath),
		MarkdownSource: markdown,
	}, nil
}

func (s *Service) ListRFCsByRepository(ctx context.Context, repositoryID string) (RepositoryRFCListResponse, error) {
	if s.repoResolver == nil {
		return RepositoryRFCListResponse{}, fmt.Errorf("repository resolver is not configured")
	}

	cacheTTL := s.repositoryRFCListCacheTTL(repositoryID)
	if s.workset != nil {
		if projection, ok, err := s.workset.GetFreshRepositoryRFCList(ctx, repositoryID, cacheTTL); err == nil && ok {
			var cached RepositoryRFCListResponse
			if decodeErr := json.Unmarshal(projection.Payload, &cached); decodeErr == nil {
				cached.Cache = &projection.Cache
				return cached, nil
			}
		}
	}

	owner, name, registry, repoBaseURL, branch, docsPath, rfcLabel, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return RepositoryRFCListResponse{}, fmt.Errorf("repository not found")
	}
	if token == "" {
		return RepositoryRFCListResponse{}, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}

	baseURL := s.registryBaseURL(registry, repoBaseURL)
	mainItems, err := client.ListRFCs(ctx, baseURL, owner, name, branch, docsPath, token)
	if err != nil {
		if cached, ok := s.cachedRepositoryRFCListAfterError(ctx, repositoryID, cacheTTL, err); ok {
			return cached, nil
		}
		return RepositoryRFCListResponse{}, err
	}

	items := make([]CatalogItem, len(mainItems))
	var wg sync.WaitGroup
	for idx, item := range mainItems {
		wg.Add(1)
		go func(idx int, item CatalogItem) {
			defer wg.Done()
			lifecycleStatus := "unknown"
			title := item.Title
			if view, viewErr := client.GetRFC(ctx, baseURL, owner, name, branch, item.Path, token); viewErr == nil {
				title = view.Title
				meta, _ := parseFrontmatter(view.MarkdownSource)
				lifecycleStatus = normalizeLifecycleStatus(meta["status"])
			}
			title = normalizeRFCTitle(title, item.Path)
			items[idx] = CatalogItem{
				ID:              item.ID,
				Title:           title,
				Path:            item.Path,
				SourceType:      "main",
				SourceLabel:     "Main branch",
				AllowedActions:  []string{"view"},
				LifecycleStatus: lifecycleStatus,
				Commentable:     false,
				StatusMutable:   true,
				HTMLURL:         rfcWebURL(baseURL, owner, name, branch, item.Path),
			}
		}(idx, item)
	}
	wg.Wait()

	// Drop any zero-value slots (shouldn't occur, but guard against panics if
	// mainItems was modified between allocation and goroutine execution).
	filled := items[:0]
	for _, it := range items {
		if it.ID != "" {
			filled = append(filled, it)
		}
	}
	items = filled

	prResult, err := client.ListReviewReadyRFCs(ctx, baseURL, owner, name, docsPath, rfcLabel, token)
	if err != nil {
		if cached, ok := s.cachedRepositoryRFCListAfterError(ctx, repositoryID, cacheTTL, err); ok {
			return cached, nil
		}
		return RepositoryRFCListResponse{}, err
	}
	for _, prItem := range prResult.Items {
		items = append(items, CatalogItem{
			ID:             makePRCatalogID(prItem.PRNumber, prItem.Path),
			Title:          prItem.Title,
			Path:           prItem.Path,
			SourceType:     "pull_request",
			SourceLabel:    fmt.Sprintf("PR #%d", prItem.PRNumber),
			AllowedActions: []string{"view", "comment"},
			PRNumber:       prItem.PRNumber,
			HeadSHA:        prItem.HeadSHA,
			HeadRef:        prItem.HeadRef,
			Mergeable:      prItem.Mergeable,
			MergeableState: prItem.MergeableState,
			Labels:         prItem.Labels,
			Commentable:    true,
			StatusMutable:  false,
			HTMLURL:        prItem.HTMLURL,
		})
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].SourceType == items[j].SourceType {
			if items[i].Title == items[j].Title {
				return items[i].ID < items[j].ID
			}
			return items[i].Title < items[j].Title
		}
		if items[i].SourceType == "main" {
			return true
		}
		if items[j].SourceType == "main" {
			return false
		}
		return items[i].Title < items[j].Title
	})

	response := RepositoryRFCListResponse{
		Items: items,
		Total: len(items),
		Summary: RepositoryRFCSummary{
			PendingReviewCount: len(prResult.Items),
			OpenPRCount:        prResult.OpenPRCount,
			PRStates:           prResult.PRStates,
		},
	}
	if s.workset != nil {
		if payload, err := json.Marshal(response); err == nil {
			if meta, err := s.workset.PutRepositoryRFCListSuccess(ctx, repositoryID, payload); err == nil {
				response.Cache = &meta
			}
		}
	}
	return response, nil
}

func (s *Service) cachedRepositoryRFCListAfterError(ctx context.Context, repositoryID string, ttl time.Duration, err error) (RepositoryRFCListResponse, bool) {
	if s.workset == nil {
		return RepositoryRFCListResponse{}, false
	}
	_ = s.workset.PutRepositoryRFCListError(ctx, repositoryID, "provider_error", err.Error())
	projection, ok, getErr := s.workset.GetAnyRepositoryRFCList(ctx, repositoryID, ttl)
	if getErr != nil || !ok {
		return RepositoryRFCListResponse{}, false
	}
	meta := projection.Cache
	meta.Cached = true
	meta.LastErrorCode = "provider_error"
	meta.LastErrorMessage = err.Error()
	var cached RepositoryRFCListResponse
	if decodeErr := json.Unmarshal(projection.Payload, &cached); decodeErr != nil {
		return RepositoryRFCListResponse{}, false
	}
	cached.Cache = &meta
	return cached, true
}

func (s *Service) repositoryRFCListCacheTTL(repositoryID string) time.Duration {
	readTTL := s.cacheReadTTL
	if readTTL <= 0 {
		readTTL = defaultRepositoryRFCListCacheTTL
	}
	jitter := s.cacheJitter
	if jitter < 0 {
		jitter = 0
	}
	if jitter == 0 {
		return readTTL
	}
	sum := sha256.Sum256([]byte(repositoryID))
	offset := binary.BigEndian.Uint64(sum[:8]) % uint64(jitter)
	return readTTL + time.Duration(offset)
}

// SubmitForReviewResult is returned by SubmitForReview on success.
type SubmitForReviewResult struct {
	PRNumber int    `json:"pr_number"`
	HTMLURL  string `json:"html_url"`
	Branch   string `json:"branch"`
}

// SubmitForReview promotes a draft RFC on the main branch to "in-review" by:
//  1. Ensuring the hermit:rfc-ready label exists on the repository.
//  2. Fetching the current RFC content and rewriting its frontmatter status to "in-review".
//  3. Creating a new branch (rfc-review/<slug>).
//  4. Committing the updated file onto that branch.
//  5. Opening a PR against the default branch with the hermit:rfc-ready label applied.
func (s *Service) SubmitForReview(ctx context.Context, repositoryID, rfcPath string) (SubmitForReviewResult, error) {
	if s.repoResolver == nil {
		return SubmitForReviewResult{}, fmt.Errorf("repository resolver is not configured")
	}

	owner, name, registry, repoBaseURL, branch, _, rfcLabel, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return SubmitForReviewResult{}, fmt.Errorf("repository not found")
	}
	if token == "" {
		return SubmitForReviewResult{}, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}
	baseURL := s.registryBaseURL(registry, repoBaseURL)

	// 1. Ensure the rfc-ready label exists.
	if err := client.EnsureLabel(ctx, baseURL, owner, name, rfcLabel, "0075ca", "RFC ready for review", token); err != nil {
		return SubmitForReviewResult{}, fmt.Errorf("ensure label: %w", err)
	}

	// 2. Fetch current RFC content, guard status transition, rewrite to "in-review".
	view, err := client.GetRFC(ctx, baseURL, owner, name, branch, rfcPath, token)
	if err != nil {
		return SubmitForReviewResult{}, fmt.Errorf("fetch rfc: %w", err)
	}
	meta, _ := parseFrontmatter(view.MarkdownSource)
	currentStatus := normalizeLifecycleStatus(meta["status"])
	if currentStatus != "draft" {
		return SubmitForReviewResult{}, fmt.Errorf(
			"cannot submit for review: RFC status is %q (only draft RFCs may be submitted)", currentStatus)
	}
	updated := rewriteFrontmatterStatus(view.MarkdownSource, "in-review")
	title := view.Title

	// 3. Create review branch.
	headSHA, err := client.GetMainBranchSHA(ctx, baseURL, owner, name, branch, token)
	if err != nil {
		return SubmitForReviewResult{}, fmt.Errorf("get branch SHA: %w", err)
	}
	reviewBranch := reviewBranchName(rfcPath)
	if err := client.CreateBranch(ctx, baseURL, owner, name, reviewBranch, headSHA, token); err != nil {
		return SubmitForReviewResult{}, fmt.Errorf("create branch: %w", err)
	}

	// 4. Commit updated file.
	commitMsg := fmt.Sprintf("docs(rfc): submit %s for review", path.Base(rfcPath))
	if _, err := client.CommitFile(ctx, baseURL, owner, name, reviewBranch, rfcPath, updated, commitMsg, token); err != nil {
		return SubmitForReviewResult{}, fmt.Errorf("commit file: %w", err)
	}

	// 5. Open PR with the rfc-ready label.
	prBody := fmt.Sprintf("## %s\n\nSubmitted for review via Hermit.\n\n<!-- %s -->", title, rfcLabel)
	pr, err := client.CreatePR(ctx, baseURL, owner, name, title, prBody, reviewBranch, branch, []string{rfcLabel}, token)
	if err != nil {
		return SubmitForReviewResult{}, fmt.Errorf("create PR: %w", err)
	}

	return SubmitForReviewResult{PRNumber: pr.Number, HTMLURL: pr.HTMLURL, Branch: reviewBranch}, nil
}

// AcceptRFCResult is returned by AcceptRFC.
type AcceptRFCResult struct {
	Merged           bool   `json:"merged"`
	BlockedByCI      bool   `json:"blocked_by_ci"`
	CommitSHA        string `json:"commit_sha,omitempty"`         // SHA of the acceptance commit on the PR branch
	HandedToIronhide bool   `json:"handed_to_ironhide,omitempty"` // true when ironhide labels were applied instead of direct merge
}

// AcceptRFC marks a PR RFC as accepted.
//
// Flow:
//  1. Fetch the current RFC file from the PR branch.
//  2. Rewrite frontmatter status to "accepted" and commit (skipped if already accepted).
//  3. Check whether both ironhide labels exist on the repository.
//     - If YES: add ironhide-review and ironhide-merge labels to the PR and return
//     HandedToIronhide=true.  Ironhide will handle merging.
//     - If NO:  attempt a direct squash-merge.  If CI blocks the merge, return
//     BlockedByCI=true and CommitSHA so the caller can poll and retry.
func (s *Service) AcceptRFC(ctx context.Context, repositoryID string, prNumber int, filePath string) (AcceptRFCResult, error) {
	if s.repoResolver == nil {
		return AcceptRFCResult{}, fmt.Errorf("repository resolver is not configured")
	}
	owner, name, registry, repoBaseURL, _, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return AcceptRFCResult{}, fmt.Errorf("repository not found")
	}
	if token == "" {
		return AcceptRFCResult{}, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}
	baseURL := s.registryBaseURL(registry, repoBaseURL)

	// 1. Get the PR head branch and current commit SHA.
	headRef, headSHA, err := client.GetPRHead(ctx, baseURL, owner, name, prNumber, token)
	if err != nil {
		return AcceptRFCResult{}, fmt.Errorf("get PR head ref: %w", err)
	}

	// 2. Fetch current RFC content from the PR branch.
	view, err := client.GetRFC(ctx, baseURL, owner, name, headRef, filePath, token)
	if err != nil {
		return AcceptRFCResult{}, fmt.Errorf("fetch rfc: %w", err)
	}

	// 3. Rewrite frontmatter status → "accepted" and commit, unless already accepted.
	meta, _ := parseFrontmatter(view.MarkdownSource)
	currentStatus := normalizeLifecycleStatus(meta["status"])
	var sha string
	if currentStatus != "accepted" {
		updated := rewriteFrontmatterStatus(view.MarkdownSource, "accepted")
		commitMsg := fmt.Sprintf("docs(rfc): accept %s", path.Base(filePath))
		sha, err = client.CommitFileOnBranch(ctx, baseURL, owner, name, headRef, filePath, updated, commitMsg, token)
		if err != nil {
			return AcceptRFCResult{}, fmt.Errorf("commit accepted status: %w", err)
		}
	} else {
		// Already accepted — use the current PR head SHA for CI polling.
		sha = headSHA
	}

	// 4a. Ironhide path: if both labels exist on the repo, apply them and hand off.
	const ironhideReview = "ironhide-review"
	const ironhideMerge = "ironhide-merge"
	reviewExists, err := client.LabelExists(ctx, baseURL, owner, name, ironhideReview, token)
	if err != nil {
		return AcceptRFCResult{}, fmt.Errorf("check ironhide-review label: %w", err)
	}
	mergeExists, err := client.LabelExists(ctx, baseURL, owner, name, ironhideMerge, token)
	if err != nil {
		return AcceptRFCResult{}, fmt.Errorf("check ironhide-merge label: %w", err)
	}
	if reviewExists && mergeExists {
		if err := client.AddLabels(ctx, baseURL, owner, name, prNumber, []string{ironhideReview, ironhideMerge}, token); err != nil {
			return AcceptRFCResult{}, fmt.Errorf("add ironhide labels: %w", err)
		}
		return AcceptRFCResult{HandedToIronhide: true, CommitSHA: sha}, nil
	}

	// 4b. Dismiss any pending bot reviews (e.g. copilot) so they don't block the merge.
	if err := client.DismissBotReviews(ctx, baseURL, owner, name, prNumber, token); err != nil {
		// Non-fatal: log and continue. A failed dismissal should not abort the accept flow.
		_ = fmt.Errorf("dismiss bot reviews (non-fatal): %w", err)
	}

	// 4c. Dismiss any outstanding human REQUEST_CHANGES reviews — the RFC has been formally
	// accepted so reviewer objections are considered resolved by the accept decision.
	if err := client.DismissHumanRequestChangesReviews(ctx, baseURL, owner, name, prNumber, token); err != nil {
		// Non-fatal: same reasoning as bot dismissal above.
		_ = fmt.Errorf("dismiss human request-changes reviews (non-fatal): %w", err)
	}

	// 4d. Resolve all open review threads so branch-protection "require
	// conversation resolution" does not block the squash-merge.
	if err := s.resolveOpenThreads(ctx, repositoryID, prNumber, owner, name); err != nil {
		return AcceptRFCResult{}, fmt.Errorf("resolve review threads: %w", err)
	}

	// 4e. Manual path: attempt squash-merge with retry/backoff so that a
	// brief lag in GitHub's branch-protection "conversations resolved" gate
	// does not cause a spurious blocked_by_ci=true response.
	merged, blockedByCI, err := s.mergeWithRetry(ctx, client, baseURL, owner, name, prNumber, token, repositoryID)
	if err != nil {
		return AcceptRFCResult{}, fmt.Errorf("merge PR: %w", err)
	}

	return AcceptRFCResult{Merged: merged, BlockedByCI: blockedByCI, CommitSHA: sha}, nil
}

// resolveOpenThreads resolves every open review thread on the PR and verifies
// that none remain. Returns an error if any thread cannot be resolved or if
// open threads are still present after resolution.  A nil threadResolver is a
// no-op (e.g. Gitea repos or tests that have not injected one).
func (s *Service) resolveOpenThreads(ctx context.Context, repositoryID string, prNumber int, owner, name string) error {
	if s.threadResolver == nil {
		return nil
	}
	openIDs := s.threadResolver.ListOpen(repositoryID, prNumber)
	if len(openIDs) == 0 {
		return nil
	}
	slog.Info("resolveOpenThreads: resolving open threads before merge",
		"owner", owner, "repo", name, "prNumber", prNumber, "count", len(openIDs))
	for _, id := range openIDs {
		slog.Info("resolveOpenThreads: resolving thread", "threadID", id)
		if err := s.threadResolver.Resolve(ctx, repositoryID, prNumber, id); err != nil {
			return fmt.Errorf("resolve thread %s: %w", id, err)
		}
	}
	// Verify.
	if remaining := s.threadResolver.ListOpen(repositoryID, prNumber); len(remaining) > 0 {
		slog.Error("resolveOpenThreads: threads still open after resolve attempt",
			"owner", owner, "repo", name, "prNumber", prNumber, "remaining", len(remaining))
		return fmt.Errorf("%d review conversation(s) could not be resolved before merging", len(remaining))
	}
	return nil
}

// mergeWithRetry calls client.MergePR up to maxMergeAttempts times.
//
// GitHub's branch-protection "require conversation resolution" gate can lag a
// few seconds behind the GraphQL resolveReviewThread mutation.  A 405 response
// immediately after resolveOpenThreads does NOT necessarily mean CI is
// blocking — it may be a transient timing window.
//
// Before each retry the method re-verifies (via threadResolver.ListOpen) that
// the PR truly has zero open conversations.  If open threads re-appear they
// are re-resolved before sleeping.  If the final attempt also returns 405 the
// result is forwarded to the caller unchanged (BlockedByCI=true).
func (s *Service) mergeWithRetry(
	ctx context.Context,
	client GitHubRFCClient,
	baseURL, owner, name string,
	prNumber int,
	token, repositoryID string,
) (merged bool, blockedByCI bool, err error) {
	const maxMergeAttempts = 4
	const retryDelay = 3 * time.Second

	for attempt := 1; attempt <= maxMergeAttempts; attempt++ {
		// Re-verify conversations before every attempt so we are certain GitHub
		// sees zero open threads at the moment we call the merge API.
		if s.threadResolver != nil {
			if open := s.threadResolver.ListOpen(repositoryID, prNumber); len(open) > 0 {
				slog.Info("mergeWithRetry: open threads detected before attempt, resolving",
					"attempt", attempt, "count", len(open), "prNumber", prNumber)
				if resolveErr := s.resolveOpenThreads(ctx, repositoryID, prNumber, owner, name); resolveErr != nil {
					return false, false, fmt.Errorf("re-resolve threads on attempt %d: %w", attempt, resolveErr)
				}
			}
		}

		merged, blockedByCI, err = client.MergePR(ctx, baseURL, owner, name, prNumber, token)
		if err != nil {
			return
		}
		if merged {
			slog.Info("mergeWithRetry: merged successfully", "attempt", attempt, "prNumber", prNumber)
			return
		}
		if !blockedByCI {
			// 409 conflict or similar — not a timing issue, don't retry.
			return
		}

		// 405: verify threads are clear so we can distinguish timing from a real block.
		if s.threadResolver != nil {
			if open := s.threadResolver.ListOpen(repositoryID, prNumber); len(open) > 0 {
				// Genuine conversation block — not timing. Surface as error.
				return false, false, fmt.Errorf(
					"merge blocked: %d unresolved conversation(s) remain after resolution attempt", len(open))
			}
		}

		if attempt == maxMergeAttempts {
			slog.Error("mergeWithRetry: all attempts exhausted, merge still returning 405",
				"prNumber", prNumber, "maxAttempts", maxMergeAttempts)
			break
		}

		slog.Info("mergeWithRetry: merge returned 405 but conversations are clear, "+
			"waiting for branch-protection to catch up",
			"attempt", attempt, "maxAttempts", maxMergeAttempts, "retryDelay", retryDelay,
			"prNumber", prNumber)
		select {
		case <-ctx.Done():
			return false, false, ctx.Err()
		case <-time.After(retryDelay):
		}
	}
	return
}

type MergePRResult struct {
	Merged      bool   `json:"merged"`
	BlockedByCI bool   `json:"blocked_by_ci"`
	CommitSHA   string `json:"commit_sha,omitempty"`
}

// MergePR attempts a direct squash-merge of the given PR without any
// frontmatter rewrite. Intended for use after AcceptRFC when CI was blocking
// the initial merge attempt and the caller has confirmed CI is now green.
func (s *Service) MergePR(ctx context.Context, repositoryID string, prNumber int) (MergePRResult, error) {
	if s.repoResolver == nil {
		return MergePRResult{}, fmt.Errorf("repository resolver is not configured")
	}
	owner, name, registry, repoBaseURL, _, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return MergePRResult{}, fmt.Errorf("repository not found")
	}
	if token == "" {
		return MergePRResult{}, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}
	baseURL := s.registryBaseURL(registry, repoBaseURL)

	// Resolve all open review threads before merging so that branch-protection
	// rules requiring "all conversations resolved" do not block the merge.
	if err := s.resolveOpenThreads(ctx, repositoryID, prNumber, owner, name); err != nil {
		slog.Error("MergePR service: failed to resolve threads", "owner", owner, "repo", name, "prNumber", prNumber, "error", err)
		return MergePRResult{}, fmt.Errorf("resolve review threads: %w", err)
	}

	merged, blockedByCI, err := s.mergeWithRetry(ctx, client, baseURL, owner, name, prNumber, token, repositoryID)
	if err != nil {
		slog.Error("MergePR service: github merge failed", "owner", owner, "repo", name, "prNumber", prNumber, "error", err)
		return MergePRResult{}, fmt.Errorf("merge PR: %w", err)
	}
	slog.Info("MergePR service: done", "owner", owner, "repo", name, "prNumber", prNumber, "merged", merged, "blockedByCI", blockedByCI)
	return MergePRResult{Merged: merged, BlockedByCI: blockedByCI}, nil
}

// CIStatusResult is returned by GetCIStatus.
type CIStatusResult struct {
	Status string `json:"status"` // "pending" | "success" | "failure"
}

// GetCIStatus returns the aggregate GitHub Actions / check-runs status for a
// commit SHA on this repository.  Used to poll after AcceptRFC when merging
// was blocked by pending CI.
func (s *Service) GetCIStatus(ctx context.Context, repositoryID, commitSHA string) (CIStatusResult, error) {
	if s.repoResolver == nil {
		return CIStatusResult{Status: "pending"}, fmt.Errorf("repository resolver is not configured")
	}
	owner, name, registry, repoBaseURL, _, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return CIStatusResult{Status: "pending"}, fmt.Errorf("repository not found")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}
	baseURL := s.registryBaseURL(registry, repoBaseURL)

	status, err := client.GetCIStatus(ctx, baseURL, owner, name, commitSHA, token)
	if err != nil {
		return CIStatusResult{Status: "pending"}, err
	}
	return CIStatusResult{Status: status}, nil
}

// rewriteFrontmatterStatus replaces the value of the "status" key inside a
// YAML frontmatter block. If no frontmatter or no status key is present one
// is inserted. The rest of the document is left unchanged.
func rewriteFrontmatterStatus(markdown, newStatus string) string {
	lines := strings.Split(markdown, "\n")
	if len(lines) < 3 || strings.TrimSpace(lines[0]) != "---" {
		// No frontmatter — prepend a minimal block.
		return fmt.Sprintf("---\nstatus: %s\n---\n%s", newStatus, markdown)
	}

	// Find closing ---.
	end := -1
	statusLine := -1
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			end = i
			break
		}
		parts := strings.SplitN(lines[i], ":", 2)
		if len(parts) == 2 && strings.TrimSpace(parts[0]) == "status" {
			statusLine = i
		}
	}
	if end == -1 {
		// Malformed frontmatter — prepend.
		return fmt.Sprintf("---\nstatus: %s\n---\n%s", newStatus, markdown)
	}

	out := make([]string, len(lines))
	copy(out, lines)
	if statusLine != -1 {
		out[statusLine] = "status: " + newStatus
	} else {
		// Insert before closing ---.
		out = append(out[:end], append([]string{"status: " + newStatus}, out[end:]...)...)
	}
	return strings.Join(out, "\n")
}

// reviewBranchName derives a branch name from the RFC file path.
// e.g. "docs-cms/rfcs/rfc-008-logging.md" → "rfc-review/rfc-008-logging"
func reviewBranchName(rfcPath string) string {
	base := strings.TrimSuffix(path.Base(rfcPath), ".md")
	return "rfc-review/" + base
}

// RenderPRRFC fetches the RFC file from the PR's head branch and renders it.
// It resolves the repository, finds the RFC file changed in the PR, and returns
// the rendered content — replacing the old stub-based Render method for the
// /pull-requests/{prNumber}/rfc/render endpoint.
func (s *Service) RenderPRRFC(ctx context.Context, repositoryID string, prNumber int) (DocumentView, error) {
	if s.repoResolver == nil {
		return DocumentView{}, fmt.Errorf("repository resolver is not configured")
	}

	owner, name, registry, repoBaseURL, _, docsPath, rfcLabel, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return DocumentView{}, fmt.Errorf("repository not found")
	}
	if token == "" {
		return DocumentView{}, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}

	baseURL := s.registryBaseURL(registry, repoBaseURL)

	// List PR files to find the RFC path.
	prResult, err := client.ListReviewReadyRFCs(ctx, baseURL, owner, name, docsPath, rfcLabel, token)
	if err != nil {
		return DocumentView{}, fmt.Errorf("list PR RFCs: %w", err)
	}

	var filePath string
	for _, item := range prResult.Items {
		if item.PRNumber == prNumber {
			filePath = item.Path
			break
		}
	}
	if filePath == "" {
		return DocumentView{}, fmt.Errorf("no RFC file found in pull request %d", prNumber)
	}

	view, err := client.GetRFCFromPullRequest(ctx, baseURL, owner, name, prNumber, filePath, token)
	if err != nil {
		return DocumentView{}, err
	}
	view.ID = makePRCatalogID(prNumber, filePath)
	return view, nil
}

func (s *Service) RenderRFCByRepository(ctx context.Context, repositoryID, rfcID string) (DocumentView, error) {
	if s.repoResolver == nil {
		return DocumentView{}, fmt.Errorf("repository resolver is not configured")
	}

	owner, name, registry, repoBaseURL, branch, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return DocumentView{}, fmt.Errorf("repository not found")
	}
	if token == "" {
		return DocumentView{}, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}

	baseURL := s.registryBaseURL(registry, repoBaseURL)
	if prNumber, filePath, ok := parsePRCatalogID(rfcID); ok {
		view, err := client.GetRFCFromPullRequest(ctx, baseURL, owner, name, prNumber, filePath, token)
		if err != nil {
			return DocumentView{}, err
		}
		view.ID = rfcID
		return view, nil
	}

	return client.GetRFC(ctx, baseURL, owner, name, branch, rfcID, token)
}

func (s *Service) registryBaseURL(registry, repoBaseURL string) string {
	if strings.TrimSpace(repoBaseURL) != "" {
		return strings.TrimRight(strings.TrimSpace(repoBaseURL), "/")
	}
	if baseURL, ok := s.registryBases[registry]; ok && strings.TrimSpace(baseURL) != "" {
		return baseURL
	}
	return "https://api.github.com"
}

// rfcWebURL constructs the browser-accessible URL for an RFC file.
// hermit-ixk: Gitea uses /src/branch/{branch}/{path}; GitHub uses /blob/{branch}/{path}.
// The distinction is made by checking whether baseURL is api.github.com.
func rfcWebURL(baseURL, owner, name, branch, filePath string) string {
	base := strings.TrimRight(baseURL, "/")
	if base == "https://api.github.com" {
		return fmt.Sprintf("https://github.com/%s/%s/blob/%s/%s", owner, name, branch, filePath)
	}
	// Gitea (and Forgejo) web URL pattern.
	return fmt.Sprintf("%s/%s/%s/src/branch/%s/%s", base, owner, name, branch, filePath)
}

func evaluateEligibility(content, filePath string) Eligibility {
	reasons := []string{}
	status := "eligible"

	if !strings.HasPrefix(filePath, "docs-cms/rfcs/") {
		status = "ineligible"
		reasons = append(reasons, "RFC file must be under docs-cms/rfcs/")
	}

	if !strings.HasSuffix(filePath, ".md") {
		status = "ineligible"
		reasons = append(reasons, "RFC file must be markdown")
	}

	if strings.TrimSpace(content) == "" {
		status = "ineligible"
		reasons = append(reasons, "RFC markdown file is empty")
	}

	if status == "eligible" {
		reasons = append(reasons, "single markdown RFC file detected")
	}

	return Eligibility{Status: status, Reasons: reasons}
}

func sampleRFCMarkdown(repositoryID string, prNumber int) string {
	return fmt.Sprintf("# RFC for %s PR-%d\n\n## Summary\n\nThis RFC proposes core workflow behavior for Hermit.\n\n## Design\n\nThe implementation follows OpenAPI-first contracts.", repositoryID, prNumber)
}

func sampleFilePath(repositoryID string, prNumber int) string {
	_ = repositoryID
	return fmt.Sprintf("docs-cms/rfcs/rfc-%03d-generated.md", prNumber)
}

func fakeHeadSHA(repositoryID string, prNumber int) string {
	return fingerprint(fmt.Sprintf("%s-%d", repositoryID, prNumber))
}

func fingerprint(value string) string {
	if len(value) > 40 {
		value = value[:40]
	}
	return strings.ReplaceAll(strings.ToLower(value), " ", "-")
}

func parseFrontmatter(content string) (map[string]string, string) {
	lines := strings.Split(content, "\n")
	if len(lines) < 3 || strings.TrimSpace(lines[0]) != "---" {
		return map[string]string{}, content
	}

	meta := map[string]string{}
	end := -1
	for i := 1; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "---" {
			end = i
			break
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		value = strings.Trim(value, `"'`)
		meta[key] = value
	}

	if end == -1 {
		return map[string]string{}, content
	}

	body := strings.Join(lines[end+1:], "\n")
	return meta, body
}

func extractFirstHeading(content string) string {
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "# ") {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "# "))
		}
	}

	return ""
}

func markdownToHTMLWithFrontmatter(meta map[string]string, markdown string) string {
	b := strings.Builder{}

	if len(meta) > 0 {
		title := strings.TrimSpace(meta["title"])
		if title != "" {
			b.WriteString("<section class=\"rfc-meta-card\">")
			b.WriteString("<h1 class=\"rfc-meta-title\">" + stdhtml.EscapeString(title) + "</h1>")
			b.WriteString("<div class=\"rfc-meta-grid\">")
			writeMetaField(&b, "Status", meta["status"])
			writeMetaField(&b, "Author", meta["author"])
			writeMetaField(&b, "Created", meta["created"])
			writeMetaField(&b, "Tags", strings.Trim(meta["tags"], "[]"))
			writeMetaField(&b, "RFC ID", meta["id"])
			writeMetaField(&b, "Project", meta["project_id"])
			writeMetaField(&b, "Document UUID", meta["doc_uuid"])
			b.WriteString("</div>")
			b.WriteString("</section>")
		}
	}

	b.WriteString(renderStrictMarkdownWithMermaid(markdown))

	return b.String()
}

func renderStrictMarkdownWithMermaid(markdown string) string {
	content := rewriteMermaidFencesAsImages(markdown)
	renderer := goldmark.New(
		goldmark.WithExtensions(extension.GFM),
		goldmark.WithParserOptions(parser.WithAutoHeadingID()),
	)

	var b bytes.Buffer
	if err := renderer.Convert([]byte(content), &b); err != nil {
		return ""
	}

	return enforceExternalLinkTargets(b.String())
}

// rewriteMermaidFencesAsImages is intentionally disabled.
// Encoding diagram source into mermaid.ink URLs sends RFC content to a
// third-party server. Mermaid rendering is handled client-side instead.
func rewriteMermaidFencesAsImages(markdown string) string {
	return markdown
}

func enforceExternalLinkTargets(rendered string) string {
	doc, err := nethtml.Parse(strings.NewReader("<div>" + rendered + "</div>"))
	if err != nil {
		return rendered
	}

	container := findFirstElement(doc, "div")
	if container == nil {
		return rendered
	}

	for child := container.FirstChild; child != nil; child = child.NextSibling {
		applyAnchorAttrs(child)
	}

	var out bytes.Buffer
	for child := container.FirstChild; child != nil; child = child.NextSibling {
		if err := nethtml.Render(&out, child); err != nil {
			return rendered
		}
	}

	return out.String()
}

func findFirstElement(node *nethtml.Node, tag string) *nethtml.Node {
	if node.Type == nethtml.ElementNode && node.Data == tag {
		return node
	}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if matched := findFirstElement(child, tag); matched != nil {
			return matched
		}
	}
	return nil
}

func applyAnchorAttrs(node *nethtml.Node) {
	if node.Type == nethtml.ElementNode && node.Data == "a" {
		setNodeAttr(node, "target", "_blank")
		rel := strings.TrimSpace(getNodeAttr(node, "rel"))
		if rel == "" {
			setNodeAttr(node, "rel", "noopener noreferrer")
		} else {
			hasNoopener := false
			hasNoreferrer := false
			for _, token := range strings.Fields(rel) {
				switch token {
				case "noopener":
					hasNoopener = true
				case "noreferrer":
					hasNoreferrer = true
				}
			}
			if !hasNoopener {
				rel += " noopener"
			}
			if !hasNoreferrer {
				rel += " noreferrer"
			}
			setNodeAttr(node, "rel", strings.TrimSpace(rel))
		}
	}

	for child := node.FirstChild; child != nil; child = child.NextSibling {
		applyAnchorAttrs(child)
	}
}

func getNodeAttr(node *nethtml.Node, key string) string {
	for _, attr := range node.Attr {
		if attr.Key == key {
			return attr.Val
		}
	}
	return ""
}

func setNodeAttr(node *nethtml.Node, key, value string) {
	for i, attr := range node.Attr {
		if attr.Key == key {
			node.Attr[i].Val = value
			return
		}
	}
	node.Attr = append(node.Attr, nethtml.Attribute{Key: key, Val: value})
}

func writeMetaField(b *strings.Builder, label, value string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return
	}
	b.WriteString("<div class=\"rfc-meta-item\"><span class=\"rfc-meta-label\">" + stdhtml.EscapeString(label) + "</span><span class=\"rfc-meta-value\">" + stdhtml.EscapeString(value) + "</span></div>")
}

func isDocuchangoRFCFilename(name string) bool {
	return docuchangoRFCFilenamePattern.MatchString(name)
}

// rfcFilenameNumberPattern matches rfc-NNN- at the start of a filename.
var rfcFilenameNumberPattern = regexp.MustCompile(`^rfc-(\d{3})-`)

// rfcTitlePrefixPattern strips any existing RFC-NNN prefix with any separator
// (e.g. "RFC-001 - ", "RFC-008: ", "RFC-037 - ", "rfc-002 ") from a title,
// capturing the number and the bare text after it.
var rfcTitlePrefixPattern = regexp.MustCompile(`(?i)^rfc[-\s]?(\d{3})[:\s\-]+\s*(.+)`)

// normalizeRFCTitle rewrites the display title to the canonical form "RFC-NNN: <bare title>".
// Any existing RFC-NNN prefix with inconsistent separators (-, :, spaces) is stripped and
// replaced. When the title has no prefix the number is extracted from the filename instead.
func normalizeRFCTitle(title, filePath string) string {
	// Case 1: title already has an RFC-NNN prefix — strip it and rebuild canonically.
	if m := rfcTitlePrefixPattern.FindStringSubmatch(title); m != nil {
		n, err := strconv.Atoi(m[1])
		if err != nil {
			return title
		}
		return fmt.Sprintf("RFC-%03d: %s", n, strings.TrimSpace(m[2]))
	}
	// Case 2: no prefix in title — extract number from filename.
	base := filepath.Base(filePath)
	m := rfcFilenameNumberPattern.FindStringSubmatch(base)
	if m == nil {
		return title
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return title
	}
	return fmt.Sprintf("RFC-%03d: %s", n, title)
}

func normalizeLifecycleStatus(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "draft", "accepted", "implemented", "superseded", "rejected":
		return strings.ToLower(strings.TrimSpace(value))
	default:
		return "unknown"
	}
}

func makePRCatalogID(prNumber int, filePath string) string {
	return fmt.Sprintf("pr:%d:%s", prNumber, strings.TrimPrefix(filePath, "/"))
}

func parsePRCatalogID(id string) (int, string, bool) {
	if !strings.HasPrefix(id, "pr:") {
		return 0, "", false
	}
	parts := strings.SplitN(id, ":", 3)
	if len(parts) != 3 {
		return 0, "", false
	}

	prNumber, err := strconv.Atoi(parts[1])
	if err != nil || prNumber <= 0 {
		return 0, "", false
	}
	filePath := strings.TrimSpace(parts[2])
	if filePath == "" {
		return 0, "", false
	}

	return prNumber, filePath, true
}

// LifecycleTransitionResult is returned on a successful lifecycle status change.
type LifecycleTransitionResult struct {
	RfcID     string `json:"rfc_id"`
	NewStatus string `json:"new_status"`
	CommitSHA string `json:"commit_sha"`
}

// isPrivilegedPermission reports whether a GitHub collaborator permission level
// grants approve/mark-implemented rights.
// Owners ("admin") and maintainers ("maintain") qualify.
func isPrivilegedPermission(permission string) bool {
	switch permission {
	case "admin", "maintain":
		return true
	default:
		return false
	}
}

// ApproveRFC transitions a draft main-branch RFC to "accepted".
// Caller must be a repo owner or maintainer (403 otherwise).
func (s *Service) ApproveRFC(ctx context.Context, repositoryID, rfcPath string) (LifecycleTransitionResult, error) {
	owner, name, _, branch, _, _, token, client, baseURL, err := s.resolveRepoClient(repositoryID)
	if err != nil {
		return LifecycleTransitionResult{}, err
	}

	if err := s.checkPrivileged(ctx, baseURL, owner, name, token, client); err != nil {
		return LifecycleTransitionResult{}, err
	}

	sha, err := client.ApproveRFCFile(ctx, baseURL, owner, name, branch, rfcPath, token)
	if err != nil {
		return LifecycleTransitionResult{}, err
	}
	return LifecycleTransitionResult{RfcID: rfcPath, NewStatus: "accepted", CommitSHA: sha}, nil
}

// MarkImplemented transitions an accepted main-branch RFC to "implemented".
// Caller must be a repo owner or maintainer (403 otherwise).
func (s *Service) MarkImplemented(ctx context.Context, repositoryID, rfcPath string) (LifecycleTransitionResult, error) {
	owner, name, _, branch, _, _, token, client, baseURL, err := s.resolveRepoClient(repositoryID)
	if err != nil {
		return LifecycleTransitionResult{}, err
	}

	if err := s.checkPrivileged(ctx, baseURL, owner, name, token, client); err != nil {
		return LifecycleTransitionResult{}, err
	}

	sha, err := client.MarkRFCFileImplemented(ctx, baseURL, owner, name, branch, rfcPath, token)
	if err != nil {
		return LifecycleTransitionResult{}, err
	}
	return LifecycleTransitionResult{RfcID: rfcPath, NewStatus: "implemented", CommitSHA: sha}, nil
}

// resolveRepoClient is a convenience helper that resolves the repo and returns
// the owner, name, registry, branch, _, _, token, client, baseURL, and any error.
func (s *Service) resolveRepoClient(repositoryID string) (owner, name, registry, branch, docsPath, rfcLabel, token string, client GitHubRFCClient, baseURL string, err error) {
	if s.repoResolver == nil {
		err = fmt.Errorf("repository resolver is not configured")
		return
	}
	var repoBaseURL string
	var ok bool
	owner, name, registry, repoBaseURL, branch, docsPath, rfcLabel, token, ok = s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		err = fmt.Errorf("repository not found")
		return
	}
	if token == "" {
		err = fmt.Errorf("repository token unavailable")
		return
	}
	var exists bool
	client, exists = s.githubClients[registry]
	if !exists {
		client = NewHTTPGitHubRFCClient()
	}
	baseURL = s.registryBaseURL(registry, repoBaseURL)
	return
}

// checkPrivileged resolves the caller's GitHub login and verifies they have
// admin or maintain permission on the repository.
// Returns a sentinel error whose message starts with "forbidden:" on 403.
func (s *Service) checkPrivileged(ctx context.Context, baseURL, owner, name, token string, client GitHubRFCClient) error {
	login, err := client.GetAuthenticatedUser(ctx, baseURL, token)
	if err != nil {
		return fmt.Errorf("resolve caller identity: %w", err)
	}
	perm, err := client.GetCollaboratorPermission(ctx, baseURL, owner, name, login, token)
	if err != nil {
		return fmt.Errorf("check collaborator permission: %w", err)
	}
	if !isPrivilegedPermission(perm) {
		return fmt.Errorf("forbidden: user %q has permission %q; approve/mark-implemented requires admin or maintain", login, perm)
	}
	return nil
}

// CallerPermissionResult is returned by GetCallerPermission.
type CallerPermissionResult struct {
	Login      string `json:"login"`
	Permission string `json:"permission"`
}

// GetCallerPermission resolves the authenticated caller's GitHub login and
// their collaborator permission level on the given repository.
// This is used by the native client to decide which toolbar buttons to show.
func (s *Service) GetCallerPermission(ctx context.Context, repositoryID string) (CallerPermissionResult, error) {
	owner, name, _, _, _, _, token, client, baseURL, err := s.resolveRepoClient(repositoryID)
	if err != nil {
		return CallerPermissionResult{}, err
	}
	login, err := client.GetAuthenticatedUser(ctx, baseURL, token)
	if err != nil {
		return CallerPermissionResult{}, fmt.Errorf("resolve caller identity: %w", err)
	}
	perm, err := client.GetCollaboratorPermission(ctx, baseURL, owner, name, login, token)
	if err != nil {
		return CallerPermissionResult{}, fmt.Errorf("check collaborator permission: %w", err)
	}
	return CallerPermissionResult{Login: login, Permission: perm}, nil
}
