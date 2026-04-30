package rfc

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

type Handler struct {
	service *Service
}

func NewHandler(service *Service) *Handler {
	return &Handler{service: service}
}

func (h *Handler) GetDocument(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	doc := h.service.GetDocument(repositoryID, prNumber)
	writeJSON(w, http.StatusOK, doc)
}

func (h *Handler) Render(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	view, err := h.service.RenderPRRFC(r.Context(), repositoryID, prNumber)
	if err != nil {
		writeError(w, http.StatusNotFound, "rfc_not_found", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, view)
}

func (h *Handler) ListRFCs(w http.ResponseWriter, _ *http.Request) {
	items, err := h.service.ListRFCs()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "rfc_catalog_unavailable", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) ListRepositoryRFCs(w http.ResponseWriter, r *http.Request) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}

	items, err := h.service.ListRFCsByRepository(r.Context(), repositoryID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "rfc_catalog_unavailable", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) RenderRepositoryRFCByID(w http.ResponseWriter, r *http.Request) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}

	id := r.PathValue("rfcId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_rfc_id", "rfcId path parameter is required")
		return
	}

	view, err := h.service.RenderRFCByRepository(r.Context(), repositoryID, id)
	if err != nil {
		writeError(w, http.StatusNotFound, "rfc_not_found", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, view)
}

func (h *Handler) RenderRFCByID(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("rfcId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_rfc_id", "rfcId path parameter is required")
		return
	}

	view, err := h.service.RenderRFC(id)
	if err != nil {
		writeError(w, http.StatusNotFound, "rfc_not_found", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, view)
}

func (h *Handler) SubmitForReview(w http.ResponseWriter, r *http.Request) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}
	rfcID := r.PathValue("rfcId")
	if rfcID == "" {
		writeError(w, http.StatusBadRequest, "invalid_rfc_id", "rfcId path parameter is required")
		return
	}

	result, err := h.service.SubmitForReview(r.Context(), repositoryID, rfcID)
	if err != nil {
		if strings.Contains(err.Error(), "cannot submit for review") {
			writeError(w, http.StatusConflict, "invalid_status_transition", err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, "submit_for_review_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, result)
}

// AcceptRFC rewrites the RFC status to "accepted" on the PR branch and
// attempts an immediate squash-merge.  The request body must contain:
//
//	{ "file_path": "docs-cms/rfcs/rfc-001-...md" }
//
// Response: AcceptRFCResult — includes merged, blocked_by_ci, commit_sha.
func (h *Handler) AcceptRFC(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	var body struct {
		FilePath string `json:"file_path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.FilePath == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "file_path is required in request body")
		return
	}

	result, err := h.service.AcceptRFC(r.Context(), repositoryID, prNumber, body.FilePath)
	if err != nil {
		writeError(w, http.StatusBadGateway, "accept_rfc_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, result)
}

// GetCIStatus returns the aggregate CI check status for a commit SHA.
// Query param: ?sha=<commitSHA>
func (h *Handler) GetCIStatus(w http.ResponseWriter, r *http.Request) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}
	sha := r.URL.Query().Get("sha")
	if sha == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "sha query parameter is required")
		return
	}

	result, err := h.service.GetCIStatus(r.Context(), repositoryID, sha)
	if err != nil {
		writeError(w, http.StatusBadGateway, "ci_status_unavailable", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) ApproveRFC(w http.ResponseWriter, r *http.Request) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}
	rfcID := r.PathValue("rfcId")
	if rfcID == "" {
		writeError(w, http.StatusBadRequest, "invalid_rfc_id", "rfcId path parameter is required")
		return
	}

	result, err := h.service.ApproveRFC(r.Context(), repositoryID, rfcID)
	if err != nil {
		switch {
		case strings.HasPrefix(err.Error(), "forbidden:"):
			writeError(w, http.StatusForbidden, "forbidden", err.Error())
		case strings.Contains(err.Error(), "cannot approve"):
			writeError(w, http.StatusConflict, "invalid_status_transition", err.Error())
		default:
			writeError(w, http.StatusBadGateway, "approve_rfc_failed", err.Error())
		}
		return
	}

	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) MarkImplemented(w http.ResponseWriter, r *http.Request) {
	repositoryID := r.PathValue("repositoryId")
	if repositoryID == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}
	rfcID := r.PathValue("rfcId")
	if rfcID == "" {
		writeError(w, http.StatusBadRequest, "invalid_rfc_id", "rfcId path parameter is required")
		return
	}

	result, err := h.service.MarkImplemented(r.Context(), repositoryID, rfcID)
	if err != nil {
		switch {
		case strings.HasPrefix(err.Error(), "forbidden:"):
			writeError(w, http.StatusForbidden, "forbidden", err.Error())
		case strings.Contains(err.Error(), "cannot mark implemented"):
			writeError(w, http.StatusConflict, "invalid_status_transition", err.Error())
		default:
			writeError(w, http.StatusBadGateway, "mark_implemented_failed", err.Error())
		}
		return
	}

	writeJSON(w, http.StatusOK, result)
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
	writeJSON(w, code, map[string]any{
		"code":           errCode,
		"message":        message,
		"details":        map[string]string{},
		"correlation_id": "corr-hermit-v1",
	})
}
