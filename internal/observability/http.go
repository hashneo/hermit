package observability

import (
	"encoding/json"
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"net/http"
	"time"
)

const CorrelationHeader = "X-Correlation-Id"

type contextKey string

const correlationContextKey contextKey = "correlation-id"

func Middleware(next http.Handler) http.Handler {
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

		slog.Info("http request completed",
			"method", r.Method,
			"path", r.URL.Path,
			"status", recorder.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"correlation_id", correlationID,
		)
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
	status int
}

func (r *statusRecorder) WriteHeader(statusCode int) {
	r.status = statusCode
	r.ResponseWriter.WriteHeader(statusCode)
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
