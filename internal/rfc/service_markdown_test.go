package rfc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMarkdownToHTMLWithFrontmatter_UsesStrictMarkdownRenderer(t *testing.T) {
	markdown := "# Title\n\n- alpha\n- beta\n\n| A | B |\n| - | - |\n| 1 | 2 |"

	html := markdownToHTMLWithFrontmatter(nil, markdown)

	if !strings.Contains(html, "<ul>") {
		t.Fatalf("expected markdown list to render as <ul>, got %q", html)
	}
	if !strings.Contains(html, "<table>") {
		t.Fatalf("expected markdown table to render as <table>, got %q", html)
	}
}

func TestMarkdownToHTMLWithFrontmatter_PassesMermaidFenceThrough(t *testing.T) {
	markdown := "## Diagram\n\n```mermaid\ngraph TD\nA-->B\n```"

	html := markdownToHTMLWithFrontmatter(nil, markdown)

	// mermaid.ink must NOT be referenced — that would leak RFC content to a third party.
	if strings.Contains(html, "mermaid.ink") {
		t.Fatalf("mermaid.ink must not appear in rendered output (security leak), got %q", html)
	}
	// Fenced block passes through as a <code class="language-mermaid"> block for client-side rendering.
	if !strings.Contains(html, "language-mermaid") {
		t.Fatalf("expected mermaid fence to pass through as language-mermaid code block, got %q", html)
	}
}

func TestMarkdownToHTMLWithFrontmatter_AddsExternalLinkTarget(t *testing.T) {
	markdown := "[Hermit](https://example.com)"

	html := markdownToHTMLWithFrontmatter(nil, markdown)

	if !strings.Contains(html, `target="_blank"`) {
		t.Fatalf("expected links to open in a new tab, got %q", html)
	}
	if !strings.Contains(html, `rel="noopener noreferrer"`) {
		t.Fatalf("expected links to include safe rel attributes, got %q", html)
	}
}

func TestIsDocuchangoRFCFilename(t *testing.T) {
	tests := []struct {
		name string
		want bool
	}{
		{name: "rfc-001-valid-name.md", want: true},
		{name: "rfc-123-abc123.md", want: true},
		{name: "rfc-12-too-short.md", want: false},
		{name: "rfc-001-Invalid.md", want: false},
		{name: "rfc-001-missing_extension", want: false},
		{name: "memo-001-not-rfc.md", want: false},
	}

	for _, tc := range tests {
		if got := isDocuchangoRFCFilename(tc.name); got != tc.want {
			t.Fatalf("isDocuchangoRFCFilename(%q) = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestListRFCs_FiltersNonDocuchangoFilenames(t *testing.T) {
	tempDir := t.TempDir()
	rfcsDir := filepath.Join(tempDir, "rfcs")
	if err := os.MkdirAll(rfcsDir, 0o755); err != nil {
		t.Fatalf("mkdir rfcs dir: %v", err)
	}

	validFile := filepath.Join(rfcsDir, "rfc-001-valid-name.md")
	invalidFile := filepath.Join(rfcsDir, "not-a-docuchango-name.md")
	if err := os.WriteFile(validFile, []byte("# Valid\n"), 0o600); err != nil {
		t.Fatalf("write valid rfc: %v", err)
	}
	if err := os.WriteFile(invalidFile, []byte("# Invalid\n"), 0o600); err != nil {
		t.Fatalf("write invalid rfc: %v", err)
	}

	service := NewService()
	service.rfcDir = rfcsDir

	items, err := service.ListRFCs()
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 RFC item after filename filtering, got %d", len(items))
	}
	if items[0].ID != "rfc-001-valid-name.md" {
		t.Fatalf("expected valid RFC file to be listed, got %q", items[0].ID)
	}
	if items[0].SourceType != "main" {
		t.Fatalf("expected source_type main, got %q", items[0].SourceType)
	}
	if items[0].Commentable {
		t.Fatalf("expected main RFC entry to be non-commentable")
	}
}

func TestParsePRCatalogID(t *testing.T) {
	prNumber, path, ok := parsePRCatalogID("pr:77:docs-cms/rfcs/rfc-077-test.md")
	if !ok {
		t.Fatalf("expected valid PR catalog id")
	}
	if prNumber != 77 {
		t.Fatalf("expected pr number 77, got %d", prNumber)
	}
	if path != "docs-cms/rfcs/rfc-077-test.md" {
		t.Fatalf("unexpected path %q", path)
	}

	if _, _, ok := parsePRCatalogID("rfc-077-test.md"); ok {
		t.Fatalf("expected invalid non-pr catalog id")
	}
}
