package rfc

import (
	"encoding/json"
	"net/http"
	"strconv"
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

	render, err := h.service.Render(repositoryID, prNumber)
	if err != nil {
		writeError(w, http.StatusBadRequest, "rfc_ineligible", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, render)
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
