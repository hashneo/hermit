package repository

import (
	"context"
	"strings"
)

type ValidationCheck struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type ValidationResult struct {
	Healthy       bool              `json:"healthy"`
	Checks        []ValidationCheck `json:"checks"`
	ValidatedAt   string            `json:"validated_at"`
	LastErrorCode string            `json:"last_error_code,omitempty"`
}

type GitHubClient interface {
	ValidatePAT(ctx context.Context, owner, name, token string) ValidationResult
}

type InMemoryGitHubClient struct{}

func NewInMemoryGitHubClient() *InMemoryGitHubClient {
	return &InMemoryGitHubClient{}
}

func (c *InMemoryGitHubClient) ValidatePAT(_ context.Context, owner, name, token string) ValidationResult {
	if strings.TrimSpace(owner) == "" || strings.TrimSpace(name) == "" {
		return ValidationResult{
			Healthy: false,
			Checks: []ValidationCheck{
				{Name: "github_api_access", Status: "fail", Message: "owner and name are required"},
			},
			LastErrorCode: "repository_identity_invalid",
		}
	}

	// Accept any non-empty token: GitHub PATs (ghp_…), Gitea hex tokens,
	// and other registry formats are all valid as far as the stub is concerned.
	// Real token scope validation happens at the registry API level.
	isValid := strings.TrimSpace(token) != "" && len(token) >= 10
	if !isValid {
		return ValidationResult{
			Healthy: false,
			Checks: []ValidationCheck{
				{Name: "github_api_access", Status: "fail", Message: "PAT authentication failed"},
				{Name: "required_scopes", Status: "fail", Message: "missing required scopes for Hermit operations"},
			},
			LastErrorCode: "pat_invalid",
		}
	}

	return ValidationResult{
		Healthy: true,
		Checks: []ValidationCheck{
			{Name: "github_api_access", Status: "pass", Message: "GitHub access validated"},
			{Name: "required_scopes", Status: "pass", Message: "required scopes are present"},
		},
	}
}
