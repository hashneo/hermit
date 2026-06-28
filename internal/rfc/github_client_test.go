package rfc

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPGitHubRFCClient_ListRFCs_FiltersNonDocuchangoFilenames(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode([]map[string]string{
			{"name": "rfc-001-valid-name.md", "path": "docs-cms/rfcs/rfc-001-valid-name.md", "type": "file"},
			{"name": "invalid-name.md", "path": "docs-cms/rfcs/invalid-name.md", "type": "file"},
			{"name": "rfc-002-upper-Case.md", "path": "docs-cms/rfcs/rfc-002-upper-Case.md", "type": "file"},
		})
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListRFCs(context.Background(), server.URL, "owner", "repo", "main", "docs-cms/rfcs", "token")
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}

	if len(items) != 1 {
		t.Fatalf("expected one valid docuchango RFC file, got %d", len(items))
	}
	if items[0].ID != "docs-cms/rfcs/rfc-001-valid-name.md" {
		t.Fatalf("expected valid RFC path, got %q", items[0].ID)
	}
}

func TestHTTPGitHubRFCClient_ListRFCs_MissingDocsDirectoryIsEmpty(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListRFCs(context.Background(), server.URL, "owner", "repo", "main", "docs-cms/rfcs", "token")
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("expected no RFC files, got %d", len(items))
	}
}

func TestHTTPGitHubRFCClient_ListRFCs_UsesDocuchangoProjectConfigAndSubprojects(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/owner/repo/contents/docs-project.yaml":
			writeContentResponse(t, w, "docs-project.yaml", `project:
  id: parent
  name: Parent
subprojects:
  - services/service-a
indexes:
  - name: RFC Index
    path: docs/rfc-index.md
    targets:
      - docs/proposals/*.md
`)
		case "/repos/owner/repo/contents/services/service-a/docs-project.yaml":
			writeContentResponse(t, w, "docs-project.yaml", `project:
  id: service-a
  name: Service A
structure:
  docs_roots: [docs]
  doc_types:
    rfc:
      schema: rfc
      folders: [proposals]
`)
		case "/repos/owner/repo/contents/services/service-a/docs/proposals":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"path": "services/service-a/docs/proposals/rfc-010-subproject.md", "type": "file"},
				{"path": "services/service-a/docs/proposals/not-rfc.md", "type": "file"},
			})
		case "/repos/owner/repo/contents/docs/proposals":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"path": "docs/proposals/rfc-011-indexed.md", "type": "file"},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListRFCs(context.Background(), server.URL, "owner", "repo", "main", "legacy/rfcs", "token")
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}

	got := make([]string, 0, len(items))
	for _, item := range items {
		got = append(got, item.Path)
	}
	want := []string{"docs/proposals/rfc-011-indexed.md", "services/service-a/docs/proposals/rfc-010-subproject.md"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("paths = %v, want %v", got, want)
	}
}

func TestHTTPGitHubRFCClient_ListRFCs_ProbesDocuchangoProjectConfigFormats(t *testing.T) {
	requested := make([]string, 0)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requested = append(requested, r.URL.Path)
		switch r.URL.Path {
		case "/repos/owner/repo/contents/docs-project.yaml":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/docs-project.yml":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/docs-project.json":
			writeContentResponse(t, w, "docs-project.json", `{
  "project": {"id": "json-root", "name": "JSON Root"},
  "structure": {
    "docs_roots": ["docs"],
    "doc_types": {
      "rfc": {"schema": "rfc", "folders": ["proposals"]}
    }
  }
}`)
		case "/repos/owner/repo/contents/docs/proposals":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"path": "docs/proposals/rfc-020-json-root.md", "type": "file"},
			})
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListRFCs(context.Background(), server.URL, "owner", "repo", "main", "legacy/rfcs", "token")
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}
	if len(items) != 1 || items[0].Path != "docs/proposals/rfc-020-json-root.md" {
		t.Fatalf("expected JSON config RFC path, got %+v", items)
	}

	wantPrefix := []string{
		"/repos/owner/repo/contents/docs-project.yaml",
		"/repos/owner/repo/contents/docs-project.yml",
		"/repos/owner/repo/contents/docs-project.json",
	}
	if strings.Join(requested[:len(wantPrefix)], ",") != strings.Join(wantPrefix, ",") {
		t.Fatalf("probe order = %v, want prefix %v", requested, wantPrefix)
	}
}

