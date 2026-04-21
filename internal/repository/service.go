package repository

import (
	"context"
	"encoding/base64"
	"fmt"
	"hermit/internal/config"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const githubTokenEnvVar = "GITHUB_TOKEN"

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
	DefaultBranch  string             `json:"default_branch"`
	DocsPathPolicy string             `json:"docs_path_policy"`
	Auth           AuthMetadata       `json:"auth"`
	Validation     ValidationResponse `json:"validation"`
	CreatedAt      string             `json:"created_at"`
	UpdatedAt      string             `json:"updated_at"`
}

type createInput struct {
	Owner          string
	Name           string
	Registry       string
	Token          string
	DefaultBranch  string
	DocsPathPolicy string
}

type storedConfig struct {
	Config
	EncryptedToken string
}

type Service struct {
	mu     sync.RWMutex
	items  map[string]storedConfig
	byName map[string]string
	client GitHubClient
	now    func() time.Time
	idSeq  atomic.Int64
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

func (s *Service) SeedFromConfig(repositories []config.Repository) {
	for _, repository := range repositories {
		token := strings.TrimSpace(os.Getenv(repository.TokenEnvVar))
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
		validation := ValidationResponse{
			Healthy: false,
			Checks: []ValidationCheckResponse{{
				Name:    "token_env",
				Status:  "warn",
				Message: fmt.Sprintf("token env var %q is not set", repository.TokenEnvVar),
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
			DefaultBranch:  repository.DefaultBranch,
			DocsPathPolicy: repository.DocsPathPolicy,
			Auth: AuthMetadata{
				Method:               "pat",
				TokenLastValidatedAt: validatedAt,
			},
			Validation: validation,
			CreatedAt:  now,
			UpdatedAt:  now,
		}
		if cfg.DefaultBranch == "" {
			cfg.DefaultBranch = "main"
		}
		if cfg.DocsPathPolicy == "" {
			cfg.DocsPathPolicy = "docs-cms/rfcs/"
		}
		s.items[cfg.ID] = storedConfig{Config: cfg, EncryptedToken: encryptToken(token)}
		s.byName[key] = cfg.ID
		s.mu.Unlock()
	}
}

func (s *Service) Create(ctx context.Context, input createInput) (Config, error) {
	token := strings.TrimSpace(input.Token)
	if token == "" {
		token = strings.TrimSpace(os.Getenv(githubTokenEnvVar))
	}

	if input.Owner == "" || input.Name == "" || token == "" {
		return Config{}, fmt.Errorf("owner, name, and personal_access_token are required (or set GITHUB_TOKEN)")
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
		DefaultBranch:  input.DefaultBranch,
		DocsPathPolicy: input.DocsPathPolicy,
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

func (s *Service) ResolveRepositoryAccess(id string) (owner, name, registry, defaultBranch, docsPathPolicy, token string, ok bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	item, exists := s.items[id]
	if !exists {
		return "", "", "", "", "", "", false
	}

	return item.Owner, item.Name, item.Registry, item.DefaultBranch, item.DocsPathPolicy, decryptToken(item.EncryptedToken), true
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
	s.mu.Unlock()

	return updated.Validation, nil
}

func (s *Service) newID() string {
	return fmt.Sprintf("repo_%d", s.idSeq.Add(1))
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
