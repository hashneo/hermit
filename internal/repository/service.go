package repository

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"hermit/internal/config"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// hermitPATEnvVar is a fallback for the subprocess dev path.
// When the Go server is launched as a subprocess by the native app,
// the native app sets this env var to the keychain PAT.
// In embedded (gomobile) mode this is never set; the PAT flows via
// config.Repository.Token instead.
const hermitPATEnvVar = "HERMIT_PAT"

type AuthMetadata struct {
	Method               string  `json:"method"`
	TokenLastValidatedAt *string `json:"token_last_validated_at"`
}

type ValidationCheckResponse struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type ValidationResponse struct {
	Healthy       bool                      `json:"healthy"`
	Checks        []ValidationCheckResponse `json:"checks"`
	ValidatedAt   string                    `json:"validated_at"`
	LastErrorCode string                    `json:"last_error_code,omitempty"`
}

type Config struct {
	ID             string             `json:"id"`
	Owner          string             `json:"owner"`
	Name           string             `json:"name"`
	Registry       string             `json:"registry"`
	BaseURL        string             `json:"base_url,omitempty"`
	DefaultBranch  string             `json:"default_branch"`
	DocsPathPolicy string             `json:"docs_path_policy"`
	RFCLabel       string             `json:"rfc_label"`
	Auth           AuthMetadata       `json:"auth"`
	Validation     ValidationResponse `json:"validation"`
	CreatedAt      string             `json:"created_at"`
	UpdatedAt      string             `json:"updated_at"`
}

type createInput struct {
	Owner          string
	Name           string
	Registry       string
	BaseURL        string
	Token          string
	DefaultBranch  string
	DocsPathPolicy string
	RFCLabel       string
}

type rotateTokenInput struct {
	Token string
}

type storedConfig struct {
	Config
	EncryptedToken string
}

type Service struct {
	mu             sync.RWMutex
	items          map[string]storedConfig
	byName         map[string]string
	client         GitHubClient
	now            func() time.Time
	idSeq          atomic.Int64
	storePath      string
	loadedFromDisk bool
}

type persistedStore struct {
	Items []storedConfig `json:"items"`
}

func repositoryKey(registry, owner, name string) string {
	if registry == "" {
		registry = "github"
	}
	return fmt.Sprintf("%s:%s/%s", registry, owner, name)
}

func NewService(client GitHubClient) *Service {
	if client == nil {
		client = NewInMemoryGitHubClient()
	}
	s := &Service{
		items:  make(map[string]storedConfig),
		byName: make(map[string]string),
		client: client,
		now:    time.Now,
	}
	s.idSeq.Store(2000)
	return s
}

func NewPersistentService(client GitHubClient, dataDir string) *Service {
	s := NewService(client)
	if strings.TrimSpace(dataDir) == "" {
		return s
	}
	s.storePath = filepath.Join(dataDir, "repositories.json")
	if err := s.loadFromDisk(); err != nil {
		// Treat malformed local repository state as empty rather than preventing
		// the embedded server from starting; repository validation will surface
		// missing config in the client.
		return s
	}
	return s
}

