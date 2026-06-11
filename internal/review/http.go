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

// RequestChanges submits a REQUEST_CHANGES review to GitHub.
// Body: { "body": "..." }
func (h *Handler) RequestChanges(w http.ResponseWriter, r *http.Request) {
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
	if payload.Body == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "body is required")
		return
	}

	reviewer := r.Header.Get("X-Hermit-User")
	result, err := h.service.RequestChanges(r.Context(), repositoryID, prNumber, payload.Body, reviewer)
	if err != nil {
		writeError(w, http.StatusBadGateway, "request_changes_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, result)
}

// ListReviews returns all reviews for a PR.
func (h *Handler) ListReviews(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	result, err := h.service.ListReviews(r.Context(), repositoryID, prNumber)
	if err != nil {
		writeError(w, http.StatusBadGateway, "list_reviews_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, result)
}

// DismissReview dismisses a single review by its numeric ID.
// Body: { "message": "..." }
func (h *Handler) DismissReview(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	reviewIDStr := r.PathValue("reviewId")
	reviewID, err := strconv.ParseInt(reviewIDStr, 10, 64)
	if err != nil || reviewID <= 0 {
		writeError(w, http.StatusBadRequest, "invalid_review_id", "reviewId path parameter must be a positive integer")
		return
	}

	var payload struct {
		Message string `json:"message"`
	}
	if r.Body != nil {
		defer r.Body.Close()
		_ = json.NewDecoder(r.Body).Decode(&payload)
	}
	if payload.Message == "" {
		payload.Message = "Review dismissed."
	}

	if err := h.service.DismissReview(r.Context(), repositoryID, prNumber, reviewID, payload.Message); err != nil {
		writeError(w, http.StatusBadGateway, "dismiss_review_failed", err.Error())
		return
	}

	w.WriteHeader(http.StatusNoContent)
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

func (h *Handler) GetMergeStatus(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}
	status, err := h.service.GetMergeStatus(r.Context(), repositoryID, prNumber)
	if err != nil {
		writeError(w, http.StatusBadGateway, "merge_status_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (h *Handler) UpdateBranch(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}
	if err := h.service.UpdateBranch(r.Context(), repositoryID, prNumber); err != nil {
		writeError(w, http.StatusBadGateway, "update_branch_failed", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func ReviewMergeStatusPath() string {
	return fmt.Sprintf("%s/merge-status", ReviewStatePath())
}

func ReviewUpdateBranchPath() string {
	return fmt.Sprintf("%s/update-branch", ReviewStatePath())
}

func ReviewStatePath() string {
	return "/api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/review"
}

func ReviewApprovePath() string {
	return fmt.Sprintf("%s/approve", ReviewStatePath())
}

func ReviewRequestChangesPath() string {
	return fmt.Sprintf("%s/request-changes", ReviewStatePath())
}

func ReviewListPath() string {
	return fmt.Sprintf("%s/list", ReviewStatePath())
}

func ReviewDismissPath() string {
	return fmt.Sprintf("%s/{reviewId}/dismiss", ReviewStatePath())
}

