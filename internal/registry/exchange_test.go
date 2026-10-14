package registry

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// The four refusals the brief names, plus the shape that makes them real: a
// capability is spent exactly once, and every box refusal is answered with
// box's own status and code rather than a registry-shaped guess.

// --- 1. an expired receipt is refused ------------------------------------
//
// Box answers its capability_expired renderer (410, code
// capability_expired). The exchange passes it through unchanged, so the
// operator hears the same refusal at this door that they would have heard at
// box's. And nothing was minted: a refusal must not reach the authority at all.
func TestAnExpiredCapabilityIsRefusedWithBoxsOwnRefusal(t *testing.T) {
	exchange, _, github := wireExchange(t, nil, boxRefusing(t, http.StatusGone,
		"capability_expired", "capability has expired"))

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusGone {
		t.Errorf("status: got %d, want 410", refusal.Status)
	}
	if refusal.Code != "capability_expired" {
		t.Errorf("code: got %q, want capability_expired", refusal.Code)
	}
	assertNoGitHub(t, github, "an expired capability must not mint a credential")
}

// --- 2. a receipt for another box is refused ------------------------------
func TestACapabilityBoundToAnotherBoxIsRefused(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, boxRefusing(t, http.StatusForbidden,
		"capability_wrong_box", "capability is bound to a different box"))

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusForbidden || refusal.Code != "capability_wrong_box" {
		t.Errorf("got %d %s, want 403 capability_wrong_box", refusal.Status, refusal.Code)
	}
}

// The synthetic case: box redeems (200) but renders a receipt naming a
// different box. The exchange refuses on its own re-check, even though box
// said yes — belt and braces over box's own binding.
func TestAReceiptForAnotherBoxIsRefusedLocallyEvenIfBoxSaidYes(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(boxReceipt(ExchangePurpose, testOtherBoxID, "")))
	})

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusForbidden || refusal.Code != "capability_wrong_box" {
		t.Errorf("got %d %s, want 403 capability_wrong_box", refusal.Status, refusal.Code)
	}
}

// A receipt for another purpose is refused locally on the same re-check, with
// the same status box uses for it.
func TestAReceiptForAnotherPurposeIsRefusedLocally(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(boxReceipt("box.enroll", testBoxID, "")))
	})

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusForbidden || refusal.Code != "capability_wrong_purpose" {
		t.Errorf("got %d %s, want 403 capability_wrong_purpose", refusal.Status, refusal.Code)
	}
}

// --- 3. the credential it returns is pull-only and expires ----------------
func TestARedeemedCapabilityBuysAShortLivedPullOnlyCredential(t *testing.T) {
	expiresAt := time.Now().UTC().Add(time.Hour)
	exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
		return githubAnswer{status: http.StatusCreated, body: installationTokenBody(expiresAt, nil)}
	}, nil)

	credential, err := mustCall(t, exchange, testCapability, testBoxID)
	if err != nil {
		t.Fatalf("the exchange should have minted: %v", err)
	}

	if !credential.PullOnly() {
		t.Error("the minted credential must be pull-only")
	}
	if credential.ExpiresAt().After(expiresAt.Add(time.Second)) {
		t.Error("the credential must not outlive GitHub's own expiry")
	}
	if got := credential.SecondsRemaining(time.Now()); got < 3595 || got > 3600 {
		t.Errorf("seconds_remaining: got %d, want about 3600", got)
	}
	if credential.Expired(time.Now()) {
		t.Error("the credential must be alive when it is handed over")
	}
	if credential.Registry() != "ghcr.io" {
		t.Errorf("registry: got %q, want ghcr.io", credential.Registry())
	}

	// The dockerconfigjson is the real, decodable, encoded thing — the value
	// that goes into the Secret.
	decoded := decodeDockerConfig(t, credential.EncodedDockerConfigJSON())
	entry, ok := decoded["auths"].(map[string]any)["ghcr.io"].(map[string]any)
	if !ok {
		t.Fatalf("decoded credential has no ghcr.io entry: %s", decoded["auths"])
	}
	if entry["username"] != MintedUsername {
		t.Errorf("username: got %v, want %s", entry["username"], MintedUsername)
	}
	if entry["password"] != testInstallationToken {
		t.Errorf("password: got %v, want the installation token", entry["password"])
	}
	if entry["email"] != "" {
		t.Errorf("email: got %v, want empty", entry["email"])
	}
}

