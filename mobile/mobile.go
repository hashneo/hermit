// Package mobile exposes a gomobile-compatible interface for embedding the
// Hermit Go server inside a native Swift application (macOS via gomobile bind).
//
// Only types and functions with basic types (string, int, error) are exported
// so that gomobile bind can generate the ObjC/Swift bridging layer correctly.
//
// Usage from Swift (macOS):
//
//	let portOrError = MobileStart(configJSON)
//	// portOrError is either "8765" or "error: <message>"
//	MobileStop()
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"sync"

	"hermit/internal/app"
	"hermit/internal/config"
)

// StartConfig is the JSON structure accepted by Start.
// All fields map directly to hermit config concepts.
type StartConfig struct {
	BaseURL       string `json:"baseURL"`
	PAT           string `json:"pat"`
	Owner         string `json:"owner"`
	Repo          string `json:"repo"`
	DocsPath      string `json:"docsPath"`
	RFCLabel      string `json:"rfcLabel"`
	DataDir       string `json:"dataDir"`      // app sandbox Application Support dir
	ConfigFile    string `json:"configFile"`   // optional: path to hermit.yaml override
}

var (
	mu         sync.Mutex
	cancelFunc context.CancelFunc
	doneCh     chan struct{}
)

// Start initialises and runs the embedded Hermit server on a random free port.
// configJSON must be a JSON-encoded StartConfig.
// Returns the bound port as a decimal string (e.g. "8765") on success, or
// "error: <message>" on failure — a plain string return keeps gomobile happy.
func Start(configJSON string) string {
	mu.Lock()
	defer mu.Unlock()

	if cancelFunc != nil {
		return "error: server already running — call Stop() first"
	}

	var sc StartConfig
	if err := json.Unmarshal([]byte(configJSON), &sc); err != nil {
		return fmt.Sprintf("error: parse config: %s", err)
	}

	cfg, err := buildConfig(sc)
	if err != nil {
		return fmt.Sprintf("error: build config: %s", err)
	}

	// Find a free port and bind it before handing off to the app so we can
	// return the port immediately without a race.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Sprintf("error: bind port: %s", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	cfg.ListenAddress = fmt.Sprintf("127.0.0.1:%d", port)

	// Close our listener — app.New will re-bind to the same address.
	// We hold the mutex so nothing else can race here.
	ln.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancelFunc = cancel
	doneCh = make(chan struct{})

	application := app.New(cfg)

	go func() {
		defer close(doneCh)
		if err := application.Run(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			// Non-fatal: log to stderr; Swift side sees the port already.
			fmt.Printf("[hermit/mobile] server stopped with error: %v\n", err)
		}
	}()

	return fmt.Sprintf("%d", port)
}

// Stop gracefully shuts down the embedded server started by Start.
// Safe to call even if the server is not running.
func Stop() {
	mu.Lock()
	cancel := cancelFunc
	done := doneCh
	cancelFunc = nil
	doneCh = nil
	mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}
}

// buildConfig constructs a hermit config.Config from a StartConfig.
// It writes a minimal in-memory YAML config so config.Load() isn't needed;
// instead we populate config.Config directly.
func buildConfig(sc StartConfig) (config.Config, error) {
	if sc.PAT == "" {
		return config.Config{}, errors.New("pat is required")
	}
	if sc.Owner == "" || sc.Repo == "" {
		return config.Config{}, errors.New("owner and repo are required")
	}
	if sc.BaseURL == "" {
		sc.BaseURL = "https://api.github.com"
	}
	if sc.DocsPath == "" {
		sc.DocsPath = "docs-cms/rfcs/"
	}
	if sc.RFCLabel == "" {
		sc.RFCLabel = "hermit:rfc-ready"
	}

	dataDir := sc.DataDir
	if dataDir == "" {
		dataDir = "."
	}

	// Inject the PAT via the env-var mechanism that config.Repository uses.
	// We use a synthetic env-var name and set it in the process environment.
	// This is safe because we're in a sandboxed app process.
	envVarName := "HERMIT_MOBILE_PAT"
	if err := setEnv(envVarName, sc.PAT); err != nil {
		return config.Config{}, fmt.Errorf("set PAT env: %w", err)
	}

	cfg := config.Config{
		Environment:   "production",
		ListenAddress: "127.0.0.1:0", // overridden by Start()
		Registries: []config.Registry{
			{
				Name:        "github",
				Kind:        "github",
				BaseURL:     sc.BaseURL,
				TokenEnvVar: envVarName,
			},
		},
		Repositories: []config.Repository{
			{
				Owner:          sc.Owner,
				Name:           sc.Repo,
				Registry:       "github",
				DefaultBranch:  "main",
				DocsPathPolicy: sc.DocsPath,
				TokenEnvVar:    envVarName,
			},
		},
		DataDir: filepath.Join(dataDir, "hermit"),
	}

	return cfg, nil
}