func (s *Service) SeedFromConfig(repositories []config.Repository) {
	if s.loadedFromDisk {
		return
	}
	for _, repository := range repositories {
		registry := repository.Registry
		if registry == "" {
			registry = "github"
		}

		key := repositoryKey(registry, repository.Owner, repository.Name)
		s.mu.Lock()
		if _, exists := s.byName[key]; exists {
			s.mu.Unlock()
			continue
		}
		now := s.now().UTC().Format(time.RFC3339)
		defaultBranch := repository.DefaultBranch
		if defaultBranch == "" {
			defaultBranch = "main"
		}
		docsPath := repository.DocsPathPolicy
		if docsPath == "" {
			docsPath = "docs-cms/rfcs/"
		}
		rfcLabel := repository.RFCLabel
		if rfcLabel == "" {
			rfcLabel = "hermit:rfc-ready"
		}

		token := strings.TrimSpace(repository.Token)
		if token == "" {
			token = strings.TrimSpace(os.Getenv(hermitPATEnvVar))
		}
		validation := ValidationResponse{
			Healthy: false,
			Checks: []ValidationCheckResponse{{
				Name:    "token_missing",
				Status:  "warn",
				Message: "no token configured; use the API or native app to set a PAT",
			}},
			ValidatedAt:   now,
			LastErrorCode: "token_missing",
		}
		var validatedAt *string
		if token != "" {
			result := s.client.ValidatePAT(context.Background(), repository.Owner, repository.Name, token)
			checks := make([]ValidationCheckResponse, 0, len(result.Checks))
			for _, c := range result.Checks {
				checks = append(checks, ValidationCheckResponse{Name: c.Name, Status: c.Status, Message: c.Message})
			}
			validation = ValidationResponse{
				Healthy:       result.Healthy,
				Checks:        checks,
				ValidatedAt:   now,
				LastErrorCode: result.LastErrorCode,
			}
			if result.Healthy {
				validatedAt = &now
			}
		}

		cfg := Config{
			ID:             s.newID(),
			Owner:          repository.Owner,
			Name:           repository.Name,
			Registry:       registry,
			DefaultBranch:  defaultBranch,
			DocsPathPolicy: docsPath,
			RFCLabel:       rfcLabel,
			Auth: AuthMetadata{
				Method:               "pat",
				TokenLastValidatedAt: validatedAt,
			},
			Validation: validation,
			CreatedAt:  now,
			UpdatedAt:  now,
		}
		s.items[cfg.ID] = storedConfig{Config: cfg, EncryptedToken: encryptToken(token)}
		s.byName[key] = cfg.ID
		_ = s.saveLocked()
		s.mu.Unlock()
	}
}

// ReplaceFromConfig makes the repository store match the supplied config.
//
// This is intended for embedded/mobile startup, where Swift passes the current
// native RepositoryStore snapshot, including in-memory PATs, on every launch.
// In that mode the native config is authoritative and stale server-side
// repositories.json entries must not hide newly configured repos.
func (s *Service) ReplaceFromConfig(repositories []config.Repository) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.now().UTC().Format(time.RFC3339)
	nextItems := make(map[string]storedConfig)
	nextByName := make(map[string]string)

	for _, repository := range repositories {
		registry := repository.Registry
		if registry == "" {
			registry = "github"
		}
		if repository.Owner == "" || repository.Name == "" {
			continue
		}

		key := repositoryKey(registry, repository.Owner, repository.Name)
		existing, exists := s.items[s.byName[key]]
		if !exists {
			existing, exists = s.findByOwnerNameLocked(repository.Owner, repository.Name)
		}

		cfg := s.configFromRepository(repository, now)
		if exists {
			cfg.ID = existing.ID
			cfg.CreatedAt = existing.CreatedAt
		}

		nextItems[cfg.ID] = storedConfig{Config: cfg, EncryptedToken: encryptToken(strings.TrimSpace(repository.Token))}
		nextByName[key] = cfg.ID
	}

	s.items = nextItems
	s.byName = nextByName
	_ = s.saveLocked()
}

func (s *Service) findByOwnerNameLocked(owner, name string) (storedConfig, bool) {
	for _, item := range s.items {
		if strings.EqualFold(item.Owner, owner) && strings.EqualFold(item.Name, name) {
			return item, true
		}
	}
	return storedConfig{}, false
}

func (s *Service) configFromRepository(repository config.Repository, now string) Config {
	registry := repository.Registry
	if registry == "" {
		registry = "github"
	}
	defaultBranch := repository.DefaultBranch
	if defaultBranch == "" {
		defaultBranch = "main"
	}
	docsPath := repository.DocsPathPolicy
	if docsPath == "" {
		docsPath = "docs-cms/rfcs/"
	}
	rfcLabel := repository.RFCLabel
	if rfcLabel == "" {
		rfcLabel = "hermit:rfc-ready"
	}

	token := strings.TrimSpace(repository.Token)
	validation := ValidationResponse{
		Healthy: false,
		Checks: []ValidationCheckResponse{{
			Name:    "token_missing",
			Status:  "warn",
			Message: "no token configured; use the API or native app to set a PAT",
		}},
		ValidatedAt:   now,
		LastErrorCode: "token_missing",
	}
	var validatedAt *string
	if token != "" {
		result := s.client.ValidatePAT(context.Background(), repository.Owner, repository.Name, token)
		checks := make([]ValidationCheckResponse, 0, len(result.Checks))
		for _, c := range result.Checks {
			checks = append(checks, ValidationCheckResponse{Name: c.Name, Status: c.Status, Message: c.Message})
		}
		validation = ValidationResponse{
			Healthy:       result.Healthy,
			Checks:        checks,
			ValidatedAt:   now,
			LastErrorCode: result.LastErrorCode,
		}
		if result.Healthy {
			validatedAt = &now
		}
	}

	return Config{
		ID:             s.newID(),
		Owner:          repository.Owner,
		Name:           repository.Name,
		Registry:       registry,
		DefaultBranch:  defaultBranch,
		DocsPathPolicy: docsPath,
		RFCLabel:       rfcLabel,
		Auth: AuthMetadata{
			Method:               "pat",
			TokenLastValidatedAt: validatedAt,
		},
		Validation: validation,
		CreatedAt:  now,
		UpdatedAt:  now,
	}
}

