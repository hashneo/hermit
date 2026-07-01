package syncstatus

import (
	"net/http"
	"time"

	"hermit/internal/observability"
)

type Handler struct{}

func NewHandler() *Handler {
	return &Handler{}
}

func Path() string {
	return "/api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/sync"
}

func (h *Handler) GetSyncStatus(w http.ResponseWriter, r *http.Request) {
	_ = h
	observability.WriteJSON(w, http.StatusOK, map[string]any{
		"state":          "synced",
		"last_synced_at": time.Now().UTC().Format(time.RFC3339),
		"retry_count":    0,
	})
}
