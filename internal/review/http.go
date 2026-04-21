package review

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
)

type Handler struct {
	service *Service
}

func NewHandler(service *Service) *Handler {
	return &Handler{service: service}
}

func (h *Handler) GetReviewState(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	state := h.service.Get(repositoryID, prNumber)
	writeJSON(w, http.StatusOK, state)
}

func (h *Handler) Approve(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	var payload struct {
		Body string `json:"body"`
	}

	if r.Body != nil {
		defer r.Body.Close()
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil && err != io.EOF {
			writeError(w, http.StatusBadRequest, "invalid_request", "request body must be valid JSON")
			return
		}
	}

	status, err := h.service.Approve(r.Context(), ApprovalRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		Body:         payload.Body,
		Reviewer:     r.Header.Get("X-Hermit-User"),
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, "github_approval_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, status)
}

func parsePRPathParams(w http.ResponseWriter, r *http.Request) (string, int, bool) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return "", 0, false
	}

	prNumber, err := strconv.Atoi(r.PathValue("prNumber"))
	if err != nil || prNumber <= 0 {
		writeError(w, http.StatusBadRequest, "invalid_pr_number", "prNumber path parameter must be a positive integer")
		return "", 0, false
	}

	return repositoryID, prNumber, true
}

func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, code int, errCode, message string) {
	correlationID := "corr-hermit-v1"
	writeJSON(w, code, map[string]any{
		"code":           errCode,
		"message":        message,
		"details":        map[string]string{},
		"correlation_id": correlationID,
	})
}

func ReviewStatePath() string {
	return "/api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/review"
}

func ReviewApprovePath() string {
	return fmt.Sprintf("%s/approve", ReviewStatePath())
}
