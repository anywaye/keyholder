package registry

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// The fourth refusal the brief names: a credential written is never echoed. The
// assertion is made against every path a value can leak through — the service's
// log, the exception, the interpolated message — not just the obvious one.

// newTestApp builds the whole HTTP surface in-process, the way a request spec
// drives Rails, so what is exercised is the shipped handler and not a mock of it.
func newTestApp(t *testing.T, exchange *Exchange) (*httptest.Server, *bytes.Buffer) {
	t.Helper()
	log := &bytes.Buffer{}
	app := NewApp(exchange, log)
	server := httptest.NewServer(app.Handler())
	t.Cleanup(server.Close)
	return server, log
}

// defaultApp is the app wired to the happy path: box redeems, GitHub mints an
// hour of read:packages.
func defaultApp(t *testing.T) (*httptest.Server, *bytes.Buffer, *recorder, *Exchange) {
	t.Helper()
	exchange, box, _ := defaultExchange(t)
	_ = box
	server, log := newTestApp(t, exchange)
	return server, log, box, exchange
}

// exchangeRequest is the caller: the capability as a bearer, the box in the body.
func exchangeRequest(t *testing.T, url, capability, body, contentType string) (int, string) {
	t.Helper()
	request, err := http.NewRequestWithContext(context.Background(), http.MethodPost, url+"/v1/registry-credentials", strings.NewReader(body))
	if err != nil {
		t.Fatalf("cannot build the request: %v", err)
	}
	if capability != "" {
		request.Header.Set("Authorization", "Bearer "+capability)
	}
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("the exchange could not be called: %v", err)
	}
	defer func() { _ = response.Body.Close() }()
	payload, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(payload)
}

func buildMinted(t *testing.T) *Minted {
	t.Helper()
	credential, err := NewMinted(MintedParams{
		Token:       testInstallationToken,
		ExpiresAt:   time.Now().Add(time.Hour),
		Permissions: map[string]string{"packages": "read"},
	})
	if err != nil {
		t.Fatalf("a credential should build: %v", err)
	}
	return credential
}

// The redacted form carries everything an operator needs and nothing a registry
// could be handed. This is asserted against every formatting verb, which is the
// Go equivalent of the Ruby original overriding both #inspect and #to_s.
func TestTheCredentialRendersRedactedAnywhereItIsInterpolated(t *testing.T) {
	credential := buildMinted(t)

	renderings := map[string]string{
		"String()":       credential.String(),
		"%v":             fmt.Sprintf("%v", credential),
		"%s":             fmt.Sprintf("%s", credential),
		"%+v":            fmt.Sprintf("%+v", credential),
		"%q":             fmt.Sprintf("%q", credential),
		"%d":             fmt.Sprintf("%d", credential),
		"interpolation":  fmt.Sprintf("note: %s", credential),
		"error":          fmt.Sprintf("exchanging: %s", credential),
		"GoStringer-ish": fmt.Sprintf("%#v", credential),
	}
	for name, rendered := range renderings {
		if strings.Contains(rendered, testInstallationToken) {
			t.Errorf("%s carries the credential: %s", name, rendered)
		}
		if strings.Contains(rendered, "ghs_") {
			t.Errorf("%s carries the credential: %s", name, rendered)
		}
	}

	// The redacted form still says WHAT was minted.
	redacted := credential.Redacted()
	for _, want := range []string{"ghcr.io", "pull_only=true", "expires_at=", "Minted("} {
		if !strings.Contains(redacted, want) {
			t.Errorf("the redacted form should carry %q: %s", want, redacted)
		}
	}
	if !strings.Contains(redacted, "packages") {
		t.Errorf("the redacted form should name the granted permissions: %s", redacted)
	}
}

