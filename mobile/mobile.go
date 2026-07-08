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
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"hermit/internal/app"
	"hermit/internal/config"
)

// StartConfig is the JSON structure accepted by Start.
type StartConfig struct {
	// Multi-repo (preferred)
	Repos   []RepoConfig      `json:"repos"`
	DataDir string            `json:"dataDir"`
	Cache   MobileCacheConfig `json:"cache"`
	// PairedTokens is the current set of valid iPad bearer tokens.
	PairedTokens []string `json:"pairedTokens"`
	// TLS — cert file path (on disk) + key PEM (from Keychain, in-memory only).
	// When both are present the server listens on TLS/1.3 instead of plain HTTP.
	TLSCertFile string `json:"tlsCertFile"`
	TLSKeyPEM   string `json:"tlsKeyPEM"`

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
	mu             sync.Mutex
	cancelFunc     context.CancelFunc
	doneCh         chan struct{}
	runningApp     *app.App // kept for live token registration/revocation
	tlsFingerprint string   // SHA-256 hex of current TLS cert DER
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
	runningApp = application

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
	runningApp = nil
	mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}
}

// RegisterPairedToken adds a new bearer token to the running server's auth set.
// Called from Swift immediately after a successful pairing handshake.
// Returns "ok" or "error: server not running".
func RegisterPairedToken(token string) string {
	mu.Lock()
	a := runningApp
	mu.Unlock()
	if a == nil {
		return "error: server not running"
	}
	a.Auth.Register(token)
	return "ok"
}

// RevokePairedToken removes a bearer token from the running server's auth set.
// Called from Swift when the user revokes a paired device in Settings.
// Returns "ok" or "error: server not running".
func RevokePairedToken(token string) string {
	mu.Lock()
	a := runningApp
	mu.Unlock()
	if a == nil {
		return "error: server not running"
	}
	a.Auth.Revoke(token)
	return "ok"
}

// GetTLSFingerprint returns the SHA-256 hex fingerprint of the current TLS
// certificate.  Returns an empty string if TLS is not configured or the
// server has not been started yet.
func GetTLSFingerprint() string {
	mu.Lock()
	defer mu.Unlock()
	return tlsFingerprint
}

// GenerateTLSCert generates a new ECDSA P-256 self-signed TLS certificate,
// writes the certificate PEM to <dataDir>/hermit/tls.crt, and returns a JSON
// string:
//
//	{"certFile":"<path>","keyPEM":"<pem>","fingerprint":"<sha256-hex>"}
//
// The private key is NEVER written to disk — it is returned as a PEM string
// for the caller (Swift) to store in the Keychain.  Call this once and store
// the key; on subsequent launches pass both back via StartConfig.
//
// Returns "error: <message>" on failure (gomobile-safe single string return).
func GenerateTLSCert(dataDir string) string {
	hermitDir := filepath.Join(dataDir, "hermit")
	if err := os.MkdirAll(hermitDir, 0o700); err != nil {
		return fmt.Sprintf("error: mkdir: %s", err)
	}

	// Generate ECDSA P-256 key.
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Sprintf("error: generate key: %s", err)
	}

	// Self-signed certificate — 20-year validity.
	// SANs covering loopback AND the Mac's mDNS hostname (e.g. Stevens-MacBook-Air.local)
	// so standard TLS hostname verification passes for both Mac→Mac and iPad→Mac paths.
	// os.Hostname() returns the short name; append ".local" for mDNS.
	dnsNames := []string{"localhost"}
	if h, err := os.Hostname(); err == nil && h != "" {
		// os.Hostname may or may not include the .local suffix depending on
		// the macOS network configuration.  Normalise to always add one entry
		// with and one without — deduplicating if the suffix is already present.
		bare := strings.TrimSuffix(h, ".local")
		dnsNames = append(dnsNames, bare, bare+".local")
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "Hermit Local Server"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(20 * 365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
		DNSNames:     dnsNames,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &priv.PublicKey, priv)
	if err != nil {
		return fmt.Sprintf("error: create cert: %s", err)
	}

	// Write cert PEM to disk (public — not secret).
	certFile := filepath.Join(hermitDir, "tls.crt")
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	if err := os.WriteFile(certFile, certPEM, 0o644); err != nil {
		return fmt.Sprintf("error: write cert: %s", err)
	}

	// Encode key PEM — returned to Swift for Keychain storage, never written to disk.
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return fmt.Sprintf("error: marshal key: %s", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	fp := certPEMFingerprint(certPEM)

	result, _ := json.Marshal(map[string]string{
		"certFile":    certFile,
		"keyPEM":      string(keyPEM),
		"fingerprint": fp,
	})
	return string(result)
}

// certPEMFingerprint returns the hex-encoded SHA-256 digest of the first
// DER-encoded certificate in a PEM block.
func certPEMFingerprint(certPEM []byte) string {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		return ""
	}
	sum := sha256.Sum256(block.Bytes)
	return fmt.Sprintf("%x", sum)
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
			r.RFCLabel = ""
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
		PairedTokens:  sc.PairedTokens,
		TLSCertFile:   sc.TLSCertFile,
		TLSKeyPEM:     sc.TLSKeyPEM,
	}
	if sc.Cache.RepositoryRFCListReadTTLSeconds != nil && *sc.Cache.RepositoryRFCListReadTTLSeconds > 0 {
		cfg.Cache.RepositoryRFCList.ReadTTL.Duration = time.Duration(*sc.Cache.RepositoryRFCListReadTTLSeconds) * time.Second
	}
	if sc.Cache.RepositoryRFCListJitterSeconds != nil && *sc.Cache.RepositoryRFCListJitterSeconds >= 0 {
		cfg.Cache.RepositoryRFCList.Jitter.Duration = time.Duration(*sc.Cache.RepositoryRFCListJitterSeconds) * time.Second
	}

	// Compute and cache TLS fingerprint if cert is provided.
	if sc.TLSCertFile != "" {
		if certPEM, err := os.ReadFile(sc.TLSCertFile); err == nil {
			tlsFingerprint = certPEMFingerprint(certPEM)
		}
	}

	return cfg, nil
}
