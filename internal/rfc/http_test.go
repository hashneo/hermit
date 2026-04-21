package rfc

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGetDocumentAndRender(t *testing.T) {
	service := NewService()
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc", handler.GetDocument)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc/render", handler.Render)

	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-1/pull-requests/11/rfc", nil)
	getResp := httptest.NewRecorder()
	mux.ServeHTTP(getResp, getReq)

	if getResp.Code != http.StatusOK {
		t.Fatalf("get document status = %d, want %d", getResp.Code, http.StatusOK)
	}

	var doc Document
	if err := json.Unmarshal(getResp.Body.Bytes(), &doc); err != nil {
		t.Fatalf("decode document response: %v", err)
	}
	if doc.Eligibility.Status != "eligible" {
		t.Fatalf("eligibility status = %q, want eligible", doc.Eligibility.Status)
	}

	renderReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/repo-1/pull-requests/11/rfc/render", nil)
	renderResp := httptest.NewRecorder()
	mux.ServeHTTP(renderResp, renderReq)

	if renderResp.Code != http.StatusOK {
		t.Fatalf("render status = %d, want %d", renderResp.Code, http.StatusOK)
	}

	var render Render
	if err := json.Unmarshal(renderResp.Body.Bytes(), &render); err != nil {
		t.Fatalf("decode render response: %v", err)
	}
	if render.RenderedHTML == "" {
		t.Fatalf("expected rendered html")
	}
	if len(render.AnchorMap) == 0 {
		t.Fatalf("expected non-empty anchor map")
	}
}