func decodeDockerConfig(t *testing.T, encoded string) map[string]any {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("the encoded credential is not base64: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("the decoded credential is not JSON: %v", err)
	}
	return decoded
}

func TestACredentialThatCanPushIsRefused(t *testing.T) {
	// read:packages AND contents:write is not a pull-only credential. The
	// exchange refuses rather than handing over something that could push.
	exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
		return githubAnswer{status: http.StatusCreated,
			body: installationTokenBody(time.Time{}, map[string]string{"packages": "read", "contents": "write"})}
	}, nil)

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusBadGateway || refusal.Code != "credential_not_pull_only" {
		t.Errorf("got %d %s, want 502 credential_not_pull_only", refusal.Status, refusal.Code)
	}
}

func TestACredentialThatIsAlreadyExpiredIsRefused(t *testing.T) {
	exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
		return githubAnswer{status: http.StatusCreated, body: installationTokenBody(time.Now().UTC().Add(-time.Minute), nil)}
	}, nil)

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusBadGateway || refusal.Code != "credential_expired" {
		t.Errorf("got %d %s, want 502 credential_expired", refusal.Status, refusal.Code)
	}
}

func TestACredentialWithAlmostNoLifetimeLeftIsRefused(t *testing.T) {
	// 30 seconds is enough to start a pull and not enough to finish one.
	exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
		return githubAnswer{status: http.StatusCreated, body: installationTokenBody(time.Now().UTC().Add(30*time.Second), nil)}
	}, nil)

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusServiceUnavailable || refusal.Code != "credential_too_short_lived" {
		t.Errorf("got %d %s, want 503 credential_too_short_lived", refusal.Status, refusal.Code)
	}
}

// --- the capability is spent exactly once, and only when it is good -------
func TestTheCapabilityIsPresentedToBoxOnceNamingPurposeAndBox(t *testing.T) {
	exchange, box, _ := defaultExchange(t)

	if _, err := mustCall(t, exchange, testCapability, testBoxID); err != nil {
		t.Fatalf("the exchange should have minted: %v", err)
	}

	if box.count() != 1 {
		t.Fatalf("box saw %d requests, want exactly 1", box.count())
	}
	request := box.first()
	if request.Path != "/v1/capabilities/redeem" {
		t.Errorf("path: got %q, want /v1/capabilities/redeem", request.Path)
	}
	if request.Method != http.MethodPost {
		t.Errorf("method: got %q, want POST", request.Method)
	}
	if request.Authorization != "Bearer "+testCapability {
		t.Errorf("authorization: got %q, want the capability as a bearer", request.Authorization)
	}
	if request.ContentType != "application/json" {
		t.Errorf("content-type: got %q, want application/json", request.ContentType)
	}
	body := parseBody(t, request.Body)
	if body["purpose"] != ExchangePurpose {
		t.Errorf("purpose: got %v, want %s", body["purpose"], ExchangePurpose)
	}
	if body["box_id"] != testBoxID {
		t.Errorf("box_id: got %v, want %s", body["box_id"], testBoxID)
	}
	if body["token"] != testCapability {
		t.Errorf("token: got %v, want the capability in the redeem body", body["token"])
	}
}

func TestARefusalNeverReachesTheAuthority(t *testing.T) {
	refusals := []struct {
		status int
		code   string
	}{
		{http.StatusGone, "capability_expired"},
		{http.StatusForbidden, "capability_wrong_box"},
		{http.StatusForbidden, "capability_wrong_purpose"},
		{http.StatusConflict, "capability_redeemed"},
		{http.StatusNotFound, "not_found"},
	}
	for _, refusal := range refusals {
		t.Run(refusal.code, func(t *testing.T) {
			exchange, _, github := wireExchange(t, nil,
				boxRefusing(t, refusal.status, refusal.code, "no"))

			callExpectingRefusal(t, exchange, testCapability, testBoxID)

			assertNoGitHub(t, github,
				"a "+refusal.code+" refusal from box must not mint a credential")
		})
	}
}

