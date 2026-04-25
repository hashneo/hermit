package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLocalNetworkAuth_Bypass(t *testing.T) {
	auth := NewLocalNetworkAuth(nil)
	var called bool
	handler := auth.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
	}), false)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest("GET", "/", nil))
	if !called {
		t.Error("expected handler to be called when enforcement is off")
	}
}

func TestLocalNetworkAuth_NoToken(t *testing.T) {
	auth := NewLocalNetworkAuth(nil)
	handler := auth.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), true)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, httptest.NewRequest("GET", "/", nil))
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rr.Code)
	}
}

func TestLocalNetworkAuth_ValidToken(t *testing.T) {
	token := "abc123"
	auth := NewLocalNetworkAuth([]string{token})
	var called bool
	handler := auth.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}), true)
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK || !called {
		t.Errorf("expected 200 with valid token, got %d", rr.Code)
	}
}

func TestLocalNetworkAuth_RevokedToken(t *testing.T) {
	token := "revoke-me"
	auth := NewLocalNetworkAuth([]string{token})
	auth.Revoke(token)
	handler := auth.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), true)
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 after revoke, got %d", rr.Code)
	}
}
