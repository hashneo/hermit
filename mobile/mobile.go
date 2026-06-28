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
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"hermit/internal/app"
	"hermit/internal/config"
)

// StartConfig is the JSON structure accepted by Start.
// All fields map directly to hermit config concepts.
//
// Repos is the preferred multi-repo field. The legacy single-repo fields
// (BaseURL/PAT/Owner/Repo/DocsPath/RFCLabel) are still accepted for
// backwards compatibility and are promoted into Repos when Repos is empty.
type StartConfig struct {
	// Multi-repo (preferred)
	Repos   []RepoConfig      `json:"repos"`
	DataDir string            `json:"dataDir"` // app sandbox Application Support dir
	Cache   MobileCacheConfig `json:"cache"`

	// Legacy single-repo fields (promoted to Repos when Repos is empty)
	BaseURL  string `json:"baseURL"`
	PAT      string `json:"pat"`
	Owner    string `json:"owner"`
	Repo     string `json:"repo"`
	DocsPath string `json:"docsPath"`
	RFCLabel string `json:"rfcLabel"`
}

type MobileCacheConfig struct {
	RepositoryRFCListReadTTLSeconds *int `json:"repositoryRFCListReadTTLSeconds"`
	RepositoryRFCListJitterSeconds  *int `json:"repositoryRFCListJitterSeconds"`
}

// RepoConfig describes one repository to register with the server.
type RepoConfig struct {
	BaseURL  string `json:"baseURL"`
	PAT      string `json:"pat"`
	Owner    string `json:"owner"`
	Repo     string `json:"repo"`
	DocsPath string `json:"docsPath"`
	RFCLabel string `json:"rfcLabel"`
}

var (
	mu         sync.Mutex
	cancelFunc context.CancelFunc
	doneCh     chan struct{}
)

// SetLogFile redirects the Go server's structured logger (slog) to append to
// the given file path. Call this before Start so all server logs land in the
// same file as the Swift esLog output. Safe to call multiple times — each call
// replaces the previous handler.
func SetLogFile(path string) string {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Sprintf("error: open log file: %s", err)
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(f, &slog.HandlerOptions{
		Level: slog.LevelDebug,
	})))
	return "ok"
}

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

	// Find a free port by binding on all interfaces (0.0.0.0) so that both
	// the local Mac (127.0.0.1) and iPad clients on the LAN can reach the
	// server. Binding only to 127.0.0.1 would block iPad → Mac connections
	// because the iPad reaches the Mac via its LAN IP, not loopback.
	ln, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		return fmt.Sprintf("error: bind port: %s", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	cfg.ListenAddress = fmt.Sprintf("0.0.0.0:%d", port)

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
func buildConfig(sc StartConfig) (config.Config, error) {
	// Promote legacy single-repo fields when Repos is empty.
	if len(sc.Repos) == 0 {
		if sc.PAT == "" {
			return config.Config{}, errors.New("pat is required")
		}
		if sc.Owner == "" || sc.Repo == "" {
			return config.Config{}, errors.New("owner and repo are required")
		}
		sc.Repos = []RepoConfig{{
			BaseURL:  sc.BaseURL,
			PAT:      sc.PAT,
			Owner:    sc.Owner,
			Repo:     sc.Repo,
			DocsPath: sc.DocsPath,
			RFCLabel: sc.RFCLabel,
		}}
	}

	dataDir := sc.DataDir
	if dataDir == "" {
		dataDir = "."
	}

	// Build a registry per unique base URL so repos on different hosts work.
	type registryKey struct{ baseURL string }
	registryNames := map[registryKey]string{}
	var registries []config.Registry
	registrySeq := 0

	for i := range sc.Repos {
		r := &sc.Repos[i]
		if r.BaseURL == "" {
			r.BaseURL = "https://api.github.com"
		}
		if r.DocsPath == "" {
			r.DocsPath = "docs-cms/rfcs/"
		}
		if r.RFCLabel == "" {
			r.RFCLabel = "hermit:rfc-ready"
		}
		key := registryKey{r.BaseURL}
		if _, ok := registryNames[key]; !ok {
			name := fmt.Sprintf("registry-%d", registrySeq)
			registrySeq++
			registryNames[key] = name
			registries = append(registries, config.Registry{
				Name:    name,
				Kind:    "github",
				BaseURL: r.BaseURL,
			})
		}
	}

	var repositories []config.Repository
	for _, r := range sc.Repos {
		if r.PAT == "" || r.Owner == "" || r.Repo == "" {
			continue // skip incomplete entries
		}
		registryName := registryNames[registryKey{r.BaseURL}]
		repositories = append(repositories, config.Repository{
			Owner:          r.Owner,
			Name:           r.Repo,
			Registry:       registryName,
			DefaultBranch:  "main",
			DocsPathPolicy: r.DocsPath,
			RFCLabel:       r.RFCLabel,
			Token:          r.PAT,
		})
	}

	if len(repositories) == 0 {
		return config.Config{}, errors.New("no valid repositories configured")
	}

	cfg := config.Config{
		Environment:   "production",
		ListenAddress: "0.0.0.0:0", // overridden by Start()
		Registries:    registries,
		Repositories:  repositories,
		DataDir:       filepath.Join(dataDir, "hermit"),
	}
	if sc.Cache.RepositoryRFCListReadTTLSeconds != nil && *sc.Cache.RepositoryRFCListReadTTLSeconds > 0 {
		cfg.Cache.RepositoryRFCList.ReadTTL.Duration = time.Duration(*sc.Cache.RepositoryRFCListReadTTLSeconds) * time.Second
	}
	if sc.Cache.RepositoryRFCListJitterSeconds != nil && *sc.Cache.RepositoryRFCListJitterSeconds >= 0 {
		cfg.Cache.RepositoryRFCList.Jitter.Duration = time.Duration(*sc.Cache.RepositoryRFCListJitterSeconds) * time.Second
	}
	return cfg, nil
}