// --- the request is shaped before any network call ------------------------
//
// The installer's old failure mode: an operator following an older runbook
// pastes a dockerconfigjson where a capability belongs. That must never reach
// box as an opaque bearer.
func TestAPastedDockerConfigJSONIsRefusedBeforeTheNetwork(t *testing.T) {
	pasted := base64.StdEncoding.EncodeToString(
		[]byte(`{"auths":{"ghcr.io":{"auth":"ZmFrZQ=="}}}`))
	exchange, box, github := defaultExchange(t)

	refusal := callExpectingRefusal(t, exchange, pasted, testBoxID)

	if refusal.Status != http.StatusBadRequest || refusal.Code != "capability_malformed" {
		t.Errorf("got %d %s, want 400 capability_malformed", refusal.Status, refusal.Code)
	}
	if !strings.Contains(refusal.Message, "dockerconfigjson") {
		t.Errorf("the refusal should name what was pasted: %q", refusal.Message)
	}
	if box.count() != 0 {
		t.Errorf("box saw %d request(s), the pasted value must not reach it", box.count())
	}
	assertNoGitHub(t, github, "a pasted credential must not mint anything")
}

func TestACapabilityAndABoxIDAreBothRequired(t *testing.T) {
	exchange, _, _ := defaultExchange(t)

	if refusal := callExpectingRefusal(t, exchange, "", testBoxID); refusal.Code != "capability_required" {
		t.Errorf("no capability: got %s, want capability_required", refusal.Code)
	}
	if refusal := callExpectingRefusal(t, exchange, "   ", testBoxID); refusal.Code != "capability_required" {
		t.Errorf("blank capability: got %s, want capability_required", refusal.Code)
	}
	if refusal := callExpectingRefusal(t, exchange, testCapability, ""); refusal.Code != "box_id_required" {
		t.Errorf("no box_id: got %s, want box_id_required", refusal.Code)
	}
	if refusal := callExpectingRefusal(t, exchange, testCapability, "not-a-uuid"); refusal.Code != "box_id_malformed" {
		t.Errorf("malformed box_id: got %s, want box_id_malformed", refusal.Code)
	}
	// A capability that is not the minted shape is malformed, not missing.
	if refusal := callExpectingRefusal(t, exchange, "cap_xyz", testBoxID); refusal.Code != "capability_malformed" {
		t.Errorf("short capability: got %s, want capability_malformed", refusal.Code)
	}
}

// --- the box being unreachable is a refusal, not a crash ------------------
func TestAnUnreachableBoxIsARefusal(t *testing.T) {
	boxRec := &recorder{}
	// A server that was listening and then closed: the connection is refused.
	closed := newBoxStub(t, boxRec, nil)
	url := closed.URL
	closed.Close()

	authority := readOnlyAuthority(t, "https://api.github.invalid")
	exchange := NewExchange(NewBox(url), authority, DefaultRegistryHost)

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusBadGateway || refusal.Code != "box_unreachable" {
		t.Errorf("got %d %s, want 502 box_unreachable", refusal.Status, refusal.Code)
	}
}

// A box that answers something this client cannot read is a refusal, not a
// crash.
func TestABoxAnsweringGarbageIsARefusal(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("<html>not box</html>"))
	})

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusBadGateway || refusal.Code != "box_unreachable" {
		t.Errorf("got %d %s, want 502 box_unreachable", refusal.Status, refusal.Code)
	}
}