// The token has no accessor, so nothing outside the package can name it. This
// is the structural half of the guarantee: a credential that cannot be reached
// is a credential that cannot be logged.
func TestTheCredentialTokenHasNoAccessor(t *testing.T) {
	source, err := os.ReadFile("minted.go")
	if err != nil {
		t.Fatalf("cannot read minted.go: %v", err)
	}
	if regexp.MustCompile(`(?m)^func \(m \*Minted\) Token\(`).Match(source) {
		t.Error("Minted exposes its token — the credential should only leave as the encoded dockerconfigjson")
	}
}

// The log line the service actually writes.
func TestTheAppLogsTheOutcomeAndNeverTheCredential(t *testing.T) {
	server, log, _, _ := defaultApp(t)

	status, body := exchangeRequest(t, server.URL, testCapability,
		mustJSON(t, map[string]string{"box_id": testBoxID}), "application/json")

	if status != http.StatusOK {
		t.Fatalf("status: got %d, want 200 (%s)", status, body)
	}

	for _, want := range []string{"registry.credential_exchange", `"status":200`} {
		if !strings.Contains(log.String(), want) {
			t.Errorf("the log should carry %q, got: %s", want, log.String())
		}
	}

	// THE assertion: the credential is not in the log, in any form.
	forbidden := []string{
		testInstallationToken,
		"dockerconfigjson",
		MintedUsername,
		"eyJhdXRocyI", // the prefix of a base64 dockerconfigjson
		base64.StdEncoding.EncodeToString([]byte(`{"auths"`)),
		testCapability, // and the capability is not echoed either
	}
	for _, forbiddenValue := range forbidden {
		if strings.Contains(log.String(), forbiddenValue) {
			t.Errorf("the log echoes %q: %s", forbiddenValue, log.String())
		}
	}
}

// The refusal path: the exchange answers box's own refusal, and the log names it
// without carrying anything either side of it.
func TestARefusalIsLoggedWithoutTheCredential(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, boxRefusing(t, http.StatusGone,
		"capability_expired", "capability has expired"))
	server, log := newTestApp(t, exchange)

	status, body := exchangeRequest(t, server.URL, testCapability,
		mustJSON(t, map[string]string{"box_id": testBoxID}), "application/json")

	if status != http.StatusGone {
		t.Errorf("status: got %d, want box's own 410", status)
	}
	parsed := parseBody(t, body)
	errObject, _ := parsed["error"].(map[string]any)
	if errObject["code"] != "capability_expired" {
		t.Errorf("code: got %v, want capability_expired", errObject["code"])
	}

	if !strings.Contains(log.String(), "capability_expired") {
		t.Errorf("the refusal should be named in the log: %s", log.String())
	}
	for _, forbidden := range []string{testInstallationToken, testCapability} {
		if strings.Contains(log.String(), forbidden) {
			t.Errorf("the log echoes %q on the refusal path: %s", forbidden, log.String())
		}
	}
}

// The response body DOES carry the credential — that is the product — and it is
// the only place in the service that it appears.
func TestTheResponseCarriesTheCredentialAndItsLifetime(t *testing.T) {
	server, _, _, _ := defaultApp(t)

	status, body := exchangeRequest(t, server.URL, testCapability,
		mustJSON(t, map[string]string{"box_id": testBoxID}), "application/json")

	if status != http.StatusOK {
		t.Fatalf("status: got %d, want 200 (%s)", status, body)
	}
	parsed := parseBody(t, body)
	encoded, _ := parsed["dockerconfigjson"].(string)
	if encoded == "" {
		t.Fatal("the product is the dockerconfigjson, and it is absent")
	}
	if parsed["expires_at"] == "" {
		t.Error("the credential's lifetime is absent")
	}
	if parsed["seconds_remaining"] == nil {
		t.Error("the seconds remaining are absent")
	}
	if seconds, _ := parsed["seconds_remaining"].(float64); seconds < 1 {
		t.Errorf("seconds_remaining: got %v, want life on it", parsed["seconds_remaining"])
	}
	if parsed["registry"] != "ghcr.io" {
		t.Errorf("registry: got %v, want ghcr.io", parsed["registry"])
	}
	// It decodes to a real ghcr.io auth entry.
	decoded := decodeDockerConfig(t, encoded)
	entry, _ := decoded["auths"].(map[string]any)["ghcr.io"].(map[string]any)
	if entry["password"] != testInstallationToken {
		t.Error("the decoded credential should be the installation token")
	}
}

