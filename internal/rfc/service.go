package rfc

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	stdhtml "html"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
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
	RenderedHTML   string   `json:"rendered_html"`
	MarkdownSource string   `json:"markdown_source"`
	AnchorMap      []Anchor `json:"anchor_map"`
}

type CatalogItem struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Path  string `json:"path"`
}

type DocumentView struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	Path           string `json:"path"`
	RenderedHTML   string `json:"rendered_html"`
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
	ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, token string, ok bool)
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
		RenderedHTML:   markdownToHTMLWithFrontmatter(map[string]string{}, source),
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
			ID:    entry.Name(),
			Title: title,
			Path:  filepath.ToSlash(fullPath),
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
		RenderedHTML:   markdownToHTMLWithFrontmatter(frontmatter, markdownBody),
		MarkdownSource: markdown,
	}, nil
}

func (s *Service) ListRFCsByRepository(ctx context.Context, repositoryID string) ([]CatalogItem, error) {
	if s.repoResolver == nil {
		return nil, fmt.Errorf("repository resolver is not configured")
	}

	owner, name, registry, branch, docsPath, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
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
	return client.ListRFCs(ctx, baseURL, owner, name, branch, docsPath, token)
}

func (s *Service) RenderRFCByRepository(ctx context.Context, repositoryID, rfcID string) (DocumentView, error) {
	if s.repoResolver == nil {
		return DocumentView{}, fmt.Errorf("repository resolver is not configured")
	}

	owner, name, registry, branch, _, token, ok := s.repoResolver.ResolveRepositoryAccess(repositoryID)
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

func rewriteMermaidFencesAsImages(markdown string) string {
	lines := strings.Split(markdown, "\n")
	out := strings.Builder{}

	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if !strings.HasPrefix(strings.TrimSpace(line), "```mermaid") {
			out.WriteString(line)
			if i < len(lines)-1 {
				out.WriteString("\n")
			}
			continue
		}

		diagramLines := []string{}
		closed := false
		for j := i + 1; j < len(lines); j++ {
			if strings.HasPrefix(strings.TrimSpace(lines[j]), "```") {
				definition := strings.TrimSpace(strings.Join(diagramLines, "\n"))
				if definition != "" {
					encoded := url.PathEscape(base64.StdEncoding.EncodeToString([]byte(definition)))
					out.WriteString("![Mermaid diagram](https://mermaid.ink/img/" + encoded + ")")
				}
				if j < len(lines)-1 {
					out.WriteString("\n")
				}
				i = j
				closed = true
				break
			}
			diagramLines = append(diagramLines, lines[j])
		}

		if closed {
			continue
		}

		out.WriteString(line)
		for _, diagramLine := range diagramLines {
			out.WriteString("\n")
			out.WriteString(diagramLine)
		}
	}

	return out.String()
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