func TestHTTPGitHubRFCClient_ListRFCs_LoadsTomlRootAndYMLSubprojectConfig(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/owner/repo/contents/docs-project.yaml",
			"/repos/owner/repo/contents/docs-project.yml",
			"/repos/owner/repo/contents/docs-project.json":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/docs-project.toml":
			writeContentResponse(t, w, "docs-project.toml", `
[project]
id = "toml-root"
name = "TOML Root"

[[subprojects]]
path = "services/service-a"
`)
		case "/repos/owner/repo/contents/services/service-a/docs-project.yaml":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/services/service-a/docs-project.yml":
			writeContentResponse(t, w, "docs-project.yml", `project:
  id: service-a
  name: Service A
structure:
  docs_roots: [docs]
  doc_types:
    rfc:
      schema: rfc
      folders: [proposals]
`)
		case "/repos/owner/repo/contents/services/service-a/docs-project.json":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/services/service-a/docs-project.toml":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/rfcs":
			http.NotFound(w, r)
		case "/repos/owner/repo/contents/services/service-a/docs/proposals":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"path": "services/service-a/docs/proposals/rfc-021-yml-subproject.md", "type": "file"},
			})
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	items, err := client.ListRFCs(context.Background(), server.URL, "owner", "repo", "main", "legacy/rfcs", "token")
	if err != nil {
		t.Fatalf("ListRFCs returned error: %v", err)
	}
	if len(items) != 1 || items[0].Path != "services/service-a/docs/proposals/rfc-021-yml-subproject.md" {
		t.Fatalf("expected subproject RFC path from TOML/YML config, got %+v", items)
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_FiltersDraftPRsAndRFCPaths(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls" && r.URL.Query().Get("state") == "open":
			if got := r.URL.Query().Get("labels"); got != "" {
				t.Fatalf("expected no labels query parameter, got %q", got)
			}
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 10, "draft": false, "head": map[string]any{"sha": "sha-ready"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
				{"number": 11, "draft": true, "head": map[string]any{"sha": "sha-draft"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/10/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-001-main-list.md", "status": "modified"},
				{"filename": "docs-cms/notes.md", "status": "modified"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/10":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"mergeable":       true,
				"mergeable_state": "clean",
			})
		case handleWorkflowLabelTestRequest(w, r):
			return
		case r.URL.Path == "/repos/owner/repo/pulls/11/files":
			t.Fatalf("draft PR file list should not be requested")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-001-main-list.md":
			if r.URL.Query().Get("ref") != "sha-ready" {
				t.Fatalf("expected RFC content request at head sha, got %q", r.URL.Query().Get("ref"))
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-001-main-list.md",
				"path":    "docs-cms/rfcs/rfc-001-main-list.md",
				"content": "LS0tCnRpdGxlOiBSZWFkeSBQUiBSRkMKLS0tCgojIFJlYWR5IFBSIFJGQwo=",
			})
		default:
			if isDocuchangoProjectConfigProbe(r) {
				http.NotFound(w, r)
				return
			}
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	result, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "hermit:rfc-ready", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}
	items := result.Items

	if len(items) != 1 {
		t.Fatalf("expected one review-ready RFC item, got %d", len(items))
	}
	if result.OpenPRCount != 2 {
		t.Fatalf("expected open PR count 2, got %d", result.OpenPRCount)
	}
	if result.PRStates.Ready != 1 || result.PRStates.NeedsReview != 1 {
		t.Fatalf("expected PR state counts ready=1 needs_review=1, got %+v", result.PRStates)
	}
	if items[0].PRNumber != 10 {
		t.Fatalf("expected PR number 10, got %d", items[0].PRNumber)
	}
	if items[0].Mergeable == nil || *items[0].Mergeable != true {
		t.Fatalf("expected PR mergeable true, got %#v", items[0].Mergeable)
	}
	if items[0].MergeableState != "clean" {
		t.Fatalf("expected PR mergeable_state clean, got %q", items[0].MergeableState)
	}
	if items[0].Path != "docs-cms/rfcs/rfc-001-main-list.md" {
		t.Fatalf("expected RFC path, got %q", items[0].Path)
	}
	if items[0].Title != "Ready PR RFC" {
		t.Fatalf("expected title from markdown content, got %q", items[0].Title)
	}
	if !containsString(items[0].Labels, "hermit:rfc-ready") || !containsString(items[0].Labels, "rfc:review") {
		t.Fatalf("expected labels to contain hermit:rfc-ready and rfc:review, got %v", items[0].Labels)
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_AutoLabelsRFCWithoutReadyLabel(t *testing.T) {
	var appliedLabels []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 20, "draft": false, "head": map[string]any{"sha": "sha-labeled"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
				{"number": 21, "draft": false, "head": map[string]any{"sha": "sha-unlabeled"}, "labels": []map[string]any{}},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/20/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-010-labeled.md", "status": "added"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/20":
			mergeable := false
			_ = json.NewEncoder(w).Encode(map[string]any{
				"mergeable":       mergeable,
				"mergeable_state": "dirty",
			})
		case r.URL.Path == "/repos/owner/repo/pulls/21/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-011-unlabeled.md", "status": "added"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/21":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"mergeable":       true,
				"mergeable_state": "clean",
			})
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-010-labeled.md":
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-010-labeled.md",
				"path":    "docs-cms/rfcs/rfc-010-labeled.md",
				"content": "IyBMYWJlbGVkIFJGQwo=",
			})
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-011-unlabeled.md":
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-011-unlabeled.md",
				"path":    "docs-cms/rfcs/rfc-011-unlabeled.md",
				"content": "IyBVbmxhYmVsZWQgUkZDCg==",
			})
		case isIssueLabelPost(r):
			var payload struct {
				Labels []string `json:"labels"`
			}
			_ = json.NewDecoder(r.Body).Decode(&payload)
			appliedLabels = append(appliedLabels, payload.Labels...)
			_ = json.NewEncoder(w).Encode(payload)
		case handleWorkflowLabelTestRequest(w, r):
			return
		default:
			if isDocuchangoProjectConfigProbe(r) {
				http.NotFound(w, r)
				return
			}
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	result, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "hermit:rfc-ready", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}
	items := result.Items

	if len(items) != 2 {
		t.Fatalf("expected labeled and auto-labeled PR RFCs, got %d items", len(items))
	}
	if result.OpenPRCount != 2 {
		t.Fatalf("expected open PR count 2, got %d", result.OpenPRCount)
	}
	if result.PRStates.Conflicted != 1 || result.PRStates.Ready != 1 {
		t.Fatalf("expected PR state counts conflicted=1 ready=1, got %+v", result.PRStates)
	}
	if items[0].Mergeable == nil || *items[0].Mergeable != false {
		t.Fatalf("expected PR mergeable false, got %#v", items[0].Mergeable)
	}
	if items[0].MergeableState != "dirty" {
		t.Fatalf("expected PR mergeable_state dirty, got %q", items[0].MergeableState)
	}
	if containsString(appliedLabels, "hermit:rfc-ready") {
		t.Fatalf("expected discovery not to auto-apply legacy RFC ready label, got %v", appliedLabels)
	}
	if !containsString(appliedLabels, "rfc:review") {
		t.Fatalf("expected auto-applied RFC review workflow label, got %v", appliedLabels)
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_UsesDocuchangoIndexTargets(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/owner/repo/contents/docs-project.yaml":
			writeContentResponse(t, w, "docs-project.yaml", `project:
  id: indexed
  name: Indexed
indexes:
  - name: RFC Index
    path: docs/rfc-index.md
    targets: [docs/proposals/*.md]
`)
		case "/repos/owner/repo/pulls":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 30, "draft": false, "head": map[string]any{"sha": "sha-indexed"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
			})
		case "/repos/owner/repo/pulls/30/files":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"filename": "docs/proposals/rfc-030-indexed.md", "status": "added", "additions": 5},
			})
		case "/repos/owner/repo/pulls/30":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"mergeable":       true,
				"mergeable_state": "clean",
			})
		case "/repos/owner/repo/labels/rfc:review":
			http.NotFound(w, r)
		case "/repos/owner/repo/labels":
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rfc:review"})
		case "/repos/owner/repo/issues/30/labels":
			_ = json.NewEncoder(w).Encode(map[string]any{"labels": []string{"rfc:review"}})
		case "/repos/owner/repo/contents/docs/proposals/rfc-030-indexed.md":
			writeContentResponse(t, w, "rfc-030-indexed.md", "---\ntitle: Indexed RFC\n---\n# Indexed RFC\n")
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	result, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "hermit:rfc-ready", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}
	items := result.Items
	if len(items) != 1 || items[0].Path != "docs/proposals/rfc-030-indexed.md" {
		t.Fatalf("expected indexed RFC PR item, got %+v", items)
	}
	if result.OpenPRCount != 1 {
		t.Fatalf("expected open PR count 1, got %d", result.OpenPRCount)
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_AutoLabelsDocuchangoDocumentTypes(t *testing.T) {
	var appliedLabels []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/contents/docs-project.yaml":
			writeContentResponse(t, w, "docs-project.yaml", `project:
  id: docs
  name: Docs
structure:
  adr_dir: docs-cms/adr
  rfc_dir: docs-cms/rfcs
  memo_dir: docs-cms/memos
  prd_dir: docs-cms/prd
  document_folders:
    - docs-cms/adr
    - docs-cms/rfcs
    - docs-cms/memos
    - docs-cms/prd
`)
		case r.URL.Path == "/repos/owner/repo/pulls":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 40, "title": "docs: normalize publishing", "draft": false, "head": map[string]any{"sha": "sha-docs", "ref": "docs-branch"}, "html_url": "https://github.test/owner/repo/pull/40", "labels": []map[string]any{}},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/40/files":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"filename": "docs-cms/adr/adr-001-choice.md", "status": "modified", "additions": 2, "deletions": 1},
				{"filename": "docs-cms/memos/memo-001-note.md", "status": "added", "additions": 3, "deletions": 0},
				{"filename": "docs-cms/prd/prd-001-product.md", "status": "added", "additions": 4, "deletions": 0},
				{"filename": "docs-cms/rfcs/rfc-001-plan.md", "status": "added", "additions": 5, "deletions": 2},
				{"filename": "README.md", "status": "modified", "additions": 1, "deletions": 1},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/40":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"mergeable":       true,
				"mergeable_state": "unstable",
			})
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/adr/adr-001-choice.md":
			writeContentResponse(t, w, "adr-001-choice.md", "---\ntitle: Architecture Choice\n---\n# Architecture Choice\n")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/memos/memo-001-note.md":
			writeContentResponse(t, w, "memo-001-note.md", "---\ntitle: Planning Memo\n---\n# Planning Memo\n")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/prd/prd-001-product.md":
			writeContentResponse(t, w, "prd-001-product.md", "---\ntitle: Product Direction\n---\n# Product Direction\n")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-001-plan.md":
			writeContentResponse(t, w, "rfc-001-plan.md", "---\ntitle: Implementation Plan\n---\n# Implementation Plan\n")
		case isIssueLabelPost(r):
			var payload struct {
				Labels []string `json:"labels"`
			}
			_ = json.NewDecoder(r.Body).Decode(&payload)
			appliedLabels = append(appliedLabels, payload.Labels...)
			_ = json.NewEncoder(w).Encode(payload)
		case handleWorkflowLabelTestRequest(w, r):
			return
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	result, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "hermit:rfc-ready", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}
	if len(result.Items) != 4 {
		t.Fatalf("expected all reviewable docs-cms documents, got %+v", result.Items)
	}
	if result.PRStates.Failed != 1 {
		t.Fatalf("expected failed PR state count 1, got %+v", result.PRStates)
	}
	expected := []struct {
		docType string
		path    string
		title   string
	}{
		{docType: "adr", path: "docs-cms/adr/adr-001-choice.md", title: "Architecture Choice"},
		{docType: "prd", path: "docs-cms/prd/prd-001-product.md", title: "Product Direction"},
		{docType: "rfc", path: "docs-cms/rfcs/rfc-001-plan.md", title: "Implementation Plan"},
		{docType: "memo", path: "docs-cms/memos/memo-001-note.md", title: "Planning Memo"},
	}
	for i, want := range expected {
		got := result.Items[i]
		if got.DocumentType != want.docType || got.Path != want.path || got.Title != want.title {
			t.Fatalf("item %d mismatch: got type=%q path=%q title=%q, want %+v", i, got.DocumentType, got.Path, got.Title, want)
		}
		if got.PRNumber != 40 || got.PRTitle != "docs: normalize publishing" || got.HeadRef != "docs-branch" {
			t.Fatalf("item %d missing PR identity metadata: %+v", i, got)
		}
		if got.ChangedFiles != 5 || got.Additions != 15 || got.Deletions != 4 {
			t.Fatalf("item %d missing PR diff stats: changed=%d additions=%d deletions=%d", i, got.ChangedFiles, got.Additions, got.Deletions)
		}
		if got.HTMLURL != "https://github.test/owner/repo/pull/40" {
			t.Fatalf("item %d missing PR html url: %q", i, got.HTMLURL)
		}
	}
	for _, label := range []string{"adr:review", "memo:review", "prd:review", "rfc:review"} {
		if !containsString(appliedLabels, label) {
			t.Fatalf("expected applied labels to contain %s, got %v", label, appliedLabels)
		}
	}
}

