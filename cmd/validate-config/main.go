package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	"hermit/internal/config"
)

func main() {
	checkAccess := flag.Bool("check-access", false, "validate configured repository access against GitHub APIs")
	flag.Parse()

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config validation failed: %v", err)
	}

	if *checkAccess {
		if err := validateRepositoryAccess(cfg); err != nil {
			log.Fatalf("config access validation failed: %v", err)
		}
	}

	fmt.Printf("config valid: environment=%s listen_address=%s registries=%d repositories=%d\n", cfg.Environment, cfg.ListenAddress, len(cfg.Registries), len(cfg.Repositories))
}

func validateRepositoryAccess(cfg config.Config) error {
	if len(cfg.Repositories) == 0 {
		fmt.Println("no repositories configured; skipping access checks")
		return nil
	}

	registryByName := make(map[string]config.Registry, len(cfg.Registries))
	for _, registry := range cfg.Registries {
		registryByName[registry.Name] = registry
	}

	client := &http.Client{}

	for _, repository := range cfg.Repositories {
		registry, ok := registryByName[repository.Registry]
		if !ok {
			return fmt.Errorf("repository %s/%s references unknown registry %q", repository.Owner, repository.Name, repository.Registry)
		}

		tokenEnvVar := repository.TokenEnvVar
		if strings.TrimSpace(tokenEnvVar) == "" {
			tokenEnvVar = registry.TokenEnvVar
		}
		token := strings.TrimSpace(os.Getenv(tokenEnvVar))
		if token == "" {
			return fmt.Errorf("repository %s/%s missing token in env var %q", repository.Owner, repository.Name, tokenEnvVar)
		}

		apiBase := strings.TrimRight(registry.BaseURL, "/")
		url := fmt.Sprintf("%s/repos/%s/%s", apiBase, repository.Owner, repository.Name)

		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			return fmt.Errorf("build request for %s/%s: %w", repository.Owner, repository.Name, err)
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("access check failed for %s/%s: %w", repository.Owner, repository.Name, err)
		}

		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
			_ = resp.Body.Close()
			return fmt.Errorf("access denied for %s/%s via registry %q: status=%d body=%s", repository.Owner, repository.Name, repository.Registry, resp.StatusCode, strings.TrimSpace(string(body)))
		}
		_ = resp.Body.Close()

		fmt.Printf("access ok: %s/%s via registry=%s\n", repository.Owner, repository.Name, repository.Registry)
	}

	return nil
}
