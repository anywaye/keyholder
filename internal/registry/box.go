package registry

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Box is box's redeem door, as this service calls it.
//
// The capability is spent HERE and not by the caller. The installer used to
// redeem at box and then have nowhere to go with the receipt; the exchange
// spends the capability itself, through this client, exactly once. box's
// Capability.redeem! enforces the single-use claim atomically, the purpose
// binding and the box binding server-side, so this service never has to trust
// the caller to have checked. That is the whole point of the standalone
// service: box stays the one door that spends capabilities, and this service is
// the one process that holds registry material. Neither holds the other's
// secret.
//
// A refusal is a refusal. Every box refusal (4xx/5xx) becomes a BoxRefusal
// carrying box's own status and error code, and the exchange maps it out
// unchanged, so the operator hears "this capability is expired" from the same
// vocabulary the installer already speaks, rather than a registry-shaped guess
// about why.

// BoxRefusal is box's own refusal: its status, its error code, its message. It
// is passed through by the exchange untouched.
type BoxRefusal struct {
	Status  int
	Code    string
	Message string
}

func (r *BoxRefusal) Error() string {
	return fmt.Sprintf("box refused the capability (%d %s): %s", r.Status, r.Code, r.Message)
}

// BoxUnreachable is box not answering: no connection, no parse, no HTTP answer
// this client can read. The exchange turns it into 502 box_unreachable — a
// refusal, never a crash.
type BoxUnreachable struct{ Cause error }

func (u *BoxUnreachable) Error() string { return fmt.Sprintf("box is not reachable: %v", u.Cause) }
func (u *BoxUnreachable) Unwrap() error { return u.Cause }

// Box is the redeem client. BaseURL is box's origin (REGISTRY_BOX_URL) and
// Client is the HTTP client every redeem travels over; the capability is NOT a
// field, because it is per request and a client that holds a token is a client
// that can spend it twice.
type Box struct {
	BaseURL string
	Client  *http.Client
}

// NewBox builds the client with the one timeout this service uses for box:
// ten seconds both ways, long enough for a slow control plane and short enough
// that a hung box does not hold a box's install open.
func NewBox(baseURL string) *Box {
	return &Box{
		BaseURL: strings.TrimSuffix(baseURL, "/"),
		Client:  &http.Client{Timeout: 10 * time.Second},
	}
}

// Receipt is what box renders for a successful redemption: its own capability
// row, purpose and all. It is re-checked locally against the box that asked
// before anything is minted.
type Receipt struct {
	Purpose   string `json:"purpose"`
	BoxID     string `json:"box_id"`
	AccountID string `json:"account_id"`
	ExpiresAt string `json:"expires_at"`
}

// Redeem spends a capability for a registry.pull on boxID, naming what the
// exchange is FOR.
//
// The capability travels as a bearer, the same way the installer used to
// present it, and the same reason box's own redeem route prefers the header: a
// token in a path lands in access logs.
func (b *Box) Redeem(ctx context.Context, capability, boxID string) (Receipt, error) {
	var receipt Receipt

	body, err := json.Marshal(redeemRequest{
		Token:   capability,
		Purpose: ExchangePurpose,
		BoxID:   boxID,
	})
	if err != nil {
		return receipt, &BoxUnreachable{Cause: fmt.Errorf("the redeem request cannot be built: %w", err)}
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, b.BaseURL+"/v1/capabilities/redeem", bytes.NewReader(body))
	if err != nil {
		return receipt, &BoxUnreachable{Cause: fmt.Errorf("the redeem request cannot be built: %w", err)}
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+capability)

	response, err := b.Client.Do(request)
	if err != nil {
		// A context deadline, a refused connection, a DNS failure and a reset
		// all land here, and none of them is the caller's fault.
		return receipt, &BoxUnreachable{Cause: err}
	}
	defer func() { _, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20)); _ = response.Body.Close() }()

	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return receipt, &BoxUnreachable{Cause: err}
	}

	switch {
	case response.StatusCode >= 200 && response.StatusCode < 300:
		// Answered. The receipt must be box's capability object, and a body
		// that is not that is an upstream defect rather than a refusal.
		var envelope redeemResponse
		if err := json.Unmarshal(payload, &envelope); err != nil {
			return receipt, &BoxUnreachable{Cause: fmt.Errorf("box's response is not JSON: %w", err)}
		}
		if envelope.Capability == nil {
			return receipt, &BoxRefusal{
				Status:  502,
				Code:    "bad_upstream",
				Message: "box's receipt carries no capability",
			}
		}
		return *envelope.Capability, nil

	case response.StatusCode >= 400:
		// box's own refusal, in box's own vocabulary. The status and the code
		// are carried out exactly as they arrived.
		code, message := refusalFrom(payload, response.StatusCode)
		return receipt, &BoxRefusal{Status: response.StatusCode, Code: code, Message: message}

	default:
		// A redirect or something stranger. Not something this client follows.
		return receipt, &BoxUnreachable{Cause: fmt.Errorf("box answered %d", response.StatusCode)}
	}
}

type redeemRequest struct {
	Token   string `json:"token"`
	Purpose string `json:"purpose"`
	BoxID   string `json:"box_id"`
}

type redeemResponse struct {
	Capability *Receipt `json:"capability"`
}

// refusalFrom reads box's `{error:{code,message}}` renderer, falling back to
// the shape the exchange uses when box's answer carries neither.
func refusalFrom(payload []byte, status int) (string, string) {
	code := "box_refused"
	message := fmt.Sprintf("box refused the capability (%d)", status)
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return code, message
	}
	if envelope.Error.Code != "" {
		code = envelope.Error.Code
	}
	if envelope.Error.Message != "" {
		message = envelope.Error.Message
	}
	return code, message
}