func TestHTTPGitHubRFCClient_ListReviewReadyRFCs_DiscoversDocsCMSDocumentsWithoutProjectConfig(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case isDocuchangoProjectConfigProbe(r):
			http.NotFound(w, r)
		case r.URL.Path == "/repos/owner/repo/pulls":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"number": 41, "title": "docs: add workflow references", "draft": false, "head": map[string]any{"sha": "sha-fallback", "ref": "docs-workflow"}, "labels": []map[string]any{{"name": "hermit:rfc-ready"}}},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/41/files":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"filename": "docs-cms/README.md", "status": "modified", "additions": 1, "deletions": 0},
				{"filename": "docs-cms/adr/adr-013-github-pr-state-label-schema.md", "status": "added", "additions": 12, "deletions": 1},
				{"filename": "docs-cms/memos/memo-002-metro-workflow-spec-reference.md", "status": "added", "additions": 20, "deletions": 2},
				{"filename": "docs-cms/rfcs/rfc-004-pr-triage-and-merge-planning-workflow.md", "status": "added", "additions": 30, "deletions": 3},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/41":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"mergeable":       true,
				"mergeable_state": "clean",
			})
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/adr/adr-013-github-pr-state-label-schema.md":
			writeContentResponse(t, w, "adr-013-github-pr-state-label-schema.md", "---\ntitle: GitHub PR State Label Schema\n---\n# GitHub PR State Label Schema\n")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/memos/memo-002-metro-workflow-spec-reference.md":
			writeContentResponse(t, w, "memo-002-metro-workflow-spec-reference.md", "---\ntitle: Metro Workflow Spec Reference\n---\n# Metro Workflow Spec Reference\n")
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-004-pr-triage-and-merge-planning-workflow.md":
			writeContentResponse(t, w, "rfc-004-pr-triage-and-merge-planning-workflow.md", "---\ntitle: PR Triage and Merge Planning Workflow\n---\n# PR Triage and Merge Planning Workflow\n")
		case handleWorkflowLabelTestRequest(w, r):
			return
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	result, err := client.ListReviewReadyRFCs(context.Background(), server.URL, "owner", "repo", "docs-cms/rfcs", "hermit:rfc-ready", "token")
	if err != nil {
		t.Fatalf("ListReviewReadyRFCs returned error: %v", err)
	}
	if len(result.Items) != 3 {
		t.Fatalf("expected ADR, memo, and RFC docs-cms review items, got %+v", result.Items)
	}

	expectedTypes := []string{"adr", "rfc", "memo"}
	for i, wantType := range expectedTypes {
		got := result.Items[i]
		if got.DocumentType != wantType {
			t.Fatalf("item %d document type = %q, want %q", i, got.DocumentType, wantType)
		}
		if got.PRNumber != 41 || got.PRTitle != "docs: add workflow references" {
			t.Fatalf("item %d missing PR metadata: %+v", i, got)
		}
		if got.ChangedFiles != 4 || got.Additions != 63 || got.Deletions != 6 {
			t.Fatalf("item %d missing PR stats: changed=%d additions=%d deletions=%d", i, got.ChangedFiles, got.Additions, got.Deletions)
		}
	}
}