func (s *Service) Create(ctx context.Context, input createInput) (Config, error) {
	token := strings.TrimSpace(input.Token)

	if input.Owner == "" || input.Name == "" || token == "" {
		return Config{}, fmt.Errorf("owner, name, and personal_access_token are required")
	}
	if input.Registry == "" {
		input.Registry = "github"
	}

	if input.DefaultBranch == "" {
		input.DefaultBranch = "main"
	}
	if input.DocsPathPolicy == "" {
		input.DocsPathPolicy = "docs-cms/rfcs/"
	}
	if input.RFCLabel == "" {
		input.RFCLabel = "hermit:rfc-ready"
	}

	fullName := repositoryKey(input.Registry, input.Owner, input.Name)

	s.mu.Lock()
	if _, exists := s.byName[fullName]; exists {
		s.mu.Unlock()
		return Config{}, fmt.Errorf("repository is already configured")
	}
	s.mu.Unlock()

	validation := s.client.ValidatePAT(ctx, input.Owner, input.Name, token)
	now := s.now().UTC().Format(time.RFC3339)

	checks := make([]ValidationCheckResponse, 0, len(validation.Checks))
	for _, c := range validation.Checks {
		checks = append(checks, ValidationCheckResponse{Name: c.Name, Status: c.Status, Message: c.Message})
	}

	var tokenValidatedAt *string
	if validation.Healthy {
		tokenValidatedAt = &now
	}

	cfg := Config{
		ID:             s.newID(),
		Owner:          input.Owner,
		Name:           input.Name,
		Registry:       input.Registry,
		BaseURL:        strings.TrimRight(strings.TrimSpace(input.BaseURL), "/"),
		DefaultBranch:  input.DefaultBranch,
		DocsPathPolicy: input.DocsPathPolicy,
		RFCLabel:       input.RFCLabel,
		Auth: AuthMetadata{
			Method:               "pat",
			TokenLastValidatedAt: tokenValidatedAt,
		},
		Validation: ValidationResponse{
			Healthy:       validation.Healthy,
			Checks:        checks,
			ValidatedAt:   now,
			LastErrorCode: validation.LastErrorCode,
		},
		CreatedAt: now,
		UpdatedAt: now,
	}

	s.mu.Lock()
	s.items[cfg.ID] = storedConfig{
		Config:         cfg,
		EncryptedToken: encryptToken(token),
	}
	s.byName[fullName] = cfg.ID
	if err := s.saveLocked(); err != nil {
		delete(s.items, cfg.ID)
		delete(s.byName, fullName)
		s.mu.Unlock()
		return Config{}, err
	}
	s.mu.Unlock()

	return cfg, nil
}

func (s *Service) Get(id string) (Config, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	item, ok := s.items[id]
	if !ok {
		return Config{}, false
	}
	return item.Config, true
}

func (s *Service) Delete(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	item, ok := s.items[id]
	if !ok {
		return false
	}
	delete(s.items, id)
	delete(s.byName, repositoryKey(item.Registry, item.Owner, item.Name))
	_ = s.saveLocked()
	return true
}

func (s *Service) List() []Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	items := make([]Config, 0, len(s.items))
	for _, item := range s.items {
		items = append(items, item.Config)
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].Owner == items[j].Owner {
			return items[i].Name < items[j].Name
		}
		return items[i].Owner < items[j].Owner
	})

	return items
}

