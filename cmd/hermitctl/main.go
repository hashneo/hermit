package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"hermit/internal/config"

	"golang.org/x/term"
)

const defaultTimeout = 15 * time.Second

type repositoryConfig struct {
	ID             string             `json:"id"`
	Owner          string             `json:"owner"`
	Name           string             `json:"name"`
	Registry       string             `json:"registry"`
	BaseURL        string             `json:"base_url,omitempty"`
	DefaultBranch  string             `json:"default_branch"`
	DocsPathPolicy string             `json:"docs_path_policy"`
	RFCLabel       string             `json:"rfc_label"`
	Auth           authMetadata       `json:"auth"`
	Validation     validationResponse `json:"validation"`
	CreatedAt      string             `json:"created_at"`
	UpdatedAt      string             `json:"updated_at"`
}

type authMetadata struct {
	Method               string  `json:"method"`
	TokenLastValidatedAt *string `json:"token_last_validated_at"`
}

type validationResponse struct {
	Healthy       bool              `json:"healthy"`
	Checks        []validationCheck `json:"checks"`
	ValidatedAt   string            `json:"validated_at"`
	LastErrorCode string            `json:"last_error_code,omitempty"`
}

type validationCheck struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type listRepositoriesResponse struct {
	Items []repositoryConfig `json:"items"`
	Total int                `json:"total"`
}

type repositoryRFCListResponse struct {
	Items   []rfcCatalogItem     `json:"items"`
	Total   int                  `json:"total"`
	Summary repositoryRFCSummary `json:"summary"`
}

type repositoryRFCSummary struct {
	PendingReviewCount int           `json:"pending_review_count"`
	OpenPRCount        int           `json:"open_pr_count"`
	PRStates           prStateCounts `json:"pr_states"`
}

type prStateCounts struct {
	Ready       int `json:"ready"`
	Conflicted  int `json:"conflicted"`
	Failed      int `json:"failed"`
	NeedsReview int `json:"needs_review"`
}

type rfcCatalogItem struct {
	ID             string   `json:"id"`
	Title          string   `json:"title"`
	Path           string   `json:"path"`
	SourceType     string   `json:"source_type"`
	SourceLabel    string   `json:"source_label"`
	PRNumber       int      `json:"pr_number,omitempty"`
	PRTitle        string   `json:"pr_title,omitempty"`
	PRState        string   `json:"pr_state,omitempty"`
	PRMerged       bool     `json:"pr_merged,omitempty"`
	HeadSHA        string   `json:"head_sha,omitempty"`
	HeadRef        string   `json:"head_ref,omitempty"`
	Mergeable      *bool    `json:"mergeable,omitempty"`
	MergeableState string   `json:"mergeable_state,omitempty"`
	DocumentType   string   `json:"document_type,omitempty"`
	Labels         []string `json:"labels,omitempty"`
	ChangedFiles   int      `json:"changed_files,omitempty"`
	Additions      int      `json:"additions,omitempty"`
	Deletions      int      `json:"deletions,omitempty"`
	HTMLURL        string   `json:"html_url,omitempty"`
}

type reviewDocsPR struct {
	Number      int              `json:"number"`
	Title       string           `json:"title"`
	State       string           `json:"state"`
	Merged      bool             `json:"merged"`
	HeadRef     string           `json:"head_ref,omitempty"`
	HTMLURL     string           `json:"html_url,omitempty"`
	MergeState  string           `json:"mergeable_state,omitempty"`
	Changed     int              `json:"changed_files"`
	Additions   int              `json:"additions"`
	Deletions   int              `json:"deletions"`
	DocumentMix map[string]int   `json:"document_mix"`
	Documents   []rfcCatalogItem `json:"documents"`
}

type reviewDocsState struct {
	RepositoryID       string               `json:"repository_id"`
	PendingReviewCount int                  `json:"pending_review_count"`
	OpenPRCount        int                  `json:"open_pr_count"`
	PRStates           prStateCounts        `json:"pr_states"`
	PullRequests       []reviewDocsPR       `json:"pull_requests"`
	Documents          []rfcCatalogItem     `json:"documents"`
	Summary            repositoryRFCSummary `json:"summary"`
}

type reviewStateResponse struct {
	Approved  bool     `json:"approved"`
	Reviewers []string `json:"reviewers"`
}

type reviewActionState struct {
	RepositoryID   string `json:"repository_id"`
	PRNumber       int    `json:"pr_number"`
	State          string `json:"state"`
	Reviewer       string `json:"reviewer,omitempty"`
	GitHubReviewID string `json:"github_review_id,omitempty"`
	UpdatedAt      string `json:"updated_at"`
}

type reviewActionResult struct {
	GitHubReviewID string `json:"github_review_id"`
	Reviewer       string `json:"reviewer"`
}

type reviewListResponse struct {
	Items []reviewItem `json:"items"`
}

type reviewItem struct {
	ID          int64  `json:"id"`
	State       string `json:"state"`
	Body        string `json:"body"`
	User        string `json:"user"`
	SubmittedAt string `json:"submitted_at"`
}

type reviewMergeStatusResponse struct {
	Behind bool `json:"behind"`
}

type reviewAcceptResult struct {
	Merged           bool   `json:"merged"`
	BlockedByCI      bool   `json:"blocked_by_ci"`
	CommitSHA        string `json:"commit_sha,omitempty"`
	HandedToIronhide bool   `json:"handed_to_ironhide,omitempty"`
}

type reviewMergeResult struct {
	Merged      bool   `json:"merged"`
	BlockedByCI bool   `json:"blocked_by_ci"`
	CommitSHA   string `json:"commit_sha,omitempty"`
}

type reviewCIStatusResponse struct {
	Status string `json:"status"`
}

type logListResponse struct {
	Items []logEntry `json:"items"`
	Total int        `json:"total"`
}

