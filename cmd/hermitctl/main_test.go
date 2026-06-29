package main

import (
	"bytes"
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
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"items": [
				{"id":"pr:1:docs-cms/adr/adr-001.md","title":"Choice","path":"docs-cms/adr/adr-001.md","source_type":"pull_request","source_label":"PR #1","pr_number":1,"pr_title":"docs: references","pr_state":"closed","pr_merged":true,"head_ref":"docs","mergeable_state":"unknown","document_type":"adr","changed_files":33,"additions":8624,"deletions":25,"html_url":"https://example.test/pr/1"},
				{"id":"pr:1:docs-cms/rfcs/rfc-001.md","title":"Plan","path":"docs-cms/rfcs/rfc-001.md","source_type":"pull_request","source_label":"PR #1","pr_number":1,"pr_title":"docs: references","pr_state":"closed","pr_merged":true,"head_ref":"docs","mergeable_state":"unknown","document_type":"rfc","changed_files":33,"additions":8624,"deletions":25,"html_url":"https://example.test/pr/1"}
			],
			"total": 2,
			"summary": {"pending_review_count":2,"open_pr_count":0,"pr_states":{"ready":0,"conflicted":0,"failed":0,"needs_review":0}}
		}`))
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	err := run([]string{"--addr", server.URL, "repo", "review-docs", "--expect-docs", "2", "--expect-pr", "1", "--expect-pr-docs", "2", "--expect-pr-state", "closed", "--expect-merged", "true", "repo-1"}, strings.NewReader(""), &stdout, &stderr)
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
