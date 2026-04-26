package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

const (
	defaultEnvironment   = "development"
	defaultListenAddress = ":8080"
	defaultConfigPath    = "config/hermit.yaml"
	defaultDataDir       = "data"
)

// Registry stores external provider configuration for repository integrations.
type Registry struct {
	Name    string `yaml:"name"`
	Kind    string `yaml:"kind"`
	BaseURL string `yaml:"base_url"`
}

// Repository stores repository bootstrap configuration.
type Repository struct {
	Owner          string `yaml:"owner"`
	Name           string `yaml:"name"`
	Registry       string `yaml:"registry"`
	DefaultBranch  string `yaml:"default_branch"`
	DocsPathPolicy string `yaml:"docs_path_policy"`
	// Token is an in-memory PAT used when building config programmatically
	// (e.g. the embedded mobile server). It is never read from or written to YAML.
	Token string `yaml:"-"`
}

// Config stores application runtime configuration.
type Config struct {
	Environment   string       `yaml:"environment"`
	ListenAddress string       `yaml:"listen_address"`
	Registries    []Registry   `yaml:"registries"`
	Repositories  []Repository `yaml:"repositories"`
	// DataDir is the base directory for mutable runtime data (thread store, etc.).
	// Defaults to "data" relative to the working directory.
	// When the server is embedded in a macOS app via gomobile, this is set to
	// the app sandbox Application Support directory.
	DataDir       string       `yaml:"data_dir"`
}

// Load builds config from a JSON config file.
func Load() (Config, error) {
	configPath := os.Getenv("HERMIT_CONFIG_FILE")
	if configPath == "" {
		configPath = defaultConfigPath
	}

	cfg, err := loadFromFile(configPath)
	if err != nil {
		return Config{}, fmt.Errorf("load config file %q: %w", configPath, err)
	}

	if cfg.ListenAddress == "" {
		return Config{}, fmt.Errorf("HERMIT_LISTEN_ADDR cannot be empty")
	}
	if cfg.Environment == "" {
		cfg.Environment = defaultEnvironment
	}
	if len(cfg.Registries) == 0 {
		return Config{}, fmt.Errorf("at least one registry is required")
	}

	for _, registry := range cfg.Registries {
		if registry.Name == "" {
			return Config{}, fmt.Errorf("registry name is required")
		}
		if registry.Kind == "" {
			return Config{}, fmt.Errorf("registry kind is required")
		}
		if registry.BaseURL == "" {
			return Config{}, fmt.Errorf("registry base_url is required")
		}
	}

	registryNames := make(map[string]struct{}, len(cfg.Registries))
	for _, registry := range cfg.Registries {
		registryNames[registry.Name] = struct{}{}
	}

	for i := range cfg.Repositories {
		repository := &cfg.Repositories[i]
		if repository.Owner == "" {
			return Config{}, fmt.Errorf("repository owner is required")
		}
		if repository.Name == "" {
			return Config{}, fmt.Errorf("repository name is required")
		}
		if repository.Registry == "" {
			repository.Registry = "github"
		}
		if _, ok := registryNames[repository.Registry]; !ok {
			return Config{}, fmt.Errorf("repository registry %q is not defined", repository.Registry)
		}
		if repository.DefaultBranch == "" {
			repository.DefaultBranch = "main"
		}
		if repository.DocsPathPolicy == "" {
			repository.DocsPathPolicy = "docs-cms/rfcs/"
		}
	}

	if cfg.DataDir == "" {
		cfg.DataDir = defaultDataDir
	}

	return cfg, nil
}

func loadFromFile(path string) (Config, error) {
	bytes, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Config{}, fmt.Errorf("file not found; copy config/hermit.example.yaml to %s", path)
		}
		return Config{}, err
	}

	cfg := Config{}
	if err := yaml.Unmarshal(bytes, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse yaml: %w", err)
	}

	if cfg.ListenAddress == "" {
		cfg.ListenAddress = defaultListenAddress
	}

	return cfg, nil
}
