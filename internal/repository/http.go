package repository

import (
	"encoding/json"
	"io"
	"net/http"
)

type Handler struct {
	service *Service
}

func NewHandler(service *Service) *Handler {
	return &Handler{service: service}
}

func (h *Handler) CreateRepository(w http.ResponseWriter, r *http.Request) {
	var payload struct {
		Owner               string `json:"owner"`
		Name                string `json:"name"`
		Registry            string `json:"registry"`
		BaseURL             string `json:"base_url"`
		PersonalAccessToken string `json:"personal_access_token"`
		DefaultBranch       string `json:"default_branch"`
		DocsPathPolicy      string `json:"docs_path_policy"`
		RFCLabel            string `json:"rfc_label"`
	}

	if err := decodeJSON(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "request body must be valid JSON")
		return
	}

	cfg, err := h.service.Create(r.Context(), createInput{
		Owner:          payload.Owner,
		Name:           payload.Name,
		Registry:       payload.Registry,
		BaseURL:        payload.BaseURL,
		Token:          payload.PersonalAccessToken,
		DefaultBranch:  payload.DefaultBranch,
		DocsPathPolicy: payload.DocsPathPolicy,
		RFCLabel:       payload.RFCLabel,
	})
	if err != nil {
		if err.Error() == "repository is already configured" {
			writeError(w, http.StatusConflict, "repository_exists", err.Error())
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, cfg)
}

func (h *Handler) GetRepository(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("repositoryId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}

	cfg, ok := h.service.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "repository_not_found", "repository configuration was not found")
		return
	}

	writeJSON(w, http.StatusOK, cfg)
}

func (h *Handler) ListRepositories(w http.ResponseWriter, _ *http.Request) {
	items := h.service.List()
	writeJSON(w, http.StatusOK, map[string]any{
		"items": items,
		"total": len(items),
	})
}

func (h *Handler) DeleteRepository(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("repositoryId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}
	if !h.service.Delete(id) {
		writeError(w, http.StatusNotFound, "repository_not_found", "repository configuration was not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) ValidateRepository(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("repositoryId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}

	validation, err := h.service.Validate(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusNotFound, "repository_not_found", "repository configuration was not found")
		return
	}

	writeJSON(w, http.StatusOK, validation)
}

func (h *Handler) RotateRepositoryToken(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("repositoryId")
	if id == "" {
		writeError(w, http.StatusBadRequest, "invalid_repository_id", "repositoryId path parameter is required")
		return
	}

	var payload struct {
		PersonalAccessToken string `json:"personal_access_token"`
	}
	if err := decodeJSON(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "request body must be valid JSON")
		return
	}

	cfg, err := h.service.RotateToken(r.Context(), id, rotateTokenInput{Token: payload.PersonalAccessToken})
	if err != nil {
		if err.Error() == "repository not found" {
			writeError(w, http.StatusNotFound, "repository_not_found", "repository configuration was not found")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, cfg)
}

func decodeJSON(r *http.Request, payload any) error {
	if r.Body == nil {
		return io.EOF
	}
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(payload); err != nil {
		return err
	}
	return nil
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