// A receipt box did not render is an upstream defect, named as one.
func TestAReceiptWithNoCapabilityIsRefused(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"something_else":true}`))
	})

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusBadGateway || refusal.Code != "bad_upstream" {
		t.Errorf("got %d %s, want 502 bad_upstream", refusal.Status, refusal.Code)
	}
}

func TestAReceiptWithNoExpiryIsRefused(t *testing.T) {
	exchange, _, _ := wireExchange(t, nil, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(boxReceipt(ExchangePurpose, testBoxID, "not-a-timestamp")))
	})

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Status != http.StatusBadGateway || refusal.Code != "bad_upstream" {
		t.Errorf("got %d %s, want 502 bad_upstream", refusal.Status, refusal.Code)
	}
}

// --- the authority --------------------------------------------------------
//
// The assertion is real: the stub verifies RS256 against the public half of the
// key the service holds, and the claims it carries are GitHub's own.
func TestTheAppAssertionCarriesGitHubsClaims(t *testing.T) {
	var seen jwt.MapClaims
	server := newGitHubStub(t, &recorder{}, func(claims jwt.MapClaims) githubAnswer {
		seen = claims
		return githubAnswer{status: http.StatusCreated, body: installationTokenBody(time.Time{}, nil)}
	})
	authority := readOnlyAuthority(t, server.URL)

	if _, err := authority.InstallationToken(context.Background()); err != nil {
		t.Fatalf("the authority should have minted: %v", err)
	}
	if seen == nil {
		t.Fatal("the stub never verified an assertion — the JWT did not arrive")
	}
	if seen["iss"] != "123456" {
		t.Errorf("iss: got %v, want 123456", seen["iss"])
	}
	issuedAt, exp, err := numericClaim(seen, "iat", "exp")
	if err != nil {
		t.Fatalf("the assertion carries no usable iat/exp: %v", err)
	}
	if lifetime := exp - (time.Now().Unix() + int64(AppJWTTTL/time.Second)); lifetime < -2 || lifetime > 2 {
		t.Errorf("exp: %ds from now, want about %ds (%ds)", exp, time.Now().Unix()+int64(AppJWTTTL/time.Second), lifetime)
	}
	if skew := time.Now().Unix() - issuedAt; skew < 0 || skew > int64((AppJWTIssuedAtSkew+2*time.Second)/time.Second) {
		t.Errorf("iat: got %d, which is %ds from now — the assertion should be minted %s in the past",
			issuedAt, skew, AppJWTIssuedAtSkew)
	}
}

func TestTheAuthorityAsksGitHubOverTheDocumentedRoute(t *testing.T) {
	github := &recorder{}
	server := newGitHubStub(t, github, nil)
	authority := readOnlyAuthority(t, server.URL)

	if _, err := authority.InstallationToken(context.Background()); err != nil {
		t.Fatalf("the authority should have minted: %v", err)
	}
	if github.count() != 1 {
		t.Fatalf("github saw %d requests, want exactly 1", github.count())
	}
	request := github.first()
	if want := "/app/installations/987654/access_tokens"; request.Path != want {
		t.Errorf("path: got %q, want %q", request.Path, want)
	}
	if !strings.HasPrefix(request.Authorization, "Bearer ") {
		t.Errorf("authorization: got %q, want a bearer assertion", request.Authorization)
	}
	if request.Accept != "application/vnd.github+json" {
		t.Errorf("accept: got %q, want application/vnd.github+json", request.Accept)
	}
	if request.APIVersion != "2022-11-28" {
		t.Errorf("api version: got %q, want 2022-11-28", request.APIVersion)
	}
}

func TestAnAuthorityThatIsMisconfiguredAnswersAtRequestTimeRatherThanDying(t *testing.T) {
	for _, tc := range []struct{ name, appID, key, installationID, want string }{
		{"no app id", "", testKeyPEM(), "987654", "REGISTRY_GITHUB_APP_ID is not set"},
		{"no key", "123456", "", "987654", "REGISTRY_GITHUB_APP_KEY is not set"},
		{"no installation id", "123456", testKeyPEM(), "", "REGISTRY_GITHUB_INSTALLATION_ID is not set"},
		{"not a pem", "123456", "not a key", "987654", "not an RSA private key"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := NewAuthority(tc.key, tc.appID, tc.installationID, "")
			if err == nil {
				t.Fatalf("expected a misconfigured authority to be refused")
			}
			var authorityErr *AuthorityError
			if !errors.As(err, &authorityErr) {
				t.Fatalf("expected an *AuthorityError, got %T", err)
			}
			if !authorityErr.Misconfigured() {
				t.Errorf("kind: got %s, want misconfigured", authorityErr.Kind)
			}
			if !strings.Contains(authorityErr.Error(), tc.want) {
				t.Errorf("message: got %q, want it to name %q", authorityErr.Error(), tc.want)
			}
		})
	}
}

func TestAnUnavailableAuthorityIsARefusalNotACrash(t *testing.T) {
	exchange, _, github := defaultExchange(t)
	exchange.authority = unavailableAuthority{&AuthorityError{
		Kind: "misconfigured", Message: "REGISTRY_GITHUB_APP_ID is not set"}}

	_, err := mustCall(t, exchange, testCapability, testBoxID)
	if err == nil {
		t.Fatal("a misconfigured authority must refuse")
	}
	var isRefusal *Refusal
	if errors.As(err, &isRefusal) {
		t.Fatal("an authority failure is not an exchange refusal: the HTTP surface answers it")
	}
	var authorityErr *AuthorityError
	if !errors.As(err, &authorityErr) {
		t.Fatalf("expected an *AuthorityError, got %T", err)
	}
	assertNoGitHub(t, github, "a misconfigured authority must not dial GitHub")
}

func TestAGitHubFailureIsAnAuthorityErrorCarryingNoSecret(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"unauthorized", http.StatusUnauthorized, `{"message":"Bad credentials"}`},
		{"server error", http.StatusInternalServerError, `{"message":"boom"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
				return githubAnswer{status: tc.status, body: tc.body}
			}, nil)

			_, err := mustCall(t, exchange, testCapability, testBoxID)
			var authorityErr *AuthorityError
			if !errors.As(err, &authorityErr) {
				t.Fatalf("expected an *AuthorityError, got %T: %v", err, err)
			}
			if !strings.Contains(authorityErr.Error(), "GitHub answered") {
				t.Errorf("message names the status and nothing else: %q", authorityErr.Error())
			}
			// The response body is never carried into the error: an error
			// message is a log line waiting to happen.
			if strings.Contains(authorityErr.Error(), tc.body) {
				t.Errorf("the upstream body reached the error message: %q", authorityErr.Error())
			}
		})
	}
}