type logEntry struct {
	ID            int64  `json:"id"`
	StartedAt     string `json:"started_at"`
	CompletedAt   string `json:"completed_at"`
	Kind          string `json:"kind"`
	Method        string `json:"method"`
	Path          string `json:"path"`
	Query         string `json:"query,omitempty"`
	Status        int    `json:"status"`
	DurationMS    int64  `json:"duration_ms"`
	CorrelationID string `json:"correlation_id"`
	RemoteAddr    string `json:"remote_addr,omitempty"`
	UserAgent     string `json:"user_agent,omitempty"`
	BytesWritten  int    `json:"bytes_written"`
	ErrorCode     string `json:"error_code,omitempty"`
	ErrorMessage  string `json:"error_message,omitempty"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type cli struct {
	baseURL string
	client  *http.Client
	jsonOut bool
}

type nativeConnection struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Endpoint string `json:"endpoint"`
	Token    string `json:"token,omitempty"`
}

type nativeRepository struct {
	ID        string `json:"id"`
	ServerID  string `json:"serverID,omitempty"`
	AccountID string `json:"accountID"`
	Owner     string `json:"owner"`
	Name      string `json:"name"`
	DocsPath  string `json:"docsPath"`
	RFCLabel  string `json:"rfcLabel"`
}

type nativePrefs struct {
	Accounts             []nativeConnection
	Repositories         []nativeRepository
	AccountsActiveID     string
	RepositoriesActiveID string
	BaseURL              string
	ServerBaseURL        string
	RepoOwner            string
	RepoName             string
	DocsPath             string
	RFCLabel             string
	ServerMode           string
}

type shareConfig struct {
	Version      int               `json:"version"`
	Accounts     []shareAccount    `json:"accounts"`
	Repositories []shareRepository `json:"repositories"`
}

type shareAccount struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Endpoint string `json:"endpoint"`
}

type shareRepository struct {
	Account  string `json:"account"`
	Owner    string `json:"owner"`
	Name     string `json:"name"`
	DocsPath string `json:"docs_path"`
	RFCLabel string `json:"rfc_label"`
	ServerID string `json:"server_id,omitempty"`
}

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	global := flag.NewFlagSet("hermitctl", flag.ContinueOnError)
	global.SetOutput(stderr)
	addr := global.String("addr", "", "Hermit server base URL or listen address")
	configPath := global.String("config", "", "Hermit config file path")
	jsonOut := global.Bool("json", false, "print JSON responses")
	if err := global.Parse(args); err != nil {
		return err
	}
	remaining := global.Args()
	if len(remaining) == 0 {
		usage(stdout)
		return nil
	}
	if remaining[0] == "help" || remaining[0] == "-h" || remaining[0] == "--help" {
		usage(stdout)
		return nil
	}
	if remaining[0] == "token" {
		return runToken(remaining[1:], stdin, stdout, stderr)
	}

	baseURL, err := resolveBaseURL(*addr, *configPath)
	if err != nil {
		return err
	}
	c := cli{baseURL: baseURL, client: &http.Client{Timeout: defaultTimeout}, jsonOut: *jsonOut}

	switch remaining[0] {
	case "repo":
		return c.runRepo(remaining[1:], stdin, stdout, stderr)
	case "review":
		return c.runReview(remaining[1:], stdout, stderr)
	case "health":
		return c.runHealth(stdout)
	case "logs":
		return c.runLogs(remaining[1:], stdout, stderr)
	default:
		return fmt.Errorf("unknown command %q", remaining[0])
	}
}

func (c cli) runReview(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		reviewUsage(stdout)
		return nil
	}
	switch args[0] {
	case "state":
		return c.reviewState(args[1:], stdout, stderr)
	case "list":
		return c.reviewList(args[1:], stdout, stderr)
	case "merge-status":
		return c.reviewMergeStatus(args[1:], stdout, stderr)
	case "approve":
		return c.reviewApprove(args[1:], stdout, stderr)
	case "request-changes":
		return c.reviewRequestChanges(args[1:], stdout, stderr)
	case "dismiss":
		return c.reviewDismiss(args[1:], stdout, stderr)
	case "update-branch":
		return c.reviewUpdateBranch(args[1:], stdout, stderr)
	case "accept":
		return c.reviewAccept(args[1:], stdout, stderr)
	case "merge":
		return c.reviewMerge(args[1:], stdout, stderr)
	case "ci-status":
		return c.reviewCIStatus(args[1:], stdout, stderr)
	case "help", "-h", "--help":
		reviewUsage(stdout)
		return nil
	default:
		return fmt.Errorf("unknown review command %q", args[0])
	}
}

func (c cli) reviewState(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review state", flag.ContinueOnError)
	fs.SetOutput(stderr)
	expectApproved := fs.String("expect-approved", "", "expected approval state: true or false")
	expectReviewer := fs.String("expect-reviewer", "", "reviewer login that must be present")
	if err := fs.Parse(args); err != nil {
		return err
	}
	repoID, prNumber, err := repoPR("review state", fs.Args())
	if err != nil {
		return err
	}
	var state reviewStateResponse
	if err := c.do(http.MethodGet, reviewPath(repoID, prNumber), nil, &state); err != nil {
		return err
	}
	if strings.TrimSpace(*expectApproved) != "" {
		want, err := parseBoolExpectation(*expectApproved)
		if err != nil {
			return err
		}
		if state.Approved != want {
			return fmt.Errorf("review approved = %t, want %t", state.Approved, want)
		}
	}
	if reviewer := strings.TrimSpace(*expectReviewer); reviewer != "" && !containsString(state.Reviewers, reviewer) {
		return fmt.Errorf("reviewers %v do not include %q", state.Reviewers, reviewer)
	}
	if c.jsonOut {
		return printJSON(stdout, state)
	}
	fmt.Fprintf(stdout, "approved: %t\n", state.Approved)
	if len(state.Reviewers) > 0 {
		fmt.Fprintf(stdout, "reviewers: %s\n", strings.Join(state.Reviewers, ", "))
	}
	return nil
}

func (c cli) reviewList(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review list", flag.ContinueOnError)
	fs.SetOutput(stderr)
	expectCount := fs.Int("expect-count", -1, "expected review count")
	expectState := fs.String("expect-state", "", "review state that must be present, e.g. APPROVED")
	expectReviewID := fs.Int64("expect-review-id", 0, "review id that must be present")
	if err := fs.Parse(args); err != nil {
		return err
	}
	repoID, prNumber, err := repoPR("review list", fs.Args())
	if err != nil {
		return err
	}
	var list reviewListResponse
	if err := c.do(http.MethodGet, reviewPath(repoID, prNumber)+"/list", nil, &list); err != nil {
		return err
	}
	if *expectCount >= 0 && len(list.Items) != *expectCount {
		return fmt.Errorf("review count = %d, want %d", len(list.Items), *expectCount)
	}
	if state := strings.TrimSpace(*expectState); state != "" && !reviewListHasState(list.Items, state) {
		return fmt.Errorf("review list does not include state %q", state)
	}
	if *expectReviewID > 0 && !reviewListHasID(list.Items, *expectReviewID) {
		return fmt.Errorf("review list does not include review id %d", *expectReviewID)
	}
	if c.jsonOut {
		return printJSON(stdout, list)
	}
	for _, item := range list.Items {
		fmt.Fprintf(stdout, "%d\t%s\t%s\t%s\n", item.ID, item.State, item.User, item.SubmittedAt)
	}
	return nil
}

func (c cli) reviewMergeStatus(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review merge-status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	expectBehind := fs.String("expect-behind", "", "expected branch-behind state: true or false")
	if err := fs.Parse(args); err != nil {
		return err
	}
	repoID, prNumber, err := repoPR("review merge-status", fs.Args())
	if err != nil {
		return err
	}
	var status reviewMergeStatusResponse
	if err := c.do(http.MethodGet, reviewPath(repoID, prNumber)+"/merge-status", nil, &status); err != nil {
		return err
	}
	if strings.TrimSpace(*expectBehind) != "" {
		want, err := parseBoolExpectation(*expectBehind)
		if err != nil {
			return err
		}
		if status.Behind != want {
			return fmt.Errorf("merge behind = %t, want %t", status.Behind, want)
		}
	}
	if c.jsonOut {
		return printJSON(stdout, status)
	}
	fmt.Fprintf(stdout, "behind: %t\n", status.Behind)
	return nil
}

func (c cli) reviewApprove(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review approve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	body := fs.String("body", "", "approval review body")
	if err := fs.Parse(args); err != nil {
		return err
	}
	repoID, prNumber, err := repoPR("review approve", fs.Args())
	if err != nil {
		return err
	}
	var state reviewActionState
	if err := c.do(http.MethodPost, reviewPath(repoID, prNumber)+"/approve", map[string]string{"body": *body}, &state); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, state)
	}
	fmt.Fprintf(stdout, "approved PR #%d in %s", prNumber, repoID)
	if state.GitHubReviewID != "" {
		fmt.Fprintf(stdout, "\treview_id: %s", state.GitHubReviewID)
	}
	if state.Reviewer != "" {
		fmt.Fprintf(stdout, "\treviewer: %s", state.Reviewer)
	}
	fmt.Fprintln(stdout)
	return nil
}

func (c cli) reviewRequestChanges(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review request-changes", flag.ContinueOnError)
	fs.SetOutput(stderr)
	body := fs.String("body", "", "required request-changes review body")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*body) == "" {
		return errors.New("review request-changes requires --body")
	}
	repoID, prNumber, err := repoPR("review request-changes", fs.Args())
	if err != nil {
		return err
	}
	var result reviewActionResult
	if err := c.do(http.MethodPost, reviewPath(repoID, prNumber)+"/request-changes", map[string]string{"body": *body}, &result); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, result)
	}
	fmt.Fprintf(stdout, "requested changes on PR #%d in %s", prNumber, repoID)
	if result.GitHubReviewID != "" {
		fmt.Fprintf(stdout, "\treview_id: %s", result.GitHubReviewID)
	}
	if result.Reviewer != "" {
		fmt.Fprintf(stdout, "\treviewer: %s", result.Reviewer)
	}
	fmt.Fprintln(stdout)
	return nil
}

func (c cli) reviewDismiss(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review dismiss", flag.ContinueOnError)
	fs.SetOutput(stderr)
	message := fs.String("message", "Review dismissed.", "dismissal message")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) != 3 {
		return errors.New("usage: hermitctl review dismiss <repository-id> <pr-number> <review-id>")
	}
	repoID, prNumber, err := repoPR("review dismiss", fs.Args()[:2])
	if err != nil {
		return err
	}
	reviewID, err := strconv.ParseInt(strings.TrimSpace(fs.Args()[2]), 10, 64)
	if err != nil || reviewID <= 0 {
		return errors.New("review-id must be a positive integer")
	}
	if err := c.do(http.MethodPut, reviewPath(repoID, prNumber)+"/"+strconv.FormatInt(reviewID, 10)+"/dismiss", map[string]string{"message": *message}, nil); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "dismissed review %d on PR #%d in %s\n", reviewID, prNumber, repoID)
	return nil
}

func (c cli) reviewUpdateBranch(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review update-branch", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return err
	}
	repoID, prNumber, err := repoPR("review update-branch", fs.Args())
	if err != nil {
		return err
	}
	if err := c.do(http.MethodPut, reviewPath(repoID, prNumber)+"/update-branch", nil, nil); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "updated branch for PR #%d in %s\n", prNumber, repoID)
	return nil
}

func (c cli) reviewAccept(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review accept", flag.ContinueOnError)
	fs.SetOutput(stderr)
	filePath := fs.String("file", "", "docs-cms document path to mark accepted before merge")
	expectMerged := fs.String("expect-merged", "", "expected merged state: true or false")
	expectBlockedByCI := fs.String("expect-blocked-by-ci", "", "expected CI-blocked state: true or false")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*filePath) == "" {
		return errors.New("review accept requires --file")
	}
	repoID, prNumber, err := repoPR("review accept", fs.Args())
	if err != nil {
		return err
	}
	var result reviewAcceptResult
	if err := c.do(http.MethodPost, "/api/v1/repositories/"+url.PathEscape(repoID)+"/pull-requests/"+strconv.Itoa(prNumber)+"/accept", map[string]string{"file_path": *filePath}, &result); err != nil {
		return err
	}
	if err := validateMergeResult(result.Merged, result.BlockedByCI, *expectMerged, *expectBlockedByCI); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, result)
	}
	printMergeOutcome(stdout, "accepted", repoID, prNumber, result.Merged, result.BlockedByCI, result.CommitSHA)
	if result.HandedToIronhide {
		fmt.Fprintln(stdout, "handed_to_ironhide: true")
	}
	return nil
}

func (c cli) reviewMerge(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review merge", flag.ContinueOnError)
	fs.SetOutput(stderr)
	expectMerged := fs.String("expect-merged", "", "expected merged state: true or false")
	expectBlockedByCI := fs.String("expect-blocked-by-ci", "", "expected CI-blocked state: true or false")
	if err := fs.Parse(args); err != nil {
		return err
	}
	repoID, prNumber, err := repoPR("review merge", fs.Args())
	if err != nil {
		return err
	}
	var result reviewMergeResult
	if err := c.do(http.MethodPost, "/api/v1/repositories/"+url.PathEscape(repoID)+"/pull-requests/"+strconv.Itoa(prNumber)+"/merge", nil, &result); err != nil {
		return err
	}
	if err := validateMergeResult(result.Merged, result.BlockedByCI, *expectMerged, *expectBlockedByCI); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, result)
	}
	printMergeOutcome(stdout, "merged", repoID, prNumber, result.Merged, result.BlockedByCI, result.CommitSHA)
	return nil
}

func (c cli) reviewCIStatus(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("review ci-status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	sha := fs.String("sha", "", "commit SHA to check")
	expectStatus := fs.String("expect-status", "", "expected CI status: pending, success, or failure")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*sha) == "" {
		return errors.New("review ci-status requires --sha")
	}
	if len(fs.Args()) != 1 || strings.TrimSpace(fs.Args()[0]) == "" {
		return errors.New("usage: hermitctl review ci-status <repository-id> --sha <commit-sha>")
	}
	repoID := strings.TrimSpace(fs.Args()[0])
	var result reviewCIStatusResponse
	values := url.Values{}
	values.Set("sha", strings.TrimSpace(*sha))
	if err := c.do(http.MethodGet, "/api/v1/repositories/"+url.PathEscape(repoID)+"/ci-status?"+values.Encode(), nil, &result); err != nil {
		return err
	}
	if expected := strings.TrimSpace(*expectStatus); expected != "" && !strings.EqualFold(result.Status, expected) {
		return fmt.Errorf("ci status = %s, want %s", result.Status, expected)
	}
	if c.jsonOut {
		return printJSON(stdout, result)
	}
	fmt.Fprintf(stdout, "ci status: %s\n", result.Status)
	return nil
}

func (c cli) runLogs(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	fs.SetOutput(stderr)
	kind := fs.String("kind", "all", "log kind: all, access, or error")
	limit := fs.Int("limit", 50, "maximum log entries to return")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("usage: hermitctl logs [--kind all|access|error] [--limit N]")
	}
	normalizedKind := strings.ToLower(strings.TrimSpace(*kind))
	switch normalizedKind {
	case "", "all", "access", "error":
	default:
		return fmt.Errorf("invalid log kind %q", *kind)
	}
	if *limit < 1 || *limit > 500 {
		return errors.New("limit must be between 1 and 500")
	}
	values := url.Values{}
	values.Set("kind", normalizedKind)
	values.Set("limit", fmt.Sprintf("%d", *limit))
	var response logListResponse
	if err := c.do(http.MethodGet, "/api/v1/logs?"+values.Encode(), nil, &response); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, response)
	}
	for _, entry := range response.Items {
		target := entry.Path
		if entry.Query != "" {
			target += "?" + entry.Query
		}
		fmt.Fprintf(stdout, "%s\t%s\t%d\t%dms\t%s\t%s",
			entry.StartedAt,
			strings.ToUpper(entry.Kind),
			entry.Status,
			entry.DurationMS,
			entry.Method,
			target,
		)
		if entry.ErrorCode != "" || entry.ErrorMessage != "" {
			fmt.Fprintf(stdout, "\t%s\t%s", entry.ErrorCode, entry.ErrorMessage)
		}
		fmt.Fprintln(stdout)
	}
	return nil
}

func (c cli) runRepo(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		repoUsage(stdout)
		return nil
	}
	switch args[0] {
	case "add":
		return c.repoAdd(args[1:], stdin, stdout, stderr)
	case "add-local":
		return repoAddLocal(args[1:], stdin, stdout, stderr)
	case "export-local":
		return repoExportLocal(args[1:], stdout, stderr)
	case "import-local":
		return repoImportLocal(args[1:], stdout, stderr)
	case "bind-credential":
		return repoBindCredential(args[1:], stdin, stdout, stderr)
	case "list":
		return c.repoList(stdout)
	case "get":
		return c.repoGet(args[1:], stdout)
	case "remove", "delete":
		return c.repoRemove(args[1:], stdout)
	case "validate":
		return c.repoValidate(args[1:], stdout)
	case "review-docs":
		return c.repoReviewDocs(args[1:], stdout, stderr)
	case "rotate-token":
		return c.repoRotateToken(args[1:], stdin, stdout, stderr)
	case "debug":
		return c.repoDebug(args[1:], stdout)
	case "help", "-h", "--help":
		repoUsage(stdout)
		return nil
	default:
		return fmt.Errorf("unknown repo command %q", args[0])
	}
}

func repoExportLocal(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo export-local", flag.ContinueOnError)
	fs.SetOutput(stderr)
	bundleID := fs.String("bundle-id", "", "HermitNative bundle identifier; defaults from hermit-native/Local.xcconfig")
	output := fs.String("output", "", "write shareable config JSON to this file instead of stdout")
	if err := fs.Parse(args); err != nil {
		return err
	}

	bid, err := resolveBundleID(strings.TrimSpace(*bundleID))
	if err != nil {
		return err
	}
	prefs, err := loadNativePrefs(bid)
	if err != nil {
		return err
	}

	cfg := shareConfigFromPrefs(prefs)
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if strings.TrimSpace(*output) != "" {
		return os.WriteFile(strings.TrimSpace(*output), data, 0o644)
	}
	_, err = stdout.Write(data)
	return err
}

func repoImportLocal(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo import-local", flag.ContinueOnError)
	fs.SetOutput(stderr)
	filePath := fs.String("file", "", "shareable Hermit repo config JSON")
	bundleID := fs.String("bundle-id", "", "HermitNative bundle identifier; defaults from hermit-native/Local.xcconfig")
	setActive := fs.String("set-active", "", "optional owner/name repository to make active after import")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*filePath) == "" {
		return errors.New("repo import-local requires --file")
	}

	cfg, err := readShareConfig(strings.TrimSpace(*filePath))
	if err != nil {
		return err
	}
	bid, err := resolveBundleID(strings.TrimSpace(*bundleID))
	if err != nil {
		return err
	}
	prefs, err := loadNativePrefs(bid)
	if err != nil {
		return err
	}

	accountIDs := map[string]string{}
	for _, account := range cfg.Accounts {
		endpoint := strings.TrimRight(strings.TrimSpace(account.Endpoint), "/")
		if endpoint == "" {
			return fmt.Errorf("account %q has empty endpoint", account.ID)
		}
		accountID := findOrCreateAccountWithoutToken(&prefs, endpoint, firstNonEmpty(account.Name, account.ID))
		accountIDs[account.ID] = accountID
		if prefs.AccountsActiveID == "" {
			prefs.AccountsActiveID = accountID
		}
	}

	imported := 0
	for _, repo := range cfg.Repositories {
		accountID := accountIDs[repo.Account]
		if accountID == "" {
			return fmt.Errorf("repository %s/%s references unknown account %q", repo.Owner, repo.Name, repo.Account)
		}
		repoID := upsertRepositoryWithServerID(&prefs, accountID, strings.TrimSpace(repo.Owner), strings.TrimSpace(repo.Name), normalizeDocsPath(repo.DocsPath), firstNonEmpty(repo.RFCLabel, "hermit:rfc-ready"), strings.TrimSpace(repo.ServerID))
		imported++
		if prefs.RepositoriesActiveID == "" || strings.EqualFold(strings.TrimSpace(*setActive), repo.Owner+"/"+repo.Name) {
			prefs.RepositoriesActiveID = repoID
			prefs.RepoOwner = strings.TrimSpace(repo.Owner)
			prefs.RepoName = strings.TrimSpace(repo.Name)
			prefs.DocsPath = normalizeDocsPath(repo.DocsPath)
			prefs.RFCLabel = firstNonEmpty(repo.RFCLabel, "hermit:rfc-ready")
		}
	}
	if prefs.ServerMode == "" {
		prefs.ServerMode = `{"type":"embeddedLocal"}`
	}
	if err := saveNativePrefs(bid, prefs); err != nil {
		return err
	}

	return printJSON(stdout, map[string]any{
		"bundle_id":    bid,
		"accounts":     len(cfg.Accounts),
		"repositories": imported,
		"credentials":  "not imported; run hermitctl repo bind-credential",
	})
}

func repoBindCredential(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo bind-credential", flag.ContinueOnError)
	fs.SetOutput(stderr)
	endpoint := fs.String("endpoint", "", "account endpoint to bind, for example https://github.ibm.com/api/v3")
	accountIDFlag := fs.String("account-id", "", "native account UUID to bind")
	bundleID := fs.String("bundle-id", "", "HermitNative bundle identifier; defaults from hermit-native/Local.xcconfig")
	noKeychain := fs.Bool("no-keychain", false, "skip writing the PAT into the native Keychain")
	token := fs.String("token", "", "PAT value; prefer --token-stdin or prompt")
	tokenStdin := fs.Bool("token-stdin", false, "read PAT from stdin")
	envFile := fs.String("env-file", "", ".env file to read token from")
	tokenEnv := fs.String("token-env", "", "environment variable name containing the PAT")
	credentialHost := fs.String("credential-host", "", "host to query via git credential helper")
	useCredentialHelper := fs.Bool("git-credential", false, "read PAT from git credential helper")
	if err := fs.Parse(args); err != nil {
		return err
	}

	pat, err := resolveToken(tokenOptions{token: *token, tokenStdin: *tokenStdin, envFile: *envFile, tokenEnv: *tokenEnv, credentialHost: *credentialHost, useCredentialHelper: *useCredentialHelper}, stdin, stderr)
	if err != nil {
		return err
	}
	bid, err := resolveBundleID(strings.TrimSpace(*bundleID))
	if err != nil {
		return err
	}
	prefs, err := loadNativePrefs(bid)
	if err != nil {
		return err
	}

	accountID, err := resolveNativeAccountID(prefs, strings.TrimSpace(*accountIDFlag), strings.TrimSpace(*endpoint))
	if err != nil {
		return err
	}
	for i := range prefs.Accounts {
		if prefs.Accounts[i].ID == accountID {
			prefs.Accounts[i].Token = pat
			break
		}
	}
	if err := saveNativePrefs(bid, prefs); err != nil {
		return err
	}
	if !*noKeychain {
		if err := writeNativeKeychainToken(accountID, pat); err != nil {
			return err
		}
	}

	result := map[string]string{
		"bundle_id":  bid,
		"account_id": accountID,
		"credential": "updated",
	}
	if *noKeychain {
		result["keychain"] = "skipped"
	} else {
		result["keychain"] = "updated"
	}
	return printJSON(stdout, result)
}

func (c cli) repoAdd(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo add", flag.ContinueOnError)
	fs.SetOutput(stderr)
	owner := fs.String("owner", "", "repository owner")
	name := fs.String("name", "", "repository name")
	registry := fs.String("registry", "github", "configured registry name")
	baseURL := fs.String("base-url", "", "registry API base URL for this repository")
	branch := fs.String("branch", "main", "default branch")
	docsPath := fs.String("docs-path", "docs-cms/rfcs/", "legacy docs path policy")
	token := fs.String("token", "", "PAT value; prefer --token-stdin or prompt")
	tokenStdin := fs.Bool("token-stdin", false, "read PAT from stdin")
	envFile := fs.String("env-file", "", ".env file to read token from")
	tokenEnv := fs.String("token-env", "", "environment variable name containing the PAT")
	credentialHost := fs.String("credential-host", "", "host to query via git credential helper")
	useCredentialHelper := fs.Bool("git-credential", false, "read PAT from git credential helper")
	if err := fs.Parse(args); err != nil {
		return err
	}
	pat, err := resolveToken(tokenOptions{token: *token, tokenStdin: *tokenStdin, envFile: *envFile, tokenEnv: *tokenEnv, credentialHost: *credentialHost, useCredentialHelper: *useCredentialHelper}, stdin, stderr)
	if err != nil {
		return err
	}
	body := map[string]string{
		"owner":                 *owner,
		"name":                  *name,
		"registry":              *registry,
		"base_url":              *baseURL,
		"default_branch":        *branch,
		"docs_path_policy":      *docsPath,
		"personal_access_token": pat,
	}
	var cfg repositoryConfig
	if err := c.do(http.MethodPost, "/api/v1/repositories", body, &cfg); err != nil {
		return err
	}
	return printRepository(stdout, cfg, c.jsonOut)
}

func repoAddLocal(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo add-local", flag.ContinueOnError)
	fs.SetOutput(stderr)
	owner := fs.String("owner", "", "repository owner")
	name := fs.String("name", "", "repository name")
	registry := fs.String("registry", "github", "configured registry name")
	baseURL := fs.String("base-url", "", "registry API base URL for this repository/account")
	docsPath := fs.String("docs-path", "docs-cms/rfcs", "docs path policy")
	rfcLabel := fs.String("rfc-label", "hermit:rfc-ready", "RFC label")
	accountName := fs.String("account-name", "", "display name for the local native account")
	bundleID := fs.String("bundle-id", "", "HermitNative bundle identifier; defaults from hermit-native/Local.xcconfig")
	configPath := fs.String("config", "", "Hermit config file path used to resolve registry base URLs")
	noKeychain := fs.Bool("no-keychain", false, "skip writing the PAT into the native Keychain")
	token := fs.String("token", "", "PAT value; prefer --token-stdin or prompt")
	tokenStdin := fs.Bool("token-stdin", false, "read PAT from stdin")
	envFile := fs.String("env-file", "", ".env file to read token from")
	tokenEnv := fs.String("token-env", "", "environment variable name containing the PAT")
	credentialHost := fs.String("credential-host", "", "host to query via git credential helper")
	useCredentialHelper := fs.Bool("git-credential", false, "read PAT from git credential helper")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*owner) == "" || strings.TrimSpace(*name) == "" {
		return errors.New("owner and name are required")
	}

	pat, err := resolveToken(tokenOptions{token: *token, tokenStdin: *tokenStdin, envFile: *envFile, tokenEnv: *tokenEnv, credentialHost: *credentialHost, useCredentialHelper: *useCredentialHelper}, stdin, stderr)
	if err != nil {
		return err
	}

	bid, err := resolveBundleID(strings.TrimSpace(*bundleID))
	if err != nil {
		return err
	}

	registryBaseURL, err := resolveRegistryBaseURL(*registry, strings.TrimSpace(*baseURL), strings.TrimSpace(*configPath))
	if err != nil {
		return err
	}
	endpoint := normalizeNativeEndpoint(registryBaseURL)
	serverBaseURL, err := resolveEmbeddedServerBaseURL(strings.TrimSpace(*configPath))
	if err != nil {
		return err
	}

	prefs, err := loadNativePrefs(bid)
	if err != nil {
		return err
	}

	accountID, accountTokenChanged := findOrCreateAccount(&prefs, endpoint, firstNonEmpty(strings.TrimSpace(*accountName), accountDisplayName(*registry, endpoint)), pat)
	repoID := upsertRepository(&prefs, accountID, strings.TrimSpace(*owner), strings.TrimSpace(*name), normalizeDocsPath(*docsPath), strings.TrimSpace(*rfcLabel))
	prefs.RepositoriesActiveID = repoID
	prefs.AccountsActiveID = accountID
	prefs.BaseURL = strings.TrimRight(registryBaseURL, "/")
	prefs.ServerBaseURL = serverBaseURL
	prefs.RepoOwner = strings.TrimSpace(*owner)
	prefs.RepoName = strings.TrimSpace(*name)
	prefs.DocsPath = normalizeDocsPath(*docsPath)
	prefs.RFCLabel = strings.TrimSpace(*rfcLabel)
	prefs.ServerMode = `{"type":"embeddedLocal"}`

	if err := saveNativePrefs(bid, prefs); err != nil {
		return err
	}
	if !*noKeychain && accountTokenChanged {
		if err := writeNativeKeychainToken(accountID, pat); err != nil {
			return err
		}
	}

	if *registry == "" {
		*registry = "github"
	}
	result := map[string]string{
		"bundle_id":  bid,
		"account_id": accountID,
		"repo_id":    repoID,
		"owner":      strings.TrimSpace(*owner),
		"name":       strings.TrimSpace(*name),
		"registry":   firstNonEmpty(strings.TrimSpace(*registry), "github"),
		"endpoint":   endpoint,
	}
	if *noKeychain {
		result["keychain"] = "skipped"
	} else if accountTokenChanged {
		result["keychain"] = "updated"
	} else {
		result["keychain"] = "unchanged"
	}
	return printJSON(stdout, result)
}

func (c cli) repoList(stdout io.Writer) error {
	var out listRepositoriesResponse
	if err := c.do(http.MethodGet, "/api/v1/repositories", nil, &out); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, out)
	}
	for _, repo := range out.Items {
		fmt.Fprintf(stdout, "%s\t%s/%s\t%s\thealthy=%t\n", repo.ID, repo.Owner, repo.Name, repo.Registry, repo.Validation.Healthy)
	}
	return nil
}

func (c cli) repoGet(args []string, stdout io.Writer) error {
	id, err := singleID("repo get", args)
	if err != nil {
		return err
	}
	var cfg repositoryConfig
	if err := c.do(http.MethodGet, "/api/v1/repositories/"+url.PathEscape(id), nil, &cfg); err != nil {
		return err
	}
	return printRepository(stdout, cfg, c.jsonOut)
}

func (c cli) repoRemove(args []string, stdout io.Writer) error {
	id, err := singleID("repo remove", args)
	if err != nil {
		return err
	}
	if err := c.do(http.MethodDelete, "/api/v1/repositories/"+url.PathEscape(id), nil, nil); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, map[string]string{"removed": id})
	}
	fmt.Fprintf(stdout, "removed: %s\n", id)
	return nil
}

func (c cli) repoValidate(args []string, stdout io.Writer) error {
	id, err := singleID("repo validate", args)
	if err != nil {
		return err
	}
	var validation validationResponse
	if err := c.do(http.MethodPost, "/api/v1/repositories/"+url.PathEscape(id)+"/validate", nil, &validation); err != nil {
		return err
	}
	return printValidation(stdout, validation, c.jsonOut)
}

func (c cli) repoReviewDocs(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo review-docs", flag.ContinueOnError)
	fs.SetOutput(stderr)
	expectDocs := fs.Int("expect-docs", -1, "expected total docs-cms review document count")
	expectPR := fs.Int("expect-pr", 0, "specific pull request number that must be present")
	expectPRDocs := fs.Int("expect-pr-docs", -1, "expected review document count for --expect-pr")
	expectPRState := fs.String("expect-pr-state", "", "expected top-level PR state for --expect-pr")
	expectMerged := fs.String("expect-merged", "", "expected merged state for --expect-pr: true or false")
	if err := fs.Parse(args); err != nil {
		return err
	}
	id, err := singleID("repo review-docs", fs.Args())
	if err != nil {
		return err
	}

	state, err := c.fetchReviewDocsState(id)
	if err != nil {
		return err
	}
	if err := validateReviewDocsExpectations(state, reviewDocsExpectations{
		expectDocs:    *expectDocs,
		expectPR:      *expectPR,
		expectPRDocs:  *expectPRDocs,
		expectPRState: strings.TrimSpace(*expectPRState),
		expectMerged:  strings.TrimSpace(*expectMerged),
	}); err != nil {
		return err
	}

	if c.jsonOut {
		return printJSON(stdout, state)
	}
	printReviewDocsState(stdout, state)
	return nil
}

func (c cli) fetchReviewDocsState(id string) (reviewDocsState, error) {
	var page repositoryRFCListResponse
	if err := c.do(http.MethodGet, "/api/v1/repositories/"+url.PathEscape(id)+"/rfcs", nil, &page); err != nil {
		return reviewDocsState{}, err
	}

	state := reviewDocsState{
		RepositoryID:       id,
		PendingReviewCount: page.Summary.PendingReviewCount,
		OpenPRCount:        page.Summary.OpenPRCount,
		PRStates:           page.Summary.PRStates,
		Summary:            page.Summary,
	}
	byPR := map[int]*reviewDocsPR{}
	for _, item := range page.Items {
		if item.SourceType != "pull_request" || item.PRNumber == 0 {
			continue
		}
		state.Documents = append(state.Documents, item)
		group := byPR[item.PRNumber]
		if group == nil {
			group = &reviewDocsPR{
				Number:      item.PRNumber,
				Title:       firstNonEmpty(item.PRTitle, item.Title),
				State:       firstNonEmpty(item.PRState, "open"),
				Merged:      item.PRMerged,
				HeadRef:     item.HeadRef,
				HTMLURL:     item.HTMLURL,
				MergeState:  item.MergeableState,
				Changed:     item.ChangedFiles,
				Additions:   item.Additions,
				Deletions:   item.Deletions,
				DocumentMix: map[string]int{},
			}
			byPR[item.PRNumber] = group
		}
		docType := strings.TrimSpace(item.DocumentType)
		if docType == "" {
			docType = "document"
		}
		group.DocumentMix[docType]++
		group.Documents = append(group.Documents, item)
	}
	for _, group := range byPR {
		sortReviewDocuments(group.Documents)
		state.PullRequests = append(state.PullRequests, *group)
	}
	sort.Slice(state.PullRequests, func(i, j int) bool {
		return state.PullRequests[i].Number < state.PullRequests[j].Number
	})
	sortReviewDocuments(state.Documents)
	return state, nil
}

type reviewDocsExpectations struct {
	expectDocs    int
	expectPR      int
	expectPRDocs  int
	expectPRState string
	expectMerged  string
}

func validateReviewDocsExpectations(state reviewDocsState, expected reviewDocsExpectations) error {
	if expected.expectDocs >= 0 && len(state.Documents) != expected.expectDocs {
		return fmt.Errorf("review docs count = %d, want %d", len(state.Documents), expected.expectDocs)
	}
	if expected.expectPR == 0 {
		if expected.expectPRDocs >= 0 || expected.expectPRState != "" || expected.expectMerged != "" {
			return errors.New("--expect-pr is required when asserting PR-specific review state")
		}
		return nil
	}
	var pr *reviewDocsPR
	for i := range state.PullRequests {
		if state.PullRequests[i].Number == expected.expectPR {
			pr = &state.PullRequests[i]
			break
		}
	}
	if pr == nil {
		return fmt.Errorf("PR #%d not found in docs review state", expected.expectPR)
	}
	if expected.expectPRDocs >= 0 && len(pr.Documents) != expected.expectPRDocs {
		return fmt.Errorf("PR #%d review docs count = %d, want %d", expected.expectPR, len(pr.Documents), expected.expectPRDocs)
	}
	if expected.expectPRState != "" && !strings.EqualFold(pr.State, expected.expectPRState) {
		return fmt.Errorf("PR #%d state = %s, want %s", expected.expectPR, pr.State, expected.expectPRState)
	}
	if expected.expectMerged != "" {
		wantMerged, err := parseBoolExpectation(expected.expectMerged)
		if err != nil {
			return err
		}
		if pr.Merged != wantMerged {
			return fmt.Errorf("PR #%d merged = %t, want %t", expected.expectPR, pr.Merged, wantMerged)
		}
	}
	return nil
}

func printReviewDocsState(w io.Writer, state reviewDocsState) {
	fmt.Fprintf(w, "repository: %s\n", state.RepositoryID)
	fmt.Fprintf(w, "documents waiting for review: %d\n", len(state.Documents))
	fmt.Fprintf(w, "open PRs: %d\n", state.OpenPRCount)
	for _, pr := range state.PullRequests {
		merged := ""
		if pr.Merged {
			merged = " merged"
		}
		fmt.Fprintf(w, "PR #%d\t%s%s\t%d docs\t%d files\t+%d -%d\t%s\n", pr.Number, pr.State, merged, len(pr.Documents), pr.Changed, pr.Additions, pr.Deletions, pr.Title)
		for _, doc := range pr.Documents {
			fmt.Fprintf(w, "  - %s\t%s\t%s\n", firstNonEmpty(doc.DocumentType, "document"), doc.Title, doc.Path)
		}
	}
}

func sortReviewDocuments(items []rfcCatalogItem) {
	sort.Slice(items, func(i, j int) bool {
		if items[i].PRNumber != items[j].PRNumber {
			return items[i].PRNumber < items[j].PRNumber
		}
		if items[i].DocumentType != items[j].DocumentType {
			return items[i].DocumentType < items[j].DocumentType
		}
		return items[i].Path < items[j].Path
	})
}

func parseBoolExpectation(value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true", "yes", "1":
		return true, nil
	case "false", "no", "0":
		return false, nil
	default:
		return false, fmt.Errorf("invalid boolean expectation %q", value)
	}
}

func repoPR(command string, args []string) (string, int, error) {
	if len(args) != 2 || strings.TrimSpace(args[0]) == "" || strings.TrimSpace(args[1]) == "" {
		return "", 0, fmt.Errorf("usage: hermitctl %s <repository-id> <pr-number>", command)
	}
	prNumber, err := strconv.Atoi(strings.TrimSpace(args[1]))
	if err != nil || prNumber <= 0 {
		return "", 0, errors.New("pr-number must be a positive integer")
	}
	return strings.TrimSpace(args[0]), prNumber, nil
}

func reviewPath(repoID string, prNumber int) string {
	return "/api/v1/repositories/" + url.PathEscape(repoID) + "/pull-requests/" + strconv.Itoa(prNumber) + "/review"
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func reviewListHasState(items []reviewItem, state string) bool {
	for _, item := range items {
		if strings.EqualFold(item.State, state) {
			return true
		}
	}
	return false
}

func reviewListHasID(items []reviewItem, id int64) bool {
	for _, item := range items {
		if item.ID == id {
			return true
		}
	}
	return false
}

func validateMergeResult(merged, blockedByCI bool, expectMerged, expectBlockedByCI string) error {
	if strings.TrimSpace(expectMerged) != "" {
		want, err := parseBoolExpectation(expectMerged)
		if err != nil {
			return err
		}
		if merged != want {
			return fmt.Errorf("merged = %t, want %t", merged, want)
		}
	}
	if strings.TrimSpace(expectBlockedByCI) != "" {
		want, err := parseBoolExpectation(expectBlockedByCI)
		if err != nil {
			return err
		}
		if blockedByCI != want {
			return fmt.Errorf("blocked_by_ci = %t, want %t", blockedByCI, want)
		}
	}
	return nil
}

func printMergeOutcome(w io.Writer, action, repoID string, prNumber int, merged, blockedByCI bool, commitSHA string) {
	fmt.Fprintf(w, "%s PR #%d in %s\tmerged: %t\tblocked_by_ci: %t", action, prNumber, repoID, merged, blockedByCI)
	if commitSHA != "" {
		fmt.Fprintf(w, "\tcommit_sha: %s", commitSHA)
	}
	fmt.Fprintln(w)
}

func (c cli) repoRotateToken(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo rotate-token", flag.ContinueOnError)
	fs.SetOutput(stderr)
	token := fs.String("token", "", "PAT value; prefer --token-stdin or prompt")
	tokenStdin := fs.Bool("token-stdin", false, "read PAT from stdin")
	envFile := fs.String("env-file", "", ".env file to read token from")
	tokenEnv := fs.String("token-env", "", "environment variable name containing the PAT")
	credentialHost := fs.String("credential-host", "", "host to query via git credential helper")
	useCredentialHelper := fs.Bool("git-credential", false, "read PAT from git credential helper")
	if err := fs.Parse(args); err != nil {
		return err
	}
	id, err := singleID("repo rotate-token", fs.Args())
	if err != nil {
		return err
	}
	pat, err := resolveToken(tokenOptions{token: *token, tokenStdin: *tokenStdin, envFile: *envFile, tokenEnv: *tokenEnv, credentialHost: *credentialHost, useCredentialHelper: *useCredentialHelper}, stdin, stderr)
	if err != nil {
		return err
	}
	var cfg repositoryConfig
	if err := c.do(http.MethodPost, "/api/v1/repositories/"+url.PathEscape(id)+"/rotate-token", map[string]string{"personal_access_token": pat}, &cfg); err != nil {
		return err
	}
	return printRepository(stdout, cfg, c.jsonOut)
}

func (c cli) repoDebug(args []string, stdout io.Writer) error {
	id, err := singleID("repo debug", args)
	if err != nil {
		return err
	}
	var cfg repositoryConfig
	if err := c.do(http.MethodGet, "/api/v1/repositories/"+url.PathEscape(id), nil, &cfg); err != nil {
		return err
	}
	var validation validationResponse
	if err := c.do(http.MethodPost, "/api/v1/repositories/"+url.PathEscape(id)+"/validate", nil, &validation); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "server: %s\n", c.baseURL)
	fmt.Fprintf(stdout, "repository: %s (%s/%s)\n", cfg.ID, cfg.Owner, cfg.Name)
	fmt.Fprintf(stdout, "registry: %s\n", cfg.Registry)
	fmt.Fprintf(stdout, "default branch: %s\n", cfg.DefaultBranch)
	fmt.Fprintf(stdout, "docs path policy: %s\n", cfg.DocsPathPolicy)
	fmt.Fprintf(stdout, "rfc label: %s\n", cfg.RFCLabel)
	fmt.Fprintf(stdout, "auth method: %s\n", cfg.Auth.Method)
	if cfg.Auth.TokenLastValidatedAt == nil {
		fmt.Fprintln(stdout, "token last validated: never")
	} else {
		fmt.Fprintf(stdout, "token last validated: %s\n", *cfg.Auth.TokenLastValidatedAt)
	}
	return printValidation(stdout, validation, false)
}

func (c cli) runHealth(stdout io.Writer) error {
	var payload map[string]any
	if err := c.do(http.MethodGet, "/api/v1/health", nil, &payload); err != nil {
		return err
	}
	if c.jsonOut {
		return printJSON(stdout, payload)
	}
	fmt.Fprintf(stdout, "server: %s\n", c.baseURL)
	fmt.Fprintf(stdout, "status: %v\n", payload["status"])
	return nil
}

func runToken(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	if len(args) == 0 || args[0] != "read" {
		fmt.Fprintln(stdout, "usage: hermitctl token read [--token-stdin|--env-file path --token-env NAME|--git-credential --credential-host HOST]")
		return nil
	}
	fs := flag.NewFlagSet("token read", flag.ContinueOnError)
	fs.SetOutput(stderr)
	tokenStdin := fs.Bool("token-stdin", false, "read token from stdin instead of secure prompt")
	envFile := fs.String("env-file", "", ".env file to read token from")
	tokenEnv := fs.String("token-env", "", "environment variable name containing the token")
	credentialHost := fs.String("credential-host", "", "host to query via git credential helper")
	useCredentialHelper := fs.Bool("git-credential", false, "read token from git credential helper")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	token, err := resolveToken(tokenOptions{tokenStdin: *tokenStdin, envFile: *envFile, tokenEnv: *tokenEnv, credentialHost: *credentialHost, useCredentialHelper: *useCredentialHelper}, stdin, stderr)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, strings.Repeat("*", min(len(token), 8)))
	return nil
}

func (c cli) do(method, apiPath string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequest(method, c.baseURL+apiPath, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var apiErr apiError
		if json.Unmarshal(data, &apiErr) == nil && apiErr.Message != "" {
			return fmt.Errorf("%s: %s", apiErr.Code, apiErr.Message)
		}
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(data, out)
}

func resolveBaseURL(addr, configPath string) (string, error) {
	if strings.TrimSpace(addr) == "" {
		if configPath != "" {
			if err := os.Setenv("HERMIT_CONFIG_FILE", configPath); err != nil {
				return "", err
			}
		}
		cfg, err := config.Load()
		if err != nil {
			return "", err
		}
		addr = cfg.ListenAddress
	}
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return "", errors.New("empty Hermit address")
	}
	if strings.HasPrefix(addr, ":") {
		return "http://localhost" + addr, nil
	}
	if strings.Contains(addr, "://") {
		return strings.TrimRight(addr, "/"), nil
	}
	return "http://" + strings.TrimRight(addr, "/"), nil
}

type tokenOptions struct {
	token               string
	tokenStdin          bool
	envFile             string
	tokenEnv            string
	credentialHost      string
	useCredentialHelper bool
}

func resolveToken(options tokenOptions, stdin io.Reader, stderr io.Writer) (string, error) {
	if strings.TrimSpace(options.token) != "" {
		return strings.TrimSpace(options.token), nil
	}
	if strings.TrimSpace(options.envFile) != "" {
		name := strings.TrimSpace(options.tokenEnv)
		if name == "" {
			name = "HERMIT_PAT"
		}
		values, err := parseEnvFile(options.envFile)
		if err != nil {
			return "", err
		}
		value := strings.TrimSpace(values[name])
		if value == "" {
			return "", fmt.Errorf("token variable %q not found in %s", name, options.envFile)
		}
		return value, nil
	}
	if strings.TrimSpace(options.tokenEnv) != "" {
		value := strings.TrimSpace(os.Getenv(options.tokenEnv))
		if value == "" {
			return "", fmt.Errorf("token environment variable %q is empty or unset", options.tokenEnv)
		}
		return value, nil
	}
	if options.useCredentialHelper || strings.TrimSpace(options.credentialHost) != "" {
		host := strings.TrimSpace(options.credentialHost)
		if host == "" {
			host = "github.com"
		}
		return readGitCredential(host)
	}
	if options.tokenStdin {
		data, err := io.ReadAll(stdin)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(data)), nil
	}
	if term.IsTerminal(int(syscall.Stdin)) {
		fmt.Fprint(stderr, "Personal access token: ")
		data, err := term.ReadPassword(int(syscall.Stdin))
		fmt.Fprintln(stderr)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(data)), nil
	}
	return "", errors.New("token required; use --token-stdin, --env-file, --token-env, or --git-credential in non-interactive shells")
}

func readGitCredential(host string) (string, error) {
	cmd := exec.Command("git", "credential", "fill")
	cmd.Stdin = strings.NewReader(fmt.Sprintf("protocol=https\nhost=%s\n\n", host))
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return "", fmt.Errorf("git credential helper failed: %s", message)
		}
		return "", fmt.Errorf("git credential helper failed: %w", err)
	}
	for _, line := range strings.Split(stdout.String(), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok && key == "password" && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value), nil
		}
	}
	return "", fmt.Errorf("git credential helper did not return a password for %s", host)
}

var envNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func parseEnvFile(filePath string) (map[string]string, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}
	values := map[string]string{}
	for lineNumber, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid .env line %d: missing '='", lineNumber+1)
		}
		name := strings.TrimSpace(parts[0])
		if !envNamePattern.MatchString(name) {
			return nil, fmt.Errorf("invalid .env line %d: invalid variable name %q", lineNumber+1, name)
		}
		value, err := parseEnvValue(strings.TrimSpace(parts[1]))
		if err != nil {
			return nil, fmt.Errorf("invalid .env line %d: %w", lineNumber+1, err)
		}
		values[name] = value
	}
	return values, nil
}

func parseEnvValue(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	quote := value[0]
	if quote == '\'' || quote == '"' {
		if len(value) < 2 || value[len(value)-1] != quote {
			return "", errors.New("unterminated quoted value")
		}
		return value[1 : len(value)-1], nil
	}
	if idx := strings.Index(value, " #"); idx >= 0 {
		value = value[:idx]
	}
	return strings.TrimSpace(value), nil
}

func resolveBundleID(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	data, err := os.ReadFile(filepath.Join("hermit-native", "Local.xcconfig"))
	if err != nil {
		return "", fmt.Errorf("resolve bundle id: %w", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "HERMIT_BUNDLE_ID") {
			continue
		}
		_, value, ok := strings.Cut(line, "=")
		if ok {
			bundleID := strings.TrimSpace(value)
			if bundleID != "" {
				return bundleID, nil
			}
		}
	}
	return "", errors.New("HERMIT_BUNDLE_ID not found in hermit-native/Local.xcconfig")
}

func resolveRegistryBaseURL(registryName, explicitBaseURL, configPath string) (string, error) {
	if strings.TrimSpace(explicitBaseURL) != "" {
		return strings.TrimRight(strings.TrimSpace(explicitBaseURL), "/"), nil
	}
	if configPath != "" {
		if err := os.Setenv("HERMIT_CONFIG_FILE", configPath); err != nil {
			return "", err
		}
	}
	cfg, err := config.Load()
	if err != nil {
		return "", err
	}
	name := strings.TrimSpace(registryName)
	if name == "" {
		name = "github"
	}
	for _, registry := range cfg.Registries {
		if registry.Name == name {
			return strings.TrimRight(strings.TrimSpace(registry.BaseURL), "/"), nil
		}
	}
	return "", fmt.Errorf("registry %q not found in config", name)
}

func resolveEmbeddedServerBaseURL(configPath string) (string, error) {
	if configPath != "" {
		if err := os.Setenv("HERMIT_CONFIG_FILE", configPath); err != nil {
			return "", err
		}
	}
	cfg, err := config.Load()
	if err != nil {
		return "", err
	}
	return resolveBaseURL(cfg.ListenAddress, "")
}

func normalizeNativeEndpoint(registryBaseURL string) string {
	trimmed := strings.TrimRight(strings.TrimSpace(registryBaseURL), "/")
	if strings.HasSuffix(trimmed, "/api/v3") {
		return trimmed
	}
	trimmed = strings.TrimSuffix(trimmed, "/api/v1")
	return trimmed
}

func normalizeDocsPath(docsPath string) string {
	trimmed := strings.TrimSpace(docsPath)
	trimmed = strings.Trim(trimmed, "/")
	if trimmed == "" {
		return "docs-cms/rfcs"
	}
	return trimmed
}

func accountDisplayName(registry, endpoint string) string {
	if registry == "github-enterprise" {
		if host := hostFromURL(endpoint); host != "" {
			return host
		}
	}
	if host := hostFromURL(endpoint); host != "" {
		return host
	}
	return "Hermit"
}

func hostFromURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return parsed.Host
}

func nativePrefsPlistPath(bundleID string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Containers", bundleID, "Data", "Library", "Preferences", bundleID+".plist")
}

func loadNativePrefs(bundleID string) (nativePrefs, error) {
	path := nativePrefsPlistPath(bundleID)
	prefs := nativePrefs{}

	if raw, err := readPlistValue(path, `hermit\.accounts`); err == nil && raw != "" {
		decoded, err := decodePlistJSONData(raw)
		if err != nil {
			return prefs, err
		}
		if err := json.Unmarshal(decoded, &prefs.Accounts); err != nil {
			return prefs, err
		}
	}
	if raw, err := readPlistValue(path, `hermit\.repositories`); err == nil && raw != "" {
		decoded, err := decodePlistJSONData(raw)
		if err != nil {
			return prefs, err
		}
		if err := json.Unmarshal(decoded, &prefs.Repositories); err != nil {
			return prefs, err
		}
	}
	prefs.AccountsActiveID, _ = readDefaultsString(bundleID, "hermit.accounts.activeID")
	prefs.RepositoriesActiveID, _ = readDefaultsString(bundleID, "hermit.repositories.activeID")
	prefs.BaseURL, _ = readDefaultsString(bundleID, "hermit.baseURL")
	prefs.ServerBaseURL, _ = readDefaultsString(bundleID, "hermit.serverBaseURL")
	prefs.RepoOwner, _ = readDefaultsString(bundleID, "hermit.repoOwner")
	prefs.RepoName, _ = readDefaultsString(bundleID, "hermit.repoName")
	prefs.DocsPath, _ = readDefaultsString(bundleID, "hermit.docsPath")
	prefs.RFCLabel, _ = readDefaultsString(bundleID, "hermit.rfcLabel")
	prefs.ServerMode, _ = readDefaultsString(bundleID, "hermit.serverMode")
	return prefs, nil
}

func saveNativePrefs(bundleID string, prefs nativePrefs) error {
	accountsJSON, err := json.Marshal(prefs.Accounts)
	if err != nil {
		return err
	}
	reposJSON, err := json.Marshal(prefs.Repositories)
	if err != nil {
		return err
	}
	plistPath := nativePrefsPlistPath(bundleID)
	if err := os.MkdirAll(filepath.Dir(plistPath), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(plistPath); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(plistPath, []byte("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict/></plist>"), 0o644); err != nil {
			return err
		}
	}
	if err := writeDefaultsString(bundleID, "hermit.baseURL", prefs.BaseURL); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.serverBaseURL", prefs.ServerBaseURL); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.repoOwner", prefs.RepoOwner); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.repoName", prefs.RepoName); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.docsPath", prefs.DocsPath); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.rfcLabel", prefs.RFCLabel); err != nil {
		return err
	}
	if err := writeDefaultsStringValue(bundleID, "hermit.serverMode", prefs.ServerMode); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.accounts.activeID", prefs.AccountsActiveID); err != nil {
		return err
	}
	if err := writeDefaultsString(bundleID, "hermit.repositories.activeID", prefs.RepositoriesActiveID); err != nil {
		return err
	}
	if err := writePlistDataValue(plistPath, `hermit\.accounts`, accountsJSON); err != nil {
		return err
	}
	if err := writePlistDataValue(plistPath, `hermit\.repositories`, reposJSON); err != nil {
		return err
	}
	return nil
}

func findOrCreateAccount(prefs *nativePrefs, endpoint, accountName, token string) (string, bool) {
	for i := range prefs.Accounts {
		if strings.EqualFold(strings.TrimRight(prefs.Accounts[i].Endpoint, "/"), strings.TrimRight(endpoint, "/")) {
			tokenChanged := prefs.Accounts[i].Token != token
			prefs.Accounts[i].Name = firstNonEmpty(accountName, prefs.Accounts[i].Name)
			prefs.Accounts[i].Endpoint = endpoint
			prefs.Accounts[i].Token = token
			return prefs.Accounts[i].ID, tokenChanged
		}
	}
	accountID := newUUID()
	prefs.Accounts = append(prefs.Accounts, nativeConnection{
		ID:       accountID,
		Name:     accountName,
		Endpoint: endpoint,
		Token:    token,
	})
	return accountID, true
}

func findOrCreateAccountWithoutToken(prefs *nativePrefs, endpoint, accountName string) string {
	for i := range prefs.Accounts {
		if strings.EqualFold(strings.TrimRight(prefs.Accounts[i].Endpoint, "/"), strings.TrimRight(endpoint, "/")) {
			prefs.Accounts[i].Name = firstNonEmpty(accountName, prefs.Accounts[i].Name)
			prefs.Accounts[i].Endpoint = endpoint
			return prefs.Accounts[i].ID
		}
	}
	accountID := newUUID()
	prefs.Accounts = append(prefs.Accounts, nativeConnection{
		ID:       accountID,
		Name:     firstNonEmpty(accountName, accountDisplayName("", endpoint)),
		Endpoint: endpoint,
	})
	return accountID
}

func upsertRepository(prefs *nativePrefs, accountID, owner, name, docsPath, rfcLabel string) string {
	return upsertRepositoryWithServerID(prefs, accountID, owner, name, docsPath, rfcLabel, "")
}

func upsertRepositoryWithServerID(prefs *nativePrefs, accountID, owner, name, docsPath, rfcLabel, serverID string) string {
	for i := range prefs.Repositories {
		if strings.EqualFold(prefs.Repositories[i].Owner, owner) && strings.EqualFold(prefs.Repositories[i].Name, name) {
			prefs.Repositories[i].AccountID = accountID
			prefs.Repositories[i].DocsPath = docsPath
			prefs.Repositories[i].RFCLabel = rfcLabel
			if serverID != "" {
				prefs.Repositories[i].ServerID = serverID
			}
			return prefs.Repositories[i].ID
		}
	}
	repoID := newUUID()
	prefs.Repositories = append(prefs.Repositories, nativeRepository{
		ID:        repoID,
		AccountID: accountID,
		Owner:     owner,
		Name:      name,
		DocsPath:  docsPath,
		RFCLabel:  rfcLabel,
		ServerID:  serverID,
	})
	return repoID
}

func shareConfigFromPrefs(prefs nativePrefs) shareConfig {
	accountByID := make(map[string]nativeConnection, len(prefs.Accounts))
	aliasByID := make(map[string]string, len(prefs.Accounts))
	usedAliases := map[string]int{}

	accounts := make([]shareAccount, 0, len(prefs.Accounts))
	for _, account := range prefs.Accounts {
		accountByID[account.ID] = account
		alias := uniqueAlias(shareAccountAlias(account), usedAliases)
		aliasByID[account.ID] = alias
		accounts = append(accounts, shareAccount{
			ID:       alias,
			Name:     account.Name,
			Endpoint: account.Endpoint,
		})
	}

	repositories := make([]shareRepository, 0, len(prefs.Repositories))
	for _, repo := range prefs.Repositories {
		accountAlias := aliasByID[repo.AccountID]
		if accountAlias == "" {
			if account, ok := accountByID[repo.AccountID]; ok {
				accountAlias = uniqueAlias(shareAccountAlias(account), usedAliases)
			}
		}
		repositories = append(repositories, shareRepository{
			Account:  accountAlias,
			Owner:    repo.Owner,
			Name:     repo.Name,
			DocsPath: normalizeDocsPath(repo.DocsPath),
			RFCLabel: firstNonEmpty(repo.RFCLabel, "hermit:rfc-ready"),
			ServerID: repo.ServerID,
		})
	}

	return shareConfig{Version: 1, Accounts: accounts, Repositories: repositories}
}

func readShareConfig(filePath string) (shareConfig, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return shareConfig{}, err
	}
	var cfg shareConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return shareConfig{}, err
	}
	if cfg.Version == 0 {
		cfg.Version = 1
	}
	if cfg.Version != 1 {
		return shareConfig{}, fmt.Errorf("unsupported repo config version %d", cfg.Version)
	}
	if len(cfg.Accounts) == 0 {
		return shareConfig{}, errors.New("repo config has no accounts")
	}
	return cfg, nil
}

func resolveNativeAccountID(prefs nativePrefs, explicitAccountID, endpoint string) (string, error) {
	if explicitAccountID != "" {
		for _, account := range prefs.Accounts {
			if account.ID == explicitAccountID {
				return account.ID, nil
			}
		}
		return "", fmt.Errorf("account id %q not found", explicitAccountID)
	}
	if endpoint == "" {
		if len(prefs.Accounts) == 1 {
			return prefs.Accounts[0].ID, nil
		}
		return "", errors.New("multiple accounts configured; pass --endpoint or --account-id")
	}
	normalized := strings.TrimRight(endpoint, "/")
	for _, account := range prefs.Accounts {
		if strings.EqualFold(strings.TrimRight(account.Endpoint, "/"), normalized) {
			return account.ID, nil
		}
	}
	return "", fmt.Errorf("account endpoint %q not found; import repo config first", endpoint)
}

func shareAccountAlias(account nativeConnection) string {
	if host := hostFromURL(account.Endpoint); host != "" {
		return slugify(host)
	}
	if account.Name != "" {
		return slugify(account.Name)
	}
	return "account"
}

func uniqueAlias(alias string, used map[string]int) string {
	if alias == "" {
		alias = "account"
	}
	used[alias]++
	if used[alias] == 1 {
		return alias
	}
	return fmt.Sprintf("%s-%d", alias, used[alias])
}

func slugify(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
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

func writeNativeKeychainToken(accountID, token string) error {
	key := "hermit.account." + accountID
	cmd := exec.Command("security", "add-generic-password", "-a", key, "-s", "HermitNative", "-w", token, "-T", "", "-U")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return fmt.Errorf("write native keychain token: %s", message)
		}
		return fmt.Errorf("write native keychain token: %w", err)
	}
	return nil
}

func readDefaultsString(domain, key string) (string, error) {
	cmd := exec.Command("defaults", "read", domain, key)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return strings.TrimSpace(stdout.String()), nil
}

func writeDefaultsString(domain, key, value string) error {
	cmd := exec.Command("defaults", "write", domain, key, value)
	return runDefaultsCommand(cmd, key)
}

func writeDefaultsStringValue(domain, key, value string) error {
	cmd := exec.Command("defaults", "write", domain, key, "-string", value)
	return runDefaultsCommand(cmd, key)
}

func runDefaultsCommand(cmd *exec.Cmd, key string) error {
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return fmt.Errorf("defaults write %s: %s", key, message)
		}
		return fmt.Errorf("defaults write %s: %w", key, err)
	}
	return nil
}

func readPlistValue(plistPath, keyPath string) (string, error) {
	cmd := exec.Command("plutil", "-extract", keyPath, "raw", "-o", "-", plistPath)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return "", fmt.Errorf("plutil extract %s: %s", keyPath, message)
		}
		return "", fmt.Errorf("plutil extract %s: %w", keyPath, err)
	}
	return strings.TrimSpace(stdout.String()), nil
}

func writePlistDataValue(plistPath, keyPath string, data []byte) error {
	encoded := base64.StdEncoding.EncodeToString(data)
	cmd := exec.Command("plutil", "-replace", keyPath, "-data", encoded, plistPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return fmt.Errorf("plutil replace %s: %s", keyPath, message)
		}
		return fmt.Errorf("plutil replace %s: %w", keyPath, err)
	}
	return nil
}

func decodePlistJSONData(raw string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(raw))
	if err == nil {
		return decoded, nil
	}
	return []byte(raw), nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func newUUID() string {
	output, err := exec.Command("uuidgen").Output()
	if err == nil {
		return strings.ToLower(strings.TrimSpace(string(output)))
	}
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

func singleID(command string, args []string) (string, error) {
	if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
		return "", fmt.Errorf("usage: hermitctl %s <repository-id>", command)
	}
	return strings.TrimSpace(args[0]), nil
}

func printRepository(w io.Writer, repo repositoryConfig, jsonOut bool) error {
	if jsonOut {
		return printJSON(w, repo)
	}
	fmt.Fprintf(w, "id: %s\n", repo.ID)
	fmt.Fprintf(w, "repository: %s/%s\n", repo.Owner, repo.Name)
	fmt.Fprintf(w, "registry: %s\n", repo.Registry)
	if repo.BaseURL != "" {
		fmt.Fprintf(w, "base_url: %s\n", repo.BaseURL)
	}
	fmt.Fprintf(w, "default_branch: %s\n", repo.DefaultBranch)
	fmt.Fprintf(w, "docs_path_policy: %s\n", repo.DocsPathPolicy)
	fmt.Fprintf(w, "healthy: %t\n", repo.Validation.Healthy)
	if repo.Validation.LastErrorCode != "" {
		fmt.Fprintf(w, "last_error_code: %s\n", repo.Validation.LastErrorCode)
	}
	return nil
}

func printValidation(w io.Writer, validation validationResponse, jsonOut bool) error {
	if jsonOut {
		return printJSON(w, validation)
	}
	fmt.Fprintf(w, "healthy: %t\n", validation.Healthy)
	fmt.Fprintf(w, "validated_at: %s\n", validation.ValidatedAt)
	if validation.LastErrorCode != "" {
		fmt.Fprintf(w, "last_error_code: %s\n", validation.LastErrorCode)
	}
	for _, check := range validation.Checks {
		fmt.Fprintf(w, "check: %s\t%s", check.Name, check.Status)
		if check.Message != "" {
			fmt.Fprintf(w, "\t%s", check.Message)
		}
		fmt.Fprintln(w)
	}
	return nil
}

func printJSON(w io.Writer, value any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: hermitctl [--addr URL|HOST:PORT] [--config path] [--json] <command>")
	fmt.Fprintln(w, "commands: health, logs, repo, review, token")
}

func repoUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: hermitctl repo <command>")
	fmt.Fprintln(w, "commands: add, add-local, export-local, import-local, bind-credential, list, get, remove, validate, review-docs, rotate-token, debug")
}

func reviewUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: hermitctl review <command>")
	fmt.Fprintln(w, "commands: state, list, merge-status, approve, request-changes, dismiss, update-branch, accept, merge, ci-status")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
