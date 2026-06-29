package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRepoReviewDocsValidatesCombinedState(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/repositories/repo-1/rfcs" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("refresh") != "true" {
			t.Fatalf("refresh query = %q, want true", r.URL.Query().Get("refresh"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"items": [
				{"id":"pr:1:docs-cms/adr/adr-001.md","title":"Choice","path":"docs-cms/adr/adr-001.md","source_type":"pull_request","source_label":"PR #1","pr_number":1,"pr_title":"docs: references","pr_state":"closed","pr_merged":true,"head_ref":"docs","mergeable_state":"unknown","document_type":"adr","labels":["adr:needs-review","hermit:rfc-ready"],"changed_files":33,"additions":8624,"deletions":25,"html_url":"https://example.test/pr/1"},
				{"id":"pr:1:docs-cms/rfcs/rfc-001.md","title":"Plan","path":"docs-cms/rfcs/rfc-001.md","source_type":"pull_request","source_label":"PR #1","pr_number":1,"pr_title":"docs: references","pr_state":"closed","pr_merged":true,"head_ref":"docs","mergeable_state":"unknown","document_type":"rfc","labels":["rfc:needs-review","hermit:rfc-ready"],"changed_files":33,"additions":8624,"deletions":25,"html_url":"https://example.test/pr/1"}
			],
			"total": 2,
			"summary": {"pending_review_count":2,"open_pr_count":0,"pr_states":{"ready":0,"conflicted":0,"failed":0,"needs_review":0}}
		}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "repo", "review-docs", "--refresh", "--expect-docs", "2", "--expect-pr", "1", "--expect-pr-docs", "2", "--expect-pr-state", "closed", "--expect-merged", "true", "--expect-pr-labels", "adr:needs-review,rfc:needs-review", "--reject-pr-labels", "adr:review,rfc:review,rfc:reviewed", "repo-1"}, strings.NewReader(""), &stdout, &stderr)
	if err != nil {
		t.Fatalf("run returned error: %v; stderr=%s", err, stderr.String())
	}
	output := stdout.String()
	if !strings.Contains(output, "documents waiting for review: 2") {
		t.Fatalf("expected document count in output, got:\n%s", output)
	}
	if !strings.Contains(output, "PR #1\tclosed merged\t2 docs\t33 files\t+8624 -25") {
		t.Fatalf("expected grouped PR review state in output, got:\n%s", output)
	}
	if !strings.Contains(output, "labels: adr:needs-review, hermit:rfc-ready, rfc:needs-review") {
		t.Fatalf("expected grouped PR labels in output, got:\n%s", output)
	}
}

func TestRepoReviewDocsExpectationFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"items": [],
			"total": 0,
			"summary": {"pending_review_count":0,"open_pr_count":0,"pr_states":{"ready":0,"conflicted":0,"failed":0,"needs_review":0}}
		}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "repo", "review-docs", "--expect-docs", "1", "repo-1"}, strings.NewReader(""), &stdout, &stderr)
	if err == nil {
		t.Fatalf("expected expectation failure")
	}
	if !strings.Contains(err.Error(), "review docs count = 0, want 1") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLogsPrintsErrorEntries(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/logs" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("kind") != "error" {
			t.Fatalf("kind = %q, want error", r.URL.Query().Get("kind"))
		}
		if r.URL.Query().Get("limit") != "2" {
			t.Fatalf("limit = %q, want 2", r.URL.Query().Get("limit"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"items": [
				{"id":7,"started_at":"2026-06-29T00:00:00Z","completed_at":"2026-06-29T00:00:00Z","kind":"error","method":"GET","path":"/api/v1/repositories/repo-1/rfcs/pr:1:docs-cms/rfcs/rfc-001.md","status":404,"duration_ms":12,"correlation_id":"corr-test","bytes_written":92,"error_code":"rfc_not_found","error_message":"document not found"}
			],
			"total": 1
		}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "logs", "--kind", "error", "--limit", "2"}, strings.NewReader(""), &stdout, &stderr)
	if err != nil {
		t.Fatalf("run returned error: %v; stderr=%s", err, stderr.String())
	}
	output := stdout.String()
	if !strings.Contains(output, "ERROR\t404\t12ms\tGET\t/api/v1/repositories/repo-1/rfcs/pr:1:docs-cms/rfcs/rfc-001.md\trfc_not_found\tdocument not found") {
		t.Fatalf("unexpected output:\n%s", output)
	}
}

func TestReviewStateValidatesExpectations(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Fatalf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/api/v1/repositories/repo-1/pull-requests/7/review" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"approved":true,"reviewers":["alice"]}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "review", "state", "--expect-approved", "true", "--expect-reviewer", "alice", "repo-1", "7"}, strings.NewReader(""), &stdout, &stderr)
	if err != nil {
		t.Fatalf("run returned error: %v; stderr=%s", err, stderr.String())
	}
	if !strings.Contains(stdout.String(), "approved: true") {
		t.Fatalf("expected approval state in output, got:\n%s", stdout.String())
	}
}

