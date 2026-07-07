// Package middleware provides HTTP middleware for the Hermit server.
package middleware

import (
	"net"
	"net/http"
	"strings"
	"sync"
)

// LocalNetworkAuth is a middleware that validates Bearer tokens for local-network
// mode requests. Tokens are registered at app launch (loaded from UserDefaults) and
// when a new iPad completes the Multipeer Connectivity pairing handshake.
//
// Loopback requests (127.0.0.1, ::1) are always allowed — they come from the Mac
// app itself.  All other requests (iPad on LAN) must supply a valid Bearer token.
type LocalNetworkAuth struct {
	mu     sync.RWMutex
	tokens map[string]struct{} // set of valid tokens
}

// NewLocalNetworkAuth creates a new middleware with an initial set of tokens.
func NewLocalNetworkAuth(initial []string) *LocalNetworkAuth {
	m := &LocalNetworkAuth{
		tokens: make(map[string]struct{}, len(initial)),
	}
	for _, t := range initial {
		if t != "" {
			m.tokens[t] = struct{}{}
		}
	}
	return m
}

// Register adds a token to the valid set (called after a new pairing handshake).
func (a *LocalNetworkAuth) Register(token string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.tokens[token] = struct{}{}
}

// Revoke removes a token (called when the user revokes a paired device).
func (a *LocalNetworkAuth) Revoke(token string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.tokens, token)
}

// Middleware returns an http.Handler that enforces token validation when
// localNetworkOnly is true. When false (e.g. loopback-only embedded mode),
// the middleware is a no-op passthrough.
func (a *LocalNetworkAuth) Middleware(next http.Handler, enforce bool) http.Handler {
	if !enforce {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := extractBearer(r)
		if token == "" || !a.valid(token) {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Handler returns an http.Handler that automatically enforces token auth for
// non-loopback requests and bypasses auth for loopback (Mac app itself).
// This is the preferred entry point for the embedded server.
func (a *LocalNetworkAuth) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		// Allow loopback — these are the Mac app's own requests.
		if host == "127.0.0.1" || host == "::1" {
			next.ServeHTTP(w, r)
			return
		}
		// Enforce bearer token for LAN clients (iPad).
		token := extractBearer(r)
		if token == "" || !a.valid(token) {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *LocalNetworkAuth) valid(token string) bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	_, ok := a.tokens[token]
	return ok
}

func extractBearer(r *http.Request) string {
	v := r.Header.Get("Authorization")
	if strings.HasPrefix(v, "Bearer ") {
		return strings.TrimPrefix(v, "Bearer ")
	}
	return ""
}
