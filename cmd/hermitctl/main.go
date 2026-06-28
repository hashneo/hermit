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
	case "health":
		return c.runHealth(stdout)
	default:
		return fmt.Errorf("unknown command %q", remaining[0])
	}
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
	fmt.Fprintln(w, "commands: health, repo, token")
}

func repoUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: hermitctl repo <command>")
	fmt.Fprintln(w, "commands: add, add-local, export-local, import-local, bind-credential, list, get, remove, validate, rotate-token, debug")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