func TestReviewStartPostsReviewSessionAndValidatesResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", r.Method)
		}
		if r.URL.Path != "/api/v1/repositories/repo-1/review-sessions" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if body["file_path"] != "docs-cms/prd/prd-001-loop.md" {
			t.Fatalf("file_path = %#v", body["file_path"])
		}
		if body["previous_pr_number"] != float64(7) {
			t.Fatalf("previous_pr_number = %#v", body["previous_pr_number"])
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"pr_number":88,"html_url":"https://example.test/pr/88","branch":"hermit/review/prd-001-loop-20260629T000000Z","file_path":"docs-cms/prd/prd-001-loop.md","marker_path":".hermit/reviews/20260629T000000Z-prd-001-loop.json","document_type":"prd","previous_pr_number":7}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "review", "start", "--file", "docs-cms/prd/prd-001-loop.md", "--previous-pr", "7", "--expect-pr", "88", "--expect-file", "docs-cms/prd/prd-001-loop.md", "--expect-doc-type", "prd", "repo-1"}, strings.NewReader(""), &stdout, &stderr)
	if err != nil {
		t.Fatalf("run returned error: %v; stderr=%s", err, stderr.String())
	}
	output := stdout.String()
	if !strings.Contains(output, "started review session PR #88 in repo-1") {
		t.Fatalf("expected review session output, got:\n%s", output)
	}
	if !strings.Contains(output, "doc_type: prd") {
		t.Fatalf("expected doc type in output, got:\n%s", output)
	}
}

func TestReviewListValidatesReviewIDAndState(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Fatalf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/api/v1/repositories/repo-1/pull-requests/7/review/list" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"items":[{"id":42,"state":"CHANGES_REQUESTED","body":"fix it","user":"alice","submitted_at":"2026-06-29T00:00:00Z"}]}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "review", "list", "--expect-count", "1", "--expect-state", "CHANGES_REQUESTED", "--expect-review-id", "42", "repo-1", "7"}, strings.NewReader(""), &stdout, &stderr)
	if err != nil {
		t.Fatalf("run returned error: %v; stderr=%s", err, stderr.String())
	}
	if !strings.Contains(stdout.String(), "42\tCHANGES_REQUESTED\talice") {
		t.Fatalf("expected review row in output, got:\n%s", stdout.String())
	}
}

func TestReviewActionsUseReviewAPIPaths(t *testing.T) {
	seen := map[string]bool{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Method + " " + r.URL.Path
		seen[key] = true
		w.Header().Set("Content-Type", "application/json")
		switch key {
		case "POST /api/v1/repositories/repo-1/pull-requests/7/review/approve":
			_, _ = w.Write([]byte(`{"repository_id":"repo-1","pr_number":7,"state":"approved","reviewer":"alice","github_review_id":"101","updated_at":"2026-06-29T00:00:00Z"}`))
		case "POST /api/v1/repositories/repo-1/pull-requests/7/review/request-changes":
			_, _ = w.Write([]byte(`{"github_review_id":"102","reviewer":"alice"}`))
		case "GET /api/v1/repositories/repo-1/pull-requests/7/review/merge-status":
			_, _ = w.Write([]byte(`{"behind":true}`))
		case "PUT /api/v1/repositories/repo-1/pull-requests/7/review/102/dismiss",
			"PUT /api/v1/repositories/repo-1/pull-requests/7/review/update-branch":
			w.WriteHeader(http.StatusNoContent)
		case "POST /api/v1/repositories/repo-1/pull-requests/7/accept":
			_, _ = w.Write([]byte(`{"merged":false,"blocked_by_ci":true,"commit_sha":"abc123"}`))
		case "POST /api/v1/repositories/repo-1/pull-requests/7/merge":
			_, _ = w.Write([]byte(`{"merged":true,"blocked_by_ci":false}`))
		case "GET /api/v1/repositories/repo-1/ci-status":
			if r.URL.Query().Get("sha") != "abc123" {
				t.Fatalf("sha = %q, want abc123", r.URL.Query().Get("sha"))
			}
			_, _ = w.Write([]byte(`{"status":"success"}`))
		default:
			t.Fatalf("unexpected request: %s", key)
		}
	}))
	defer server.Close()

	commands := [][]string{
		{"--addr", server.URL, "review", "approve", "--body", "looks good", "repo-1", "7"},
		{"--addr", server.URL, "review", "request-changes", "--body", "fix it", "repo-1", "7"},
		{"--addr", server.URL, "review", "merge-status", "--expect-behind", "true", "repo-1", "7"},
		{"--addr", server.URL, "review", "dismiss", "--message", "resolved", "repo-1", "7", "102"},
		{"--addr", server.URL, "review", "update-branch", "repo-1", "7"},
		{"--addr", server.URL, "review", "accept", "--file", "docs-cms/rfcs/rfc-001.md", "--expect-merged", "false", "--expect-blocked-by-ci", "true", "repo-1", "7"},
		{"--addr", server.URL, "review", "merge", "--expect-merged", "true", "--expect-blocked-by-ci", "false", "repo-1", "7"},
		{"--addr", server.URL, "review", "ci-status", "--sha", "abc123", "--expect-status", "success", "repo-1"},
	}
	for _, args := range commands {
		var stdout, stderr bytes.Buffer
		if err := run(args, strings.NewReader(""), &stdout, &stderr); err != nil {
			t.Fatalf("run %v returned error: %v; stderr=%s", args, err, stderr.String())
		}
	}

	for _, key := range []string{
		"POST /api/v1/repositories/repo-1/pull-requests/7/review/approve",
		"POST /api/v1/repositories/repo-1/pull-requests/7/review/request-changes",
		"GET /api/v1/repositories/repo-1/pull-requests/7/review/merge-status",
		"PUT /api/v1/repositories/repo-1/pull-requests/7/review/102/dismiss",
		"PUT /api/v1/repositories/repo-1/pull-requests/7/review/update-branch",
		"POST /api/v1/repositories/repo-1/pull-requests/7/accept",
		"POST /api/v1/repositories/repo-1/pull-requests/7/merge",
		"GET /api/v1/repositories/repo-1/ci-status",
	} {
		if !seen[key] {
			t.Fatalf("expected request %s", key)
		}
	}
}
