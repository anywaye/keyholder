package registry

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// The exchange's own suite. Everything it asserts is asserted against real
// objects: the app is driven through net/http with httptest, the capability is
// spent through Box against a stub on a socket that answers exactly as box's
// renderers do, and the credential is minted from a real RSA key through the
// same Authority code path production uses. The only things faked are the two
// networks that must not be dialed in a test — GitHub, and a live box — and
// each is faked at its wire boundary, so the code under test is the code that
// ships.

const (
	testBoxID             = "11111111-2222-3333-4444-555555555555"
	testOtherBoxID        = "88888887-7777-6666-5555-444444444444"
	testAccountID         = "99999999-8888-7777-6666-555555555555"
	testInstallationToken = "ghs_realtokenvalue"
)

var (
	testCapability      = "cap_" + strings.Repeat("a", 64)
	testOtherCapability = "cap_" + strings.Repeat("b", 64)
)

// testKey is a real RSA key, so Authority's parsing, validation and RS256
// signing are the shipped ones. 2048 bits is GitHub's floor for App keys.
var testKey = mustGenerateKey()

func mustGenerateKey() *rsa.PrivateKey {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return key
}

func testKeyPEM() string {
	return string(pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(testKey),
	}))
}

// recordedRequest is what a stub saw arrive: the exact request the production
// client built, same path, same bearer, same body.
type recordedRequest struct {
	Method        string
	Path          string
	Authorization string
	ContentType   string
	Body          string
	Accept        string
	APIVersion    string
}

type recorder struct {
	mu       sync.Mutex
	requests []recordedRequest
}

func (rec *recorder) add(request recordedRequest) {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	rec.requests = append(rec.requests, request)
}

func (rec *recorder) count() int {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	return len(rec.requests)
}

func (rec *recorder) first() recordedRequest {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.requests) == 0 {
		return recordedRequest{}
	}
	return rec.requests[0]
}

// boxReceipt is box's own redemption answer, spelled exactly as its renderer
// spells it.
func boxReceipt(purpose, boxID, expiresAt string) string {
	if purpose == "" {
		purpose = ExchangePurpose
	}
	if boxID == "" {
		boxID = testBoxID
	}
	if expiresAt == "" {
		expiresAt = time.Now().UTC().Format(time.RFC3339)
	}
	body, _ := json.Marshal(map[string]any{
		"capability": map[string]string{
			"purpose":    purpose,
			"box_id":     boxID,
			"account_id": testAccountID,
			"expires_at": expiresAt,
		},
	})
	return string(body)
}

// installationTokenBody is GitHub's own installation-token answer.
func installationTokenBody(expiresAt time.Time, permissions map[string]string) string {
	if permissions == nil {
		permissions = map[string]string{"packages": "read"}
	}
	if expiresAt.IsZero() {
		expiresAt = time.Now().Add(time.Hour)
	}
	body, _ := json.Marshal(map[string]any{
		"token":       testInstallationToken,
		"expires_at":  expiresAt.UTC().Format(time.RFC3339),
		"permissions": permissions,
	})
	return string(body)
}

// githubAnswer is what a GitHub stub answers, and is built per assertion so a
// test can answer differently for a different claim.
type githubAnswer struct {
	status int
	body   string
}

