package repository

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestRepositoryConfigCreateGetValidate(t *testing.T) {
	service := NewService(nil)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories", handler.CreateRepository)
	mux.HandleFunc("GET /api/v1/repositories/{repositoryId}", handler.GetRepository)
	mux.HandleFunc("DELETE /api/v1/repositories/{repositoryId}", handler.DeleteRepository)
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/validate", handler.ValidateRepository)
	mux.HandleFunc("POST /api/v1/repositories/{repositoryId}/rotate-token", handler.RotateRepositoryToken)

	createReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories", bytes.NewBufferString(`{"owner":"hashicorp","name":"hermit","base_url":"https://github.example.com/api/v3/","personal_access_token":"ghp_12345678901234567890"}`))
	createResp := httptest.NewRecorder()
	mux.ServeHTTP(createResp, createReq)

	if createResp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d", createResp.Code, http.StatusCreated)
	}

	var created Config
	if err := json.Unmarshal(createResp.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if !created.Validation.Healthy {
		t.Fatalf("expected healthy validation on create")
	}
	if created.Auth.Method != "pat" {
		t.Fatalf("auth method = %q, want %q", created.Auth.Method, "pat")
	}
	if created.BaseURL != "https://github.example.com/api/v3" {
		t.Fatalf("base URL = %q, want normalized GitHub Enterprise API URL", created.BaseURL)
	}

	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/"+created.ID, nil)
	getResp := httptest.NewRecorder()
	mux.ServeHTTP(getResp, getReq)
	if getResp.Code != http.StatusOK {
		t.Fatalf("get status = %d, want %d", getResp.Code, http.StatusOK)
	}

	validateReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/"+created.ID+"/validate", nil)
	validateResp := httptest.NewRecorder()
	mux.ServeHTTP(validateResp, validateReq)
	if validateResp.Code != http.StatusOK {
		t.Fatalf("validate status = %d, want %d", validateResp.Code, http.StatusOK)
	}

	var validation ValidationResponse
	if err := json.Unmarshal(validateResp.Body.Bytes(), &validation); err != nil {
		t.Fatalf("decode validate response: %v", err)
	}
	if !validation.Healthy {
		t.Fatalf("validate healthy = false, want true")
	}

	rotateReq := httptest.NewRequest(http.MethodPost, "/api/v1/repositories/"+created.ID+"/rotate-token", bytes.NewBufferString(`{"personal_access_token":"ghp_rotated1234567890"}`))
	rotateResp := httptest.NewRecorder()
	mux.ServeHTTP(rotateResp, rotateReq)
	if rotateResp.Code != http.StatusOK {
		t.Fatalf("rotate status = %d, want %d", rotateResp.Code, http.StatusOK)
	}

	var rotated Config
	if err := json.Unmarshal(rotateResp.Body.Bytes(), &rotated); err != nil {
		t.Fatalf("decode rotate response: %v", err)
	}
	if !rotated.Validation.Healthy {
		t.Fatalf("expected healthy validation after rotation")
	}

	deleteReq := httptest.NewRequest(http.MethodDelete, "/api/v1/repositories/"+created.ID, nil)
	deleteResp := httptest.NewRecorder()
	mux.ServeHTTP(deleteResp, deleteReq)
	if deleteResp.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want %d", deleteResp.Code, http.StatusNoContent)
	}

	getDeletedReq := httptest.NewRequest(http.MethodGet, "/api/v1/repositories/"+created.ID, nil)
	getDeletedResp := httptest.NewRecorder()
	mux.ServeHTTP(getDeletedResp, getDeletedReq)
	if getDeletedResp.Code != http.StatusNotFound {
		t.Fatalf("get deleted status = %d, want %d", getDeletedResp.Code, http.StatusNotFound)
	}
}

func TestRepositoryConfigCreateRejectsInvalidPAT(t *testing.T) {
	service := NewService(nil)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/repositories", handler.CreateRepository)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/repositories", bytes.NewBufferString(`{"owner":"hashicorp","name":"hermit","personal_access_token":"bad-token"}`))
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d", resp.Code, http.StatusCreated)
	}

	var created Config
	if err := json.Unmarshal(resp.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.Validation.Healthy {
		t.Fatalf("expected unhealthy validation for invalid PAT")
	}
	if created.Validation.LastErrorCode == "" {
		t.Fatalf("expected validation last error code")
	}
}

func TestPersistentRepositoryConfigSurvivesServiceRestart(t *testing.T) {
	dataDir := t.TempDir()
	service := NewPersistentService(nil, dataDir)

	created, err := service.Create(t.Context(), createInput{
		Owner:          "hashicorp",
		Name:           "gantry",
		Registry:       "github",
		BaseURL:        "https://api.github.com/",
		Token:          "ghp_12345678901234567890",
		DocsPathPolicy: "docs",
	})
	if err != nil {
		t.Fatalf("create repository: %v", err)
	}

	reloaded := NewPersistentService(nil, dataDir)
	got, ok := reloaded.Get(created.ID)
	if !ok {
		t.Fatalf("expected repository %s after reload", created.ID)
	}
	if got.Owner != "hashicorp" || got.Name != "gantry" || got.DocsPathPolicy != "docs" {
		t.Fatalf("unexpected repository after reload: %+v", got)
	}
	if got.BaseURL != "https://api.github.com" {
		t.Fatalf("base URL after reload = %q", got.BaseURL)
	}
	if _, err := os.Stat(filepath.Join(dataDir, "repositories.json")); err != nil {
		t.Fatalf("expected repository store file: %v", err)
	}
}