func TestAGitHubAnswerMissingItsTokenIsAnAuthorityError(t *testing.T) {
	for _, tc := range []struct{ name, body, want string }{
		{"no token", `{"expires_at":"2030-01-01T00:00:00Z"}`, "missing token"},
		{"no expiry", `{"token":"ghs_x"}`, "missing expires_at"},
		{"unparseable expiry", `{"token":"ghs_x","expires_at":"whenever"}`, "unparseable expires_at"},
		{"not json", `nonsense`, "not JSON"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
				return githubAnswer{status: http.StatusCreated, body: tc.body}
			}, nil)

			_, err := mustCall(t, exchange, testCapability, testBoxID)
			var authorityErr *AuthorityError
			if !errors.As(err, &authorityErr) {
				t.Fatalf("expected an *AuthorityError, got %T: %v", err, err)
			}
			if !strings.Contains(authorityErr.Error(), tc.want) {
				t.Errorf("message: got %q, want it to name %q", authorityErr.Error(), tc.want)
			}
			if strings.Contains(authorityErr.Error(), "ghs_x") {
				t.Errorf("a token reached an error message: %q", authorityErr.Error())
			}
		})
	}
}

func TestAGitHubAnswerWithNoPermissionsIsRefusedAsNotPullOnly(t *testing.T) {
	exchange, _, _ := wireExchange(t, func(jwt.MapClaims) githubAnswer {
		return githubAnswer{status: http.StatusCreated, body: `{"token":"ghs_x","expires_at":"` +
			time.Now().UTC().Add(time.Hour).Format(time.RFC3339) + `","permissions":{}}`}
	}, nil)

	refusal := callExpectingRefusal(t, exchange, testCapability, testBoxID)

	if refusal.Code != "credential_not_pull_only" {
		t.Errorf("got %s, want credential_not_pull_only", refusal.Code)
	}
}

var errNotFound = fmt.Errorf("claim not found")

func numericClaim(claims jwt.MapClaims, names ...string) (int64, int64, error) {
	values := make([]int64, 0, len(names))
	for _, name := range names {
		raw, ok := claims[name]
		if !ok {
			return 0, 0, errNotFound
		}
		switch typed := raw.(type) {
		case float64:
			values = append(values, int64(typed))
		case json.Number:
			value, err := typed.Int64()
			if err != nil {
				return 0, 0, err
			}
			values = append(values, value)
		default:
			return 0, 0, errNotFound
		}
	}
	return values[0], values[1], nil
}
