package registry

import (
	"bytes"
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Authority is the registry authority — the ONLY place in the fleet that holds
// registry source material, and the reason the exchange is a standalone service
// rather than a route on box.
//
// What it holds is a GitHub App's private key and its App id. Nothing else
// long-lived is stored anywhere in this service: there is no GHCR password, no
// PAT, and no operator secret in the environment.
//
// Why a private key is not a long-lived operator secret
//
// The rejected option was a deploy bot's PAT: a PAT with read:packages is BOTH
// a registry password and a general GitHub identity. It authenticates directly
// against ghcr.io for as long as it lives, and its compromise is total until a
// human rotates it. The App private key cannot be used against ghcr.io at all
// — ghcr.io has no idea what to do with an RSA key. The only thing the key can
// do is sign an assertion that THIS app made a request at a given time, and
// GitHub answers that assertion with an installation access token that:
//
//   - carries only the permissions the App was granted (read:packages, scoped
//     to the repositories it is installed on) — pull-only by construction,
//     not by policy;
//   - expires in at most one hour, on GitHub's clock, not ours;
//   - is useless for anything else in GitHub — it cannot read other repos,
//     push, or read the account.
//
// The long-lived material is therefore the minimum any issuer can carry: the
// power to say "I am this app", bounded by the app's own permission set.

// DefaultGitHubAPIURL is GitHub's API when the environment does not override
// it (the override exists so the proof can point at a socket).
const DefaultGitHubAPIURL = "https://api.github.com"

// AppJWTIssuedAtSkew is how far back the assertion's iat is set. GitHub rejects
// an assertion minted in the future, and a box whose clock is a few seconds
// fast would otherwise be refused for a reason nobody can see. Sixty seconds is
// the conventional allowance.
const AppJWTIssuedAtSkew = 60 * time.Second

// AppJWTTTL is the assertion's lifetime. GitHub allows at most ten minutes.
// The assertion is refreshed per exchange rather than cached, so the credential
// a box receives is never older than the exchange that produced it.
const AppJWTTTL = 600 * time.Second

// TokenMinter is what the exchange asks for a credential. It is an interface so
// the exchange does not care whether the authority is a real GitHub App, a
// misconfigured environment, or (in the suite) a stub on a socket.
type TokenMinter interface {
	InstallationToken(ctx context.Context) (*Minted, error)
}

// AuthorityError is an authority failure: the environment is not configured, or
// GitHub would not answer. It is deliberately unrecognizable from the outside —
// an operator is told the authority failed and nothing about the material.
type AuthorityError struct {
	Kind    string // "misconfigured" or "upstream"
	Message string
}

func (e *AuthorityError) Error() string { return e.Message }

// Misconfigured reports whether the environment is not configured.
func (e *AuthorityError) Misconfigured() bool { return e.Kind == "misconfigured" }

// Authority is the one process that holds the App key. The private key is
// unexported and has no accessor, for the same reason Minted's token does not:
// material that cannot be named outside this package cannot be logged.
type Authority struct {
	appID          string
	installationID string
	apiURL         string
	privateKey     *rsa.PrivateKey
	client         *http.Client
}

// NewAuthority parses the PEM, validates the ids, and answers an AuthorityError
// (never a panic) for anything that is not a usable RSA App key. It is
// constructed once, at startup, so a misconfiguration is found before the first
// request rather than during it.
func NewAuthority(privatePEM string, appID, installationID, apiURL string) (*Authority, error) {
	if strings.TrimSpace(appID) == "" {
		return nil, &AuthorityError{Kind: "misconfigured", Message: "REGISTRY_GITHUB_APP_ID is not set"}
	}
	if strings.TrimSpace(privatePEM) == "" {
		return nil, &AuthorityError{Kind: "misconfigured", Message: "REGISTRY_GITHUB_APP_KEY is not set"}
	}
	if strings.TrimSpace(installationID) == "" {
		return nil, &AuthorityError{Kind: "misconfigured", Message: "REGISTRY_GITHUB_INSTALLATION_ID is not set"}
	}

	key, err := parseRSAPrivateKey(privatePEM)
	if err != nil {
		return nil, &AuthorityError{
			Kind:    "misconfigured",
			Message: fmt.Sprintf("REGISTRY_GITHUB_APP_KEY is not an RSA private key: %v", err),
		}
	}

	base := strings.TrimSuffix(strings.TrimSpace(apiURL), "/")
	if base == "" {
		base = DefaultGitHubAPIURL
	}

	return &Authority{
		appID:          strings.TrimSpace(appID),
		installationID: strings.TrimSpace(installationID),
		apiURL:         base,
		privateKey:     key,
		client:         &http.Client{Timeout: 15 * time.Second},
	}, nil
}

// parseRSAPrivateKey reads a PEM private key: PKCS#1 ("RSA PRIVATE KEY"),
// PKCS#8 ("PRIVATE KEY") and the encrypted forms are all shapes a mounted
// GitHub App key can arrive in.
func parseRSAPrivateKey(pemText string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemText))
	if block == nil {
		return nil, fmt.Errorf("not a PEM block")
	}
	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("neither PKCS#1 nor PKCS#8: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("the key is not an RSA key")
	}
	return key, nil
}

