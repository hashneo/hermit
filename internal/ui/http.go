package ui

import (
	"embed"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"strings"
)

//go:embed static/*
var staticFS embed.FS

const defaultUIDir = "ui/dist"

// Handler returns an HTTP handler that serves the web UI.
//
// If ui/dist exists on disk, it is served so the built React bundle can be
// delivered directly by the app. Otherwise, the embedded placeholder UI is
// served.
func Handler() http.Handler {
	if _, err := os.Stat(defaultUIDir); err == nil {
		return spaFileServer(os.DirFS(defaultUIDir))
	}

	assets, err := fs.Sub(staticFS, "static")
	if err != nil {
		panic(err)
	}

	return spaFileServer(assets)
}

func spaFileServer(files fs.FS) http.Handler {
	fileServer := http.FileServer(http.FS(files))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedPath := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		if requestedPath == "." {
			requestedPath = "index.html"
		}

		if hasFile(files, requestedPath) {
			fileServer.ServeHTTP(w, r)
			return
		}

		if hasFile(files, "index.html") {
			index, err := files.Open("index.html")
			if err == nil {
				defer index.Close()
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				_, _ = io.Copy(w, index)
				return
			}
		}

		http.NotFound(w, r)
	})
}

func hasFile(files fs.FS, name string) bool {
	entry, err := fs.Stat(files, name)
	if err != nil {
		return false
	}

	return !entry.IsDir()
}
