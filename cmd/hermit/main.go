package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"hermit/internal/app"
	"hermit/internal/config"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load configuration", "error", err)
		os.Exit(1)
	}

	application := app.New(cfg)
	url := startupURL(cfg.ListenAddress)

	slog.Info("starting hermit", "address", cfg.ListenAddress, "url", url)

	if err := application.Run(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("application stopped with error", "error", err)
		os.Exit(1)
	}
}

func startupURL(listenAddress string) string {
	if strings.HasPrefix(listenAddress, ":") {
		return fmt.Sprintf("http://localhost%s", listenAddress)
	}

	if strings.Contains(listenAddress, "://") {
		return listenAddress
	}

	return fmt.Sprintf("http://%s", listenAddress)
}