// InstallationToken mints an installation access token.
//
// # Why there is no GitHub client library
//
// The fleet's dependency rule says a good existing library is the default and
// writing our own is the exception whose reason is written at the code site.
// For the JWT we take the library (golang-jwt/jwt/v5 — it is *the* RS256 JWT
// library for Go, and hand-rolling RS256 is thirty lines of security-critical
// base64url and padding for no gain). For the token exchange we deliberately
// do not: the call is ONE request — POST
// /app/installations/:id/access_tokens with a JWT bearer — and an
// octokit-equivalent is a full GitHub API client whose version tracker,
// paginator, middleware stack and own dependency tree we would inherit to make
// exactly that one call. The request is built on net/http, which is the
// standard library's own client and what every Go service in this fleet
// already uses.
func (a *Authority) InstallationToken(ctx context.Context) (*Minted, error) {
	token, err := a.appJWT()
	if err != nil {
		return nil, &AuthorityError{Kind: "upstream", Message: fmt.Sprintf("the registry authority could not sign its assertion: %v", err)}
	}

	endpoint := fmt.Sprintf("%s/app/installations/%s/access_tokens", a.apiURL, url.PathEscape(a.installationID))
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(nil))
	if err != nil {
		return nil, &AuthorityError{Kind: "upstream", Message: fmt.Sprintf("the registry authority could not build its request: %v", err)}
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "cafaye-keyholder")

	response, err := a.client.Do(request)
	if err != nil {
		return nil, &AuthorityError{Kind: "upstream", Message: "the registry authority could not reach GitHub"}
	}
	defer func() { _, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20)); _ = response.Body.Close() }()

	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, &AuthorityError{Kind: "upstream", Message: "the registry authority could not read GitHub's answer"}
	}

	if response.StatusCode < 200 || response.StatusCode > 299 {
		// The status, never the body: an error body is not where a credential
		// lives, but nothing downstream should ever learn that it might.
		return nil, &AuthorityError{
			Kind:    "upstream",
			Message: fmt.Sprintf("GitHub answered %d to the installation-token request", response.StatusCode),
		}
	}

	return a.mintedFrom(payload)
}

// appJWT signs an assertion that THIS app is asking, for ten minutes.
//
// golang-jwt/jwt/v5: the library that exists for exactly this. The claims are
// the three GitHub documents — iss, iat, exp — and RS256 is pinned rather than
// inferred, because an assertion whose algorithm a caller can choose is an
// assertion that can be made to be something else.
func (a *Authority) appJWT() (string, error) {
	now := time.Now()
	claims := jwt.RegisteredClaims{
		Issuer:    a.appID,
		IssuedAt:  jwt.NewNumericDate(now.Add(-AppJWTIssuedAtSkew)),
		ExpiresAt: jwt.NewNumericDate(now.Add(AppJWTTTL)),
	}
	return jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(a.privateKey)
}

// installationTokenResponse is what GitHub answers, reduced to what the
// exchange needs. permissions is carried because the suite asserts on it:
// pull-only is a property of the minted credential, and a minted credential
// that can push is a defect the suite must be able to see.
type installationTokenResponse struct {
	Token       string            `json:"token"`
	ExpiresAt   string            `json:"expires_at"`
	Permissions map[string]string `json:"permissions"`
}

func (a *Authority) mintedFrom(payload []byte) (*Minted, error) {
	var response installationTokenResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, &AuthorityError{Kind: "upstream", Message: "the installation-token response is not JSON"}
	}
	if response.Token == "" {
		return nil, &AuthorityError{Kind: "upstream", Message: "the installation-token response is missing token"}
	}
	if response.ExpiresAt == "" {
		return nil, &AuthorityError{Kind: "upstream", Message: "the installation-token response is missing expires_at"}
	}
	// GitHub's own clock, read from the response and never trusted from ours:
	// the credential's lifetime is whatever GitHub says it is.
	expiresAt, err := time.Parse(time.RFC3339, response.ExpiresAt)
	if err != nil {
		return nil, &AuthorityError{
			Kind:    "upstream",
			Message: fmt.Sprintf("the installation-token response carries an unparseable expires_at: %v", err),
		}
	}
	return NewMinted(MintedParams{
		Token:       response.Token,
		ExpiresAt:   expiresAt,
		Permissions: response.Permissions,
	})
}
