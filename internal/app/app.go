package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
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
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rfcs/{rfcId}/submit-for-review", rfcHandler.SubmitForReview)

	reviewService := review.NewServiceWithMergeClient(nil, review.NewHTTPMergeClient(repositoryService, registryBaseURLs))
	reviewHandler := review.NewHandler(reviewService)
	mux.HandleFunc("GET "+review.ReviewStatePath(), reviewHandler.GetReviewState)
	mux.HandleFunc("POST "+review.ReviewApprovePath(), reviewHandler.Approve)
	mux.HandleFunc("GET "+review.ReviewMergeStatusPath(), reviewHandler.GetMergeStatus)
	mux.HandleFunc("PUT "+review.ReviewUpdateBranchPath(), reviewHandler.UpdateBranch)

	threadService := thread.NewServiceWithDataDir(
		thread.NewHTTPGitHubClient(repositoryService, registryBaseURLs),
		cfg.DataDir,
	)
	threadHandler := thread.NewHandler(threadService)
	mux.HandleFunc("GET "+thread.ThreadsPath(), threadHandler.ListThreads)
	mux.HandleFunc("POST "+thread.ThreadsPath(), threadHandler.CreateThread)
	mux.HandleFunc("POST "+thread.ThreadReplyPath(), threadHandler.ReplyThread)
	mux.HandleFunc("POST "+thread.ThreadResolvePath(), threadHandler.ResolveThread)
	mux.HandleFunc("POST "+thread.ThreadUnresolvePath(), threadHandler.UnresolveThread)
	mux.HandleFunc("DELETE "+thread.ThreadDeletePath(), threadHandler.DeleteThread)
	mux.HandleFunc("DELETE "+thread.ThreadMessageDeletePath(), threadHandler.DeleteMessage)

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

	mux.HandleFunc("GET /api/v1/me", meHandler(cfg))

	mux.Handle("GET /", ui.Handler())

	return mux
}

// meHandler proxies the authenticated user's identity from GitHub/Gitea.
// The Swift client sends Authorization: Bearer <PAT>; this handler tries
// all configured registries in order and returns the first successful
// { "login": "...", "name": "...", "avatar_url": "..." } response.
func meHandler(cfg config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if token == "" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}

		// Build candidate base URLs: all configured registries + fallback to GitHub.
		candidates := make([]string, 0, len(cfg.Registries)+1)
		for _, reg := range cfg.Registries {
			if b := strings.TrimSpace(reg.BaseURL); b != "" {
				candidates = append(candidates, strings.TrimRight(b, "/"))
			}
		}
		if len(candidates) == 0 {
			candidates = append(candidates, "https://api.github.com")
		}

		var upstream struct {
			Login     string `json:"login"`
			Name      string `json:"name"`
			AvatarURL string `json:"avatar_url"`
		}

		for _, baseURL := range candidates {
			userURL := baseURL + "/user"
			req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, userURL, nil)
			if err != nil {
				continue
			}
			req.Header.Set("Authorization", "Bearer "+token)
			req.Header.Set("Accept", "application/json")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				continue
			}
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
			resp.Body.Close()

			if resp.StatusCode < 200 || resp.StatusCode >= 300 {
				continue
			}
			if err := json.Unmarshal(body, &upstream); err != nil || upstream.Login == "" {
				continue
			}
			// Found a valid response — return it.
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{
				"login":      upstream.Login,
				"name":       upstream.Name,
				"avatar_url": upstream.AvatarURL,
			})
			return
		}

		http.Error(w, `{"error":"could_not_resolve_user"}`, http.StatusBadGateway)
	}
}
