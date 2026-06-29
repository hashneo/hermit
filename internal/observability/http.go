package observability

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const CorrelationHeader = "X-Correlation-Id"

type contextKey string

const correlationContextKey contextKey = "correlation-id"

func Middleware(next http.Handler) http.Handler {
	return MiddlewareWithAccessLog(next, nil)
}

func MiddlewareWithAccessLog(next http.Handler, store *AccessLogStore) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		correlationID := r.Header.Get(CorrelationHeader)
		if correlationID == "" {
			correlationID = newCorrelationID()
		}

		ctx := context.WithValue(r.Context(), correlationContextKey, correlationID)
		r = r.WithContext(ctx)

		w.Header().Set(CorrelationHeader, correlationID)

		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		duration := time.Since(start)

		slog.Info("http request completed",
			"method", r.Method,
			"path", r.URL.Path,
			"status", recorder.status,
			"duration_ms", duration.Milliseconds(),
			"correlation_id", correlationID,
		)

		if store != nil {
			entry := LogEntry{
				StartedAt:     start.UTC().Format(time.RFC3339Nano),
				CompletedAt:   time.Now().UTC().Format(time.RFC3339Nano),
				Kind:          "access",
				Method:        r.Method,
				Path:          r.URL.Path,
				Query:         r.URL.RawQuery,
				Status:        recorder.status,
				DurationMS:    duration.Milliseconds(),
				CorrelationID: correlationID,
				RemoteAddr:    r.RemoteAddr,
				UserAgent:     r.UserAgent(),
				BytesWritten:  recorder.bytesWritten,
			}
			if recorder.status >= http.StatusBadRequest {
				entry.Kind = "error"
				entry.ErrorCode, entry.ErrorMessage = parseErrorBody(recorder.body.String())
			}
			if err := store.Insert(r.Context(), entry); err != nil {
				slog.Warn("record http access log failed", "error", err)
			}
		}
	})
}

func CorrelationIDFromContext(ctx context.Context) string {
	if value, ok := ctx.Value(correlationContextKey).(string); ok && value != "" {
		return value
	}
	return "corr-unknown"
}

type statusRecorder struct {
	http.ResponseWriter
	status       int
	bytesWritten int
	body         bytes.Buffer
}

func (r *statusRecorder) WriteHeader(statusCode int) {
	r.status = statusCode
	r.ResponseWriter.WriteHeader(statusCode)
}

func (r *statusRecorder) Write(data []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	if r.body.Len() < maxCapturedErrorBody {
		remaining := maxCapturedErrorBody - r.body.Len()
		if len(data) < remaining {
			remaining = len(data)
		}
		_, _ = r.body.Write(data[:remaining])
	}
	n, err := r.ResponseWriter.Write(data)
	r.bytesWritten += n
	return n, err
}

func newCorrelationID() string {
	return fmt.Sprintf("corr-%d-%d", time.Now().UnixNano(), rand.Intn(100000))
}

func WriteJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}

func WriteError(w http.ResponseWriter, r *http.Request, code int, errCode, message string) {
	WriteJSON(w, code, map[string]any{
		"code":           errCode,
		"message":        message,
		"details":        map[string]string{},
		"correlation_id": CorrelationIDFromContext(r.Context()),
	})
}

const maxCapturedErrorBody = 2048

type LogHandler struct {
	store *AccessLogStore
}

func NewLogHandler(store *AccessLogStore) *LogHandler {
	return &LogHandler{store: store}
}

func (h *LogHandler) List(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.store == nil {
		WriteError(w, r, http.StatusServiceUnavailable, "access_log_unavailable", "access log is not configured")
		return
	}
	limit := 50
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 500 {
			WriteError(w, r, http.StatusBadRequest, "invalid_limit", "limit must be between 1 and 500")
			return
		}
		limit = parsed
	}
	kind := strings.TrimSpace(strings.ToLower(r.URL.Query().Get("kind")))
	switch kind {
	case "", "all", "access", "error":
	default:
		WriteError(w, r, http.StatusBadRequest, "invalid_kind", "kind must be all, access, or error")
		return
	}
	items, err := h.store.List(r.Context(), LogQuery{Kind: kind, Limit: limit})
	if err != nil {
		WriteError(w, r, http.StatusInternalServerError, "access_log_query_failed", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func parseErrorBody(body string) (string, string) {
	body = strings.TrimSpace(body)
	if body == "" {
		return "", ""
	}
	var payload struct {
		Code    string `json:"code"`
		Message string `json:"message"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err == nil {
		message := payload.Message
		if message == "" {
			message = payload.Error
		}
		return payload.Code, message
	}
	if len(body) > maxCapturedErrorBody {
		body = body[:maxCapturedErrorBody]
	}
	return "", body
}