// The route shape: a capability in a URL path would land in access logs, so it
// goes in the bearer, and a route nobody declared is a 404.
func TestAnUnknownRouteIsA404AndHealthIsA200(t *testing.T) {
	server, _, _, _ := defaultApp(t)

	response, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatalf("health: %v", err)
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		t.Errorf("healthz: got %d, want 200", response.StatusCode)
	}

	request, err := http.NewRequestWithContext(context.Background(), http.MethodGet,
		server.URL+"/v1/capabilities/"+testCapability+"/registry-credential", nil)
	if err != nil {
		t.Fatalf("cannot build the request: %v", err)
	}
	notFound, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("the capability-in-a-path request: %v", err)
	}
	defer func() { _ = notFound.Body.Close() }()
	if notFound.StatusCode != http.StatusNotFound {
		t.Errorf("the capability must never travel in a URL path: got %d, want 404", notFound.StatusCode)
	}
}

// A request with no bearer or no body is refused by shape, not by a 500.
func TestARequestWithoutTheCapabilityIsRefusedByShape(t *testing.T) {
	server, _, _, _ := defaultApp(t)

	status, body := exchangeRequest(t, server.URL, "",
		mustJSON(t, map[string]string{"box_id": testBoxID}), "application/json")
	if status != http.StatusBadRequest {
		t.Errorf("no capability: got %d, want 400", status)
	}
	if parsed := parseBody(t, body); dig(parsed, "error", "code") != "capability_required" {
		t.Errorf("no capability: got %v, want capability_required", parsed["error"])
	}

	status, body = exchangeRequest(t, server.URL, testCapability, "not json", "application/json")
	if status != http.StatusBadRequest {
		t.Errorf("malformed body: got %d, want 400", status)
	}
	if parsed := parseBody(t, body); dig(parsed, "error", "code") != "malformed_body" {
		t.Errorf("malformed body: got %v, want malformed_body", parsed["error"])
	}
}

// A missing/misconfigured authority is a refusal at request time — 503
// authority_error — and never a crash, and never a half-built credential.
func TestAMisconfiguredAuthorityAnswers503AuthorityError(t *testing.T) {
	boxRec := &recorder{}
	githubRec := &recorder{}
	boxServer := newBoxStub(t, boxRec, nil)
	_ = newGitHubStub(t, githubRec, nil)

	authority, err := NewTokenMinter(Config{
		BoxURL:               boxServer.URL,
		GitHubAppID:          "",
		GitHubInstallationID: "987654",
		GitHubAPIURL:         "https://api.github.invalid",
	})
	if err == nil {
		t.Fatal("a misconfigured authority should be reported")
	}
	if _, ok := authority.(unavailableAuthority); !ok {
		t.Fatalf("the minter should refuse rather than mint: got %T", authority)
	}

	exchange := NewExchange(NewBox(boxServer.URL), authority, DefaultRegistryHost)
	server, log := newTestApp(t, exchange)

	status, body := exchangeRequest(t, server.URL, testCapability,
		mustJSON(t, map[string]string{"box_id": testBoxID}), "application/json")

	if status != http.StatusServiceUnavailable {
		t.Fatalf("status: got %d, want 503 (%s)", status, body)
	}
	parsed := parseBody(t, body)
	if dig(parsed, "error", "code") != "authority_error" {
		t.Errorf("code: got %v, want authority_error", parsed["error"])
	}
	if strings.Contains(body, "REGISTRY_GITHUB_APP_KEY") {
		t.Errorf("the authority's material is named in the response: %s", body)
	}
	// The capability WAS spent — box answered — and the refusal is the
	// authority's, exactly as a failed image pull would leave it.
	if boxRec.count() != 1 {
		t.Errorf("box saw %d request(s), want the capability spent exactly once", boxRec.count())
	}
	assertNoGitHub(t, githubRec, "a misconfigured authority must not dial GitHub")
	if strings.Contains(log.String(), testInstallationToken) {
		t.Errorf("the log echoes a credential on the authority-error path: %s", log.String())
	}
}

