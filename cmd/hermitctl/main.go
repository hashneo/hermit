package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
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

func (c cli) repoAdd(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("repo add", flag.ContinueOnError)
	fs.SetOutput(stderr)
	owner := fs.String("owner", "", "repository owner")
	name := fs.String("name", "", "repository name")
	registry := fs.String("registry", "github", "configured registry name")
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
	fmt.Fprintln(w, "commands: add, list, get, remove, validate, rotate-token, debug")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
