package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"hermit/internal/config"
	"hermit/internal/observability"
	"hermit/internal/repository"
	"hermit/internal/review"
	"hermit/internal/rfc"
	"hermit/internal/syncstatus"
	"hermit/internal/thread"
	"hermit/internal/ui"
)

const shutdownTimeout = 10 * time.Second

// App wires foundational HTTP services for the Hermit monolith.
type App struct {
	server *http.Server
}

// New creates an application with baseline routing and server configuration.
func New(cfg config.Config) *App {
	mux := newMux(cfg)

	return &App{
		server: &http.Server{
			Addr:    cfg.ListenAddress,
			Handler: observability.Middleware(mux),
		},
	}
}

// Run starts the HTTP server and blocks until context cancellation or server error.
func (a *App) Run(ctx context.Context) error {
	errCh := make(chan error, 1)

	go func() {
		if err := a.server.ListenAndServe(); err != nil {
			errCh <- err
		}
	}()

	select {
	case <-ctx.Done():
		slog.Info("shutting down hermit")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := a.server.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown server: %w", err)
		}

		if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("server closed with error: %w", err)
		}

		return nil
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}

		return fmt.Errorf("start server: %w", err)
	}
}

func newMux(cfg config.Config) *http.ServeMux {
	mux := http.NewServeMux()
	repositoryService := repository.NewService(nil)
	repositoryService.SeedFromConfig(cfg.Repositories)
	repositoryHandler := repository.NewHandler(repositoryService)
	mux.HandleFunc("POST /api/v1/repositories", repositoryHandler.CreateRepository)
	mux.HandleFunc("GET /api/v1/repositories", repositoryHandler.ListRepositories)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}", repositoryHandler.GetRepository)
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/validate", repositoryHandler.ValidateRepository)

	registryBaseURLs := map[string]string{}
	for _, registry := range cfg.Registries {
		registryBaseURLs[registry.Name] = registry.BaseURL
	}
	rfcService := rfc.NewServiceWithRepositoryResolver(repositoryService, registryBaseURLs)
	rfcHandler := rfc.NewHandler(rfcService)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc", rfcHandler.GetDocument)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc/render", rfcHandler.Render)
	mux.HandleFunc("GET /api/v1/rfcs", rfcHandler.ListRFCs)
	mux.HandleFunc("GET /api/v1/rfcs/{rfcId}", rfcHandler.RenderRFCByID)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/rfcs", rfcHandler.ListRepositoryRFCs)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/rfcs/{rfcId}", rfcHandler.RenderRepositoryRFCByID)

	reviewService := review.NewService(nil)
	reviewHandler := review.NewHandler(reviewService)
	mux.HandleFunc("GET "+review.ReviewStatePath(), reviewHandler.GetReviewState)
	mux.HandleFunc("POST "+review.ReviewApprovePath(), reviewHandler.Approve)

	threadService := thread.NewService(nil)
	threadHandler := thread.NewHandler(threadService)
	mux.HandleFunc("GET "+thread.ThreadsPath(), threadHandler.ListThreads)
	mux.HandleFunc("POST "+thread.ThreadsPath(), threadHandler.CreateThread)
	mux.HandleFunc("POST "+thread.ThreadReplyPath(), threadHandler.ReplyThread)
	mux.HandleFunc("POST "+thread.ThreadResolvePath(), threadHandler.ResolveThread)

	syncHandler := syncstatus.NewHandler()
	mux.HandleFunc("GET "+syncstatus.Path(), syncHandler.GetSyncStatus)

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok","service":"hermit-api","version":"1.0.0"}`))
	})

	mux.Handle("GET /", ui.Handler())

	return mux
}