func (s *Service) ResolveRepositoryAccess(id string) (owner, name, registry, baseURL, defaultBranch, docsPathPolicy, rfcLabel, token string, ok bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	item, exists := s.items[id]
	if !exists {
		return "", "", "", "", "", "", "", "", false
	}

	return item.Owner, item.Name, item.Registry, item.BaseURL, item.DefaultBranch, item.DocsPathPolicy, item.RFCLabel, decryptToken(item.EncryptedToken), true
}

func (s *Service) Validate(ctx context.Context, id string) (ValidationResponse, error) {
	s.mu.RLock()
	item, ok := s.items[id]
	s.mu.RUnlock()
	if !ok {
		return ValidationResponse{}, fmt.Errorf("repository not found")
	}

	validation := s.client.ValidatePAT(ctx, item.Owner, item.Name, decryptToken(item.EncryptedToken))
	now := s.now().UTC().Format(time.RFC3339)

	checks := make([]ValidationCheckResponse, 0, len(validation.Checks))
	for _, c := range validation.Checks {
		checks = append(checks, ValidationCheckResponse{Name: c.Name, Status: c.Status, Message: c.Message})
	}

	updated := item
	updated.Validation = ValidationResponse{
		Healthy:       validation.Healthy,
		Checks:        checks,
		ValidatedAt:   now,
		LastErrorCode: validation.LastErrorCode,
	}
	if validation.Healthy {
		updated.Auth.TokenLastValidatedAt = &now
	}
	updated.UpdatedAt = now

	s.mu.Lock()
	s.items[id] = updated
	_ = s.saveLocked()
	s.mu.Unlock()

	return updated.Validation, nil
}

func (s *Service) RotateToken(ctx context.Context, id string, input rotateTokenInput) (Config, error) {
	token := strings.TrimSpace(input.Token)
	if token == "" {
		return Config{}, fmt.Errorf("personal_access_token is required")
	}

	s.mu.RLock()
	item, ok := s.items[id]
	s.mu.RUnlock()
	if !ok {
		return Config{}, fmt.Errorf("repository not found")
	}

	validation := s.client.ValidatePAT(ctx, item.Owner, item.Name, token)
	now := s.now().UTC().Format(time.RFC3339)
	checks := make([]ValidationCheckResponse, 0, len(validation.Checks))
	for _, c := range validation.Checks {
		checks = append(checks, ValidationCheckResponse{Name: c.Name, Status: c.Status, Message: c.Message})
	}

	updated := item
	updated.EncryptedToken = encryptToken(token)
	updated.Validation = ValidationResponse{
		Healthy:       validation.Healthy,
		Checks:        checks,
		ValidatedAt:   now,
		LastErrorCode: validation.LastErrorCode,
	}
	if validation.Healthy {
		updated.Auth.TokenLastValidatedAt = &now
	} else {
		updated.Auth.TokenLastValidatedAt = nil
	}
	updated.UpdatedAt = now

	s.mu.Lock()
	s.items[id] = updated
	_ = s.saveLocked()
	s.mu.Unlock()

	return updated.Config, nil
}

func (s *Service) newID() string {
	return fmt.Sprintf("repo_%d", s.idSeq.Add(1))
}

func (s *Service) loadFromDisk() error {
	data, err := os.ReadFile(s.storePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	s.loadedFromDisk = true
	var store persistedStore
	if err := json.Unmarshal(data, &store); err != nil {
		return err
	}
	var maxID int64 = 2000
	for _, item := range store.Items {
		if item.ID == "" {
			continue
		}
		s.items[item.ID] = item
		s.byName[repositoryKey(item.Registry, item.Owner, item.Name)] = item.ID
		if n, err := strconv.ParseInt(strings.TrimPrefix(item.ID, "repo_"), 10, 64); err == nil && n > maxID {
			maxID = n
		}
	}
	s.idSeq.Store(maxID)
	return nil
}

func (s *Service) saveLocked() error {
	if s.storePath == "" {
		return nil
	}
	items := make([]storedConfig, 0, len(s.items))
	for _, item := range s.items {
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	data, err := json.MarshalIndent(persistedStore{Items: items}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.storePath), 0o755); err != nil {
		return err
	}
	return os.WriteFile(s.storePath, data, 0o600)
}

func encryptToken(token string) string {
	return base64.StdEncoding.EncodeToString([]byte(token))
}

func decryptToken(token string) string {
	decoded, err := base64.StdEncoding.DecodeString(token)
	if err != nil {
		return ""
	}
	return string(decoded)
}
