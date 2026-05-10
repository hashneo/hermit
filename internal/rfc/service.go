package rfc

import (
	"bytes"
	"context"
	"fmt"
	stdhtml "html"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

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
	Labels          []string `json:"labels,omitempty"`
	Commentable     bool     `json:"commentable"`
	StatusMutable   bool     `json:"status_mutable"`
	HTMLURL         string   `json:"html_url,omitempty"`
}

type DocumentView struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	Path           string `json:"path"`
	MarkdownSource string `json:"markdown_source"`
}

type Service struct {
	rfcDir        string
	repoResolver  RepositoryResolver
	githubClients map[string]GitHubRFCClient
	registryBases map[string]string
}

var docuchangoRFCFilenamePattern = regexp.MustCompile(`^rfc-[0-9]{3}-[a-z0-9]+(?:-[a-z0-9]+)*\.md$`)

type RepositoryResolver interface {
	ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool)
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

func (s *Service) ListRFCsByRepository(ctx context.Context, repositoryID string) ([]CatalogItem, error) {
	if s.repoResolver == nil {
		return nil, fmt.Errorf("repository resolver is not configured")
	}

	owner, name, registry, branch, docsPath, rfcLabel, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return nil, fmt.Errorf("repository not found")
	}
	if token == "" {
		return nil, fmt.Errorf("repository token unavailable")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}

	baseURL := s.registryBaseURL(registry)
	mainItems, err := client.ListRFCs(ctx, baseURL, owner, name, branch, docsPath, token)
	if err != nil {
		return nil, err
	}

	items := make([]CatalogItem, 0, len(mainItems))
	for _, item := range mainItems {
		lifecycleStatus := "unknown"
		title := item.Title
		if view, viewErr := client.GetRFC(ctx, baseURL, owner, name, branch, item.Path, token); viewErr == nil {
			title = view.Title
			meta, _ := parseFrontmatter(view.MarkdownSource)
			lifecycleStatus = normalizeLifecycleStatus(meta["status"])
		}
		title = normalizeRFCTitle(title, item.Path)

		items = append(items, CatalogItem{
			ID:              item.ID,
			Title:           title,
			Path:            item.Path,
			SourceType:      "main",
			SourceLabel:     "Main branch",
			AllowedActions:  []string{"view"},
			LifecycleStatus: lifecycleStatus,
			Commentable:     false,
			StatusMutable:   true,
			HTMLURL:         item.HTMLURL,
		})
	}

	prItems, err := client.ListReviewReadyRFCs(ctx, baseURL, owner, name, docsPath, rfcLabel, token)
	if err != nil {
		return nil, err
	}
	for _, prItem := range prItems {
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

	return items, nil
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

	owner, name, registry, branch, _, rfcLabel, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
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
	baseURL := s.registryBaseURL(registry)

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
	CommitSHA        string `json:"commit_sha,omitempty"`        // SHA of the acceptance commit on the PR branch
	HandedToIronhide bool   `json:"handed_to_ironhide,omitempty"` // true when ironhide labels were applied instead of direct merge
}

// AcceptRFC marks a PR RFC as accepted.
//
// Flow:
//  1. Fetch the current RFC file from the PR branch.
//  2. Rewrite frontmatter status to "accepted" and commit (skipped if already accepted).
//  3. Check whether both ironhide labels exist on the repository.
//     - If YES: add ironhide-review and ironhide-merge labels to the PR and return
//       HandedToIronhide=true.  Ironhide will handle merging.
//     - If NO:  attempt a direct squash-merge.  If CI blocks the merge, return
//       BlockedByCI=true and CommitSHA so the caller can poll and retry.
func (s *Service) AcceptRFC(ctx context.Context, repositoryID string, prNumber int, filePath string) (AcceptRFCResult, error) {
	if s.repoResolver == nil {
		return AcceptRFCResult{}, fmt.Errorf("repository resolver is not configured")
	}
	owner, name, registry, _, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
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
	baseURL := s.registryBaseURL(registry)

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

	// 4b. Manual path: attempt immediate squash-merge.
	merged, blockedByCI, err := client.MergePR(ctx, baseURL, owner, name, prNumber, token)
	if err != nil {
		return AcceptRFCResult{}, fmt.Errorf("merge PR: %w", err)
	}

	return AcceptRFCResult{Merged: merged, BlockedByCI: blockedByCI, CommitSHA: sha}, nil
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
	owner, name, registry, _, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
	if !ok {
		return CIStatusResult{Status: "pending"}, fmt.Errorf("repository not found")
	}

	client, ok := s.githubClients[registry]
	if !ok {
		client = NewHTTPGitHubRFCClient()
	}
	baseURL := s.registryBaseURL(registry)

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

	owner, name, registry, _, docsPath, rfcLabel, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
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

	baseURL := s.registryBaseURL(registry)

	// List PR files to find the RFC path.
	prFiles, err := client.ListReviewReadyRFCs(ctx, baseURL, owner, name, docsPath, rfcLabel, token)
	if err != nil {
		return DocumentView{}, fmt.Errorf("list PR RFCs: %w", err)
	}

	var filePath string
	for _, item := range prFiles {
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

	owner, name, registry, branch, _, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
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

	baseURL := s.registryBaseURL(registry)
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

func (s *Service) registryBaseURL(registry string) string {
	if baseURL, ok := s.registryBases[registry]; ok && strings.TrimSpace(baseURL) != "" {
		return baseURL
	}
	return "https://api.github.com"
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