func TestHTTPGitHubRFCClient_GetRFCFromPullRequest_UsesHeadSHAAndValidatesMembership(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/owner/repo/pulls/23":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"head": map[string]any{"sha": "sha-pr-23"},
			})
		case r.URL.Path == "/repos/owner/repo/pulls/23/files":
			_ = json.NewEncoder(w).Encode([]map[string]string{
				{"filename": "docs-cms/rfcs/rfc-002-target.md", "status": "modified"},
			})
		case r.URL.Path == "/repos/owner/repo/contents/docs-cms/rfcs/rfc-002-target.md":
			if r.URL.Query().Get("ref") != "sha-pr-23" {
				t.Fatalf("expected content lookup at PR head sha, got %q", r.URL.Query().Get("ref"))
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"name":    "rfc-002-target.md",
				"path":    "docs-cms/rfcs/rfc-002-target.md",
				"content": "IyBQUiBkb2N1bWVudA==",
			})
		default:
			t.Fatalf("unexpected request path: %s?%s", r.URL.Path, r.URL.RawQuery)
		}
	}))
	defer server.Close()

	client := NewHTTPGitHubRFCClient()
	view, err := client.GetRFCFromPullRequest(context.Background(), server.URL, "owner", "repo", 23, "docs-cms/rfcs/rfc-002-target.md", "token")
	if err != nil {
		t.Fatalf("GetRFCFromPullRequest returned error: %v", err)
	}

	if !strings.Contains(view.MarkdownSource, "PR document") {
		t.Fatalf("expected markdown_source to include markdown content")
	}

	_, err = client.GetRFCFromPullRequest(context.Background(), server.URL, "owner", "repo", 23, "docs-cms/rfcs/rfc-999-missing.md", "token")
	if err == nil {
		t.Fatalf("expected error when requested file is not part of PR")
	}
}

