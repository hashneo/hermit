package authstatus

import (
	"encoding/json"
	"net/http"

	"hermit/internal/repository"
	"hermit/internal/workset"
)

// Path is the route for a repository's auth/sync health.
func Path() string {
	return "/api/v1/repositories/{repositoryId}/auth-status"
}

type Handler struct {
	repos *repository.Service
	store *workset.Store
}

// NewHandler builds an auth-status handler that combines the repository's
// persisted validation metadata with the most recent sync outcome recorded in
// the workset cache.
func NewHandler(repos *repository.Service, store *workset.Store) *Handler {
	return &Handler{repos: repos, store: store}
}

// Response describes the current credential/auth health for a repository.
type Response struct {
	State            string `json:"state"`
	Method           string `json:"method,omitempty"`
	LastValidatedAt  string `json:"last_validated_at,omitempty"`
	LastSuccessfulAt string `json:"last_successful_refresh_at,omitempty"`
	LastAttemptedAt  string `json:"last_attempted_refresh_at,omitempty"`
	LastErrorCode    string `json:"last_error_code,omitempty"`
	LastErrorMessage string `json:"last_error_message,omitempty"`
	Remediation      string `json:"remediation,omitempty"`
}

// Auth status states. The dashboard maps these to badges and remediation CTAs.
const (
	StateHealthy            = "healthy"
	StateAuthenticationReqd = "authentication_required"
	StateAccessDenied       = "access_denied"
	StateRefreshFailed      = "refresh_failed"
	StateUnknown            = "unknown"
)

// GetAuthStatus returns the current auth/sync health for one repository.
func (h *Handler) GetAuthStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("repositoryId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}

	cfg, ok := h.repos.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "repository_not_found", "repository configuration was not found")
		return
	}

	resp := Response{
		Method: cfg.Auth.Method,
	}
	if cfg.Auth.TokenLastValidatedAt != nil {
		resp.LastValidatedAt = *cfg.Auth.TokenLastValidatedAt
	}

	if h.store != nil {
		if cache, cacheOk, err := h.store.GetRepositoryRFCListCache(r.Context(), id); err == nil && cacheOk {
			resp.LastSuccessfulAt = cache.LastSuccessfulRefreshAt
			resp.LastAttemptedAt = cache.LastAttemptedRefreshAt
			resp.LastErrorCode = cache.LastErrorCode
			resp.LastErrorMessage = cache.LastErrorMessage
		}
	}

	resp.State = deriveState(resp)
	resp.Remediation = remediationFor(resp.State)

	writeJSON(w, http.StatusOK, resp)
}

// deriveState maps the stored cache + validation fields to a dashboard state.
// The workset cache is authoritative when present because it reflects the most
// recent live provider refresh. Validation timestamps are informational;
// repositories that have never been refreshed remain unknown.
func deriveState(resp Response) string {
	switch resp.LastErrorCode {
	case "auth_failed":
		return StateAuthenticationReqd
	case "access_denied":
		return StateAccessDenied
	case "provider_error":
		return StateRefreshFailed
	case "":
		if resp.LastSuccessfulAt != "" {
			return StateHealthy
		}
		return StateUnknown
	default:
		return StateRefreshFailed
	}
}

// remediationFor returns a short, UI-ready hint describing how to recover.
func remediationFor(state string) string {
	switch state {
	case StateAuthenticationReqd:
		return "Token is missing, expired, or revoked. Rotate the token or re-import it from the Git Credential Helper."
	case StateAccessDenied:
		return "Token lacks access to this repository, or SAML SSO authorization is required."
	case StateRefreshFailed:
		return "Repository refresh failed for a non-auth reason. Retry, or check network and rate limits."
	default:
		return ""
	}
}

func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, code int, errCode, message string) {
	writeJSON(w, code, map[string]any{
		"code":           errCode,
		"message":        message,
		"details":        map[string]string{},
		"correlation_id": "corr-hermit-v1",
	})
}
