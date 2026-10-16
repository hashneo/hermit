package rfc

import (
	"errors"
	"testing"
)

func TestClassifySyncError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"nil", nil, ""},
		{"401", errors.New("list RFCs failed: 401 Unauthorized"), "auth_failed"},
		{"bad credentials", errors.New("GET .github/workflows/ci.yml: 401 Bad credentials []"), "auth_failed"},
		{"token mention", errors.New("repository token revoked by provider"), "auth_failed"},
		{"credential", errors.New("credential helper returned empty"), "auth_failed"},
		{"403", errors.New("list pulls: 403 Forbidden"), "access_denied"},
		{"denied", errors.New("access denied to resource"), "access_denied"},
		{"saml sso", errors.New("403 SAML SSO authorization required"), "access_denied"},
		{"rate limit", errors.New("403 API rate limit exceeded"), "provider_error"},
		{"token permission", errors.New("403 Forbidden: token lacks access"), "access_denied"},
		{"token filename", errors.New("fetch token-guide.md failed: 500 Internal Server Error"), "provider_error"},
		{"network", errors.New("dial tcp: connection refused"), "provider_error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifySyncError(tc.err); got != tc.want {
				t.Errorf("classifySyncError() = %q, want %q", got, tc.want)
			}
		})
	}
}