func handleWorkflowLabelTestRequest(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/labels/") {
		http.NotFound(w, r)
		return true
	}
	if r.Method == http.MethodPost && r.URL.Path == "/repos/owner/repo/labels" {
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"name": "workflow"})
		return true
	}
	if isIssueLabelPost(r) {
		var payload struct {
			Labels []string `json:"labels"`
		}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		_ = json.NewEncoder(w).Encode(payload)
		return true
	}
	return false
}

func isIssueLabelPost(r *http.Request) bool {
	return r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/repos/owner/repo/issues/") && strings.HasSuffix(r.URL.Path, "/labels")
}

func isDocuchangoProjectConfigProbe(r *http.Request) bool {
	return r.Method == http.MethodGet &&
		(strings.HasSuffix(r.URL.Path, "docs-project.yaml") ||
			strings.HasSuffix(r.URL.Path, "docs-project.yml") ||
			strings.HasSuffix(r.URL.Path, "docs-project.json") ||
			strings.HasSuffix(r.URL.Path, "docs-project.toml"))
}

func writeContentResponse(t *testing.T, w http.ResponseWriter, name, content string) {
	t.Helper()
	_ = json.NewEncoder(w).Encode(map[string]string{
		"name":    name,
		"path":    name,
		"content": base64.StdEncoding.EncodeToString([]byte(content)),
	})
}