// newGitHubStub stands a stub on a socket that VERIFIES the App's own RS256
// assertion against the public half of the key the service holds the private
// half of, before it answers. It is the only way the suite can prove the
// assertion is real, and it is the same thing the proof script's stub does.
func newGitHubStub(t *testing.T, rec *recorder, answer func(claims jwt.MapClaims) githubAnswer) *httptest.Server {
	t.Helper()
	if answer == nil {
		answer = func(jwt.MapClaims) githubAnswer {
			return githubAnswer{status: http.StatusCreated, body: installationTokenBody(time.Time{}, nil)}
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		assertion, found := strings.CutPrefix(header, "Bearer ")
		rec.add(recordedRequest{
			Path:          r.URL.Path,
			Accept:        r.Header.Get("Accept"),
			APIVersion:    r.Header.Get("X-GitHub-Api-Version"),
			Authorization: header,
		})
		if !found {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"message":"a JWT is required"}`)
			return
		}
		// Parsed into the claims the answer builder receives, so a test can
		// answer differently for a different claim — and so an assertion that
		// does not verify against the key the service holds is a test failure
		// rather than a silent empty map.
		claims := jwt.MapClaims{}
		if _, err := jwt.ParseWithClaims(assertion, claims, func(*jwt.Token) (any, error) {
			return testKey.Public(), nil
		}, jwt.WithValidMethods([]string{"RS256"})); err != nil {
			t.Errorf("the App's assertion did not verify against the key the service holds: %v", err)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		resolved := answer(claims)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resolved.status)
		_, _ = io.WriteString(w, resolved.body)
	}))
	t.Cleanup(server.Close)
	return server
}

// newBoxStub stands box's redeem door on a socket.
func newBoxStub(t *testing.T, rec *recorder, respond func(w http.ResponseWriter, r *http.Request)) *httptest.Server {
	t.Helper()
	if respond == nil {
		respond = func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, boxReceipt("", "", ""))
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		rec.add(recordedRequest{
			Method:        r.Method,
			Path:          r.URL.Path,
			Authorization: r.Header.Get("Authorization"),
			ContentType:   r.Header.Get("Content-Type"),
			Body:          string(body),
		})
		respond(w, r)
	}))
	t.Cleanup(server.Close)
	return server
}

// wireExchange points a real Box client and a real Authority at stubs on
// sockets. Nothing is mocked: the URLs, the headers, the bearer, the RS256
// assertion and the JSON parsing are all the shipped code's.
func wireExchange(t *testing.T, github func(jwt.MapClaims) githubAnswer, box func(http.ResponseWriter, *http.Request)) (*Exchange, *recorder, *recorder) {
	t.Helper()
	boxRec := &recorder{}
	githubRec := &recorder{}
	boxServer := newBoxStub(t, boxRec, box)
	githubServer := newGitHubStub(t, githubRec, github)

	authority, err := NewAuthority(testKeyPEM(), "123456", "987654", githubServer.URL)
	if err != nil {
		t.Fatalf("the test authority should build: %v", err)
	}
	exchange := NewExchange(NewBox(boxServer.URL), authority, DefaultRegistryHost)
	return exchange, boxRec, githubRec
}

// defaultExchange is the happy path: box redeems, GitHub mints an hour of
// read:packages.
func defaultExchange(t *testing.T) (*Exchange, *recorder, *recorder) {
	t.Helper()
	return wireExchange(t, nil, nil)
}

func readOnlyAuthority(t *testing.T, githubURL string) *Authority {
	t.Helper()
	authority, err := NewAuthority(testKeyPEM(), "123456", "987654", githubURL)
	if err != nil {
		t.Fatalf("the test authority should build: %v", err)
	}
	return authority
}

func boxRefusing(t *testing.T, status int, code, message string) func(http.ResponseWriter, *http.Request) {
	t.Helper()
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		body, _ := json.Marshal(map[string]any{
			"error": map[string]string{"code": code, "message": message},
		})
		_, _ = w.Write(body)
	}
}

// refusalOf pulls a Refusal out of an error, or fails the test naming what it
// got instead.
func refusalOf(t *testing.T, err error) *Refusal {
	t.Helper()
	if err == nil {
		t.Fatal("expected a refusal, got none")
	}
	if refusal, ok := err.(*Refusal); ok {
		return refusal
	}
	t.Fatalf("expected a *Refusal, got %T: %v", err, err)
	return nil
}

func mustCall(t *testing.T, exchange *Exchange, capability, boxID string) (*Minted, error) {
	t.Helper()
	return exchange.Call(context.Background(), capability, boxID)
}

func callExpectingRefusal(t *testing.T, exchange *Exchange, capability, boxID string) *Refusal {
	t.Helper()
	_, err := mustCall(t, exchange, capability, boxID)
	return refusalOf(t, err)
}

func assertNoGitHub(t *testing.T, rec *recorder, when string) {
	t.Helper()
	if rec.count() != 0 {
		t.Fatalf("github saw %d request(s) — %s", rec.count(), when)
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	body, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("cannot marshal: %v", err)
	}
	return string(body)
}

func parseBody(t *testing.T, body string) map[string]any {
	t.Helper()
	var parsed map[string]any
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("body is not JSON: %v (%s)", err, body)
	}
	return parsed
}

var _ = fmt.Sprintf
