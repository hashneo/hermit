package thread

import (
	"encoding/json"
	"fmt"
	"io"
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

func (h *Handler) ListThreads(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	threads := h.service.List(repositoryID, prNumber)
	writeJSON(w, http.StatusOK, map[string]any{
		"items": threads,
		"total": len(threads),
	})
}

func (h *Handler) CreateThread(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return
	}

	var payload struct {
		Anchor struct {
			LineStart       int    `json:"line_start"`
			LineEnd         int    `json:"line_end"`
			FormattedLineStart int `json:"formatted_line_start"`
			FormattedLineEnd   int `json:"formatted_line_end"`
			TextFingerprint string `json:"text_fingerprint"`
			FilePath        string `json:"file_path"`
		} `json:"anchor"`
		Body string `json:"body"`
	}

	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "request body must be valid JSON")
		return
	}

	if payload.Body == "" || payload.Anchor.LineStart <= 0 || payload.Anchor.LineEnd <= 0 || payload.Anchor.TextFingerprint == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "body and anchor fields are required")
		return
	}

	thread, err := h.service.Create(r.Context(), CreateRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		Anchor: Anchor{
			LineStart:       payload.Anchor.LineStart,
			LineEnd:         payload.Anchor.LineEnd,
			FormattedLineStart: payload.Anchor.FormattedLineStart,
			FormattedLineEnd:   payload.Anchor.FormattedLineEnd,
			TextFingerprint: payload.Anchor.TextFingerprint,
			FilePath:        payload.Anchor.FilePath,
		},
		Body:   payload.Body,
		Author: r.Header.Get("X-Hermit-User"),
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, "github_sync_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, thread)
}

func (h *Handler) ReplyThread(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, threadID, ok := parseThreadPathParams(w, r)
	if !ok {
		return
	}

	var payload struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "request body must be valid JSON")
		return
	}
	if payload.Body == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "body is required")
		return
	}

	thread, err := h.service.Reply(r.Context(), ReplyRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		ThreadID:     threadID,
		Body:         payload.Body,
		Author:       r.Header.Get("X-Hermit-User"),
	})
	if err != nil {
		if err.Error() == "thread not found" {
			writeError(w, http.StatusNotFound, "thread_not_found", err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, "github_sync_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, thread)
}

func (h *Handler) DeleteThread(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, threadID, ok := parseThreadPathParams(w, r)
	if !ok {
		return
	}

	if err := h.service.Delete(r.Context(), DeleteRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		ThreadID:     threadID,
		Actor:        r.Header.Get("X-Hermit-User"),
	}); err != nil {
		h.writeDeleteError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// DeleteMessage deletes a specific message from a thread.
// The message must be the last one in the thread, and must have been authored
// by the user identified in the X-Hermit-User request header.
//
// Route: DELETE /repositories/{repositoryId}/pull-requests/{prNumber}/threads/{threadId}/messages/{messageId}
func (h *Handler) DeleteMessage(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, threadID, ok := parseThreadPathParams(w, r)
	if !ok {
		return
	}

	messageID := r.PathValue("messageId")
	if messageID == "" {
		writeError(w, http.StatusBadRequest, "invalid_message_id", "messageId path parameter is required")
		return
	}

	if err := h.service.Delete(r.Context(), DeleteRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		ThreadID:     threadID,
		MessageID:    messageID,
		Actor:        r.Header.Get("X-Hermit-User"),
	}); err != nil {
		h.writeDeleteError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) writeDeleteError(w http.ResponseWriter, err error) {
	msg := err.Error()
	switch {
	case msg == "thread not found" || msg == "message not found in thread":
		writeError(w, http.StatusNotFound, "not_found", msg)
	case msg == "only the last message in a thread can be deleted":
		writeError(w, http.StatusConflict, "not_last_message", msg)
	case strings.HasPrefix(msg, "cannot delete a message authored"):
		writeError(w, http.StatusForbidden, "forbidden", msg)
	default:
		writeError(w, http.StatusBadGateway, "github_sync_failed", msg)
	}
}

func (h *Handler) ResolveThread(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, threadID, ok := parseThreadPathParams(w, r)
	if !ok {
		return
	}

	thread, err := h.service.Resolve(r.Context(), ResolveRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		ThreadID:     threadID,
	})
	if err != nil {
		if err.Error() == "thread not found" {
			writeError(w, http.StatusNotFound, "thread_not_found", err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, "github_sync_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, thread)
}

func (h *Handler) UnresolveThread(w http.ResponseWriter, r *http.Request) {
	repositoryID, prNumber, threadID, ok := parseThreadPathParams(w, r)
	if !ok {
		return
	}

	thread, err := h.service.Unresolve(r.Context(), ResolveRequest{
		RepositoryID: repositoryID,
		PRNumber:     prNumber,
		ThreadID:     threadID,
	})
	if err != nil {
		if err.Error() == "thread not found" {
			writeError(w, http.StatusNotFound, "thread_not_found", err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, "github_sync_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, thread)
}

func ThreadUnresolvePath() string {
	return fmt.Sprintf("%s/{threadId}/unresolve", ThreadsPath())
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

func parseThreadPathParams(w http.ResponseWriter, r *http.Request) (string, int, string, bool) {
	repositoryID, prNumber, ok := parsePRPathParams(w, r)
	if !ok {
		return "", 0, "", false
	}

	threadID := r.PathValue("threadId")
	if threadID == "" {
		writeError(w, http.StatusBadRequest, "invalid_thread_id", "threadId path parameter is required")
		return "", 0, "", false
	}

	return repositoryID, prNumber, threadID, true
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

func ThreadsPath() string {
	return "/api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/threads"
}

func ThreadReplyPath() string {
	return fmt.Sprintf("%s/{threadId}/reply", ThreadsPath())
}

func ThreadResolvePath() string {
	return fmt.Sprintf("%s/{threadId}/resolve", ThreadsPath())
}

func ThreadDeletePath() string {
	return fmt.Sprintf("%s/{threadId}", ThreadsPath())
}

func ThreadMessageDeletePath() string {
	return fmt.Sprintf("%s/{threadId}/messages/{messageId}", ThreadsPath())
}

func decodeOptionalJSONBody(r *http.Request, payload any) error {
	if r.Body == nil {
		return nil
	}
	defer r.Body.Close()
	err := json.NewDecoder(r.Body).Decode(payload)
	if err == io.EOF {
		return nil
	}
	return err
}
