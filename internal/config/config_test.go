package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadFromConfigFileWithMultipleRegistries(t *testing.T) {
	tempDir := t.TempDir()
	configPath := filepath.Join(tempDir, "hermit.yaml")
	configYAML := `environment: development
listen_address: ":8080"
registries:
  - name: github-public
    kind: github
    base_url: https://api.github.com
    token_env_var: GITHUB_TOKEN
  - name: github-enterprise
    kind: github
    base_url: https://github.example.com/api/v3
    token_env_var: GHE_TOKEN
repositories:
  - owner: hashicorp
    name: hermit
    registry: github-public
`

	if err := os.WriteFile(configPath, []byte(configYAML), 0o600); err != nil {
		t.Fatalf("write config file: %v", err)
	}

	t.Setenv("HERMIT_CONFIG_FILE", configPath)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if got, want := len(cfg.Registries), 2; got != want {
		t.Fatalf("registries len = %d, want %d", got, want)
	}

	if cfg.Registries[1].TokenEnvVar != "GHE_TOKEN" {
		t.Fatalf("second registry token env = %q, want GHE_TOKEN", cfg.Registries[1].TokenEnvVar)
	}

	if got, want := len(cfg.Repositories), 1; got != want {
		t.Fatalf("repositories len = %d, want %d", got, want)
	}
	if cfg.Repositories[0].TokenEnvVar != "GITHUB_TOKEN" {
		t.Fatalf("repository token env = %q, want GITHUB_TOKEN", cfg.Repositories[0].TokenEnvVar)
	}
}

func TestLoadRejectsMissingRegistryFields(t *testing.T) {
	tempDir := t.TempDir()
	configPath := filepath.Join(tempDir, "hermit.yaml")
	configYAML := `listen_address: ":8080"
registries:
  - name: broken
`

	if err := os.WriteFile(configPath, []byte(configYAML), 0o600); err != nil {
		t.Fatalf("write config file: %v", err)
	}

	t.Setenv("HERMIT_CONFIG_FILE", configPath)

	_, err := Load()
	if err == nil {
		t.Fatalf("expected validation error")
	}
}

func TestLoadRejectsRepositoryWithUnknownRegistry(t *testing.T) {
	tempDir := t.TempDir()
	configPath := filepath.Join(tempDir, "hermit.yaml")
	configYAML := `listen_address: ":8080"
registries:
  - name: github
    kind: github
    base_url: https://api.github.com
    token_env_var: GITHUB_TOKEN
repositories:
  - owner: hashicorp
    name: hermit
    registry: missing-registry
    token_env_var: GITHUB_TOKEN
`

	if err := os.WriteFile(configPath, []byte(configYAML), 0o600); err != nil {
		t.Fatalf("write config file: %v", err)
	}

	t.Setenv("HERMIT_CONFIG_FILE", configPath)

	_, err := Load()
	if err == nil {
		t.Fatalf("expected unknown registry validation error")
	}
}

func TestLoadRejectsMissingConfigFile(t *testing.T) {
	t.Setenv("HERMIT_CONFIG_FILE", filepath.Join(t.TempDir(), "missing.yaml"))

	_, err := Load()
	if err == nil {
		t.Fatalf("expected missing file error")
	}
}