// A GitHub that will not answer is the same refusal, and the capability stays
// spent exactly as a failed image pull would leave it.
func TestAnUnreachableGitHubAnswers503AuthorityError(t *testing.T) {
	exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
		return githubAnswer{status: http.StatusInternalServerError, body: `{"message":"boom"}`}
	}, nil)
	server, _ := newTestApp(t, exchange)

	status, body := exchangeRequest(t, server.URL, testCapability,
		mustJSON(t, map[string]string{"box_id": testBoxID}), "application/json")

	if status != http.StatusServiceUnavailable {
		t.Fatalf("status: got %d, want 503 (%s)", status, body)
	}
	if parsed := parseBody(t, body); dig(parsed, "error", "code") != "authority_error" {
		t.Errorf("code: got %v, want authority_error", parsed["error"])
	}
}

// dig walks a decoded JSON body.
func dig(parsed map[string]any, path ...string) any {
	var current any = parsed
	for _, key := range path {
		object, ok := current.(map[string]any)
		if !ok {
			return nil
		}
		current = object[key]
	}
	return current
}

// --- the negative control ------------------------------------------------
//
// The house style: no line of the source writes the credential anywhere. A bare
// fmt.Print, a println, a direct reach for stdout — those are the ways a value
// reaches a log, so the files that hold it are checked for one. There is exactly
// one reference to stdout in the repository, and it is the log destination in
// cmd/keyholder/main.go: an injected sink, not a print of a value. The Ruby
// original made the same allowance for `@logger.puts`.
func TestNoSourceFileWritesTheCredentialToStdout(t *testing.T) {
	root := repoRoot(t)
	// The one reference to stdout the fleet allows: the log destination, which
	// is a destination and not a print of a value (the Ruby original made the
	// same allowance for `@logger.puts`). The patterns below are assembled from
	// pieces so this test's own source cannot satisfy them — a negative control
	// that flags itself is a negative control nobody can run.
	allowedSinkFile := filepath.Join("cmd", "keyholder", "main.go")
	allowedSinkToken := "logSink"
	allowedSinkStream := "os." + "Stdout"
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`(?m)\bos\.` + "Stdout" + `\b`),
		regexp.MustCompile(`(?m)\bos\.` + "Stderr" + `\b`),
		regexp.MustCompile(`\bfmt\.Print(f|ln)?\(`),
		regexp.MustCompile(`(?m)^\s*(print|println)\(`),
	}
	files := 0
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			switch info.Name() {
			case ".git", "vendor":
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".go" {
			return nil
		}
		files++
		source, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(string(source), "\n")
		for number, line := range lines {
			matched := false
			for _, pattern := range patterns {
				if pattern.MatchString(line) {
					matched = true
				}
			}
			if !matched {
				continue
			}
			location := fmt.Sprintf("%s:%d", path, number+1)
			// The one allowed reference: the log sink, and nothing else.
			if strings.Contains(path, allowedSinkFile) &&
				strings.Contains(line, allowedSinkToken) && strings.Contains(line, allowedSinkStream) {
				continue
			}
			t.Errorf("%s writes to stdout — %q", location, strings.TrimSpace(line))
		}
		return nil
	})
	if err != nil {
		t.Fatalf("cannot walk the repository: %v", err)
	}
	if files < 5 {
		t.Fatalf("the scan found %d Go files — it is not looking where the source is", files)
	}
}

// repoRoot is the directory this suite runs one level below.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("cannot find the repository root: %v", err)
	}
	return root
}
