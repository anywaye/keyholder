package registry

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// ExchangePurpose is the purpose the capability is spent FOR. It is named at
// box so box can refuse a capability minted for anything else, and it is
// re-checked here against the receipt box answers with.
const ExchangePurpose = "registry.pull"

// MinimumSeconds is the floor an installation token must still have on it.
// GitHub mints at an hour; a token that arrives with less than this left is a
// credential that dies mid-pull, and the honest answer is a refusal and a
// retry, not a Secret that expires while pods are starting.
const MinimumSeconds = 60

// CapabilityShape is what a minted capability looks like. A dockerconfigjson
// pasted where a capability belongs fails this, and is refused before any
// network call is made: the installer's old failure mode was an operator
// following an older runbook, and that value must never reach box as an opaque
// bearer.
var capabilityShape = regexp.MustCompile(`\Acap_[0-9a-f]{64}\z`)

// BoxIDShape is a UUID, case-insensitive: box binds a capability to exactly one
// box and this is the id of the box it is being spent for.
var boxIDShape = regexp.MustCompile(`\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z`)

// Refusal is a refusal the exchange itself makes: a status, an error code, and a
// message an operator can read. It is the only error shape the HTTP surface
// turns into a response.
type Refusal struct {
	Status  int
	Code    string
	Message string
}

func (r *Refusal) Error() string { return r.Message }

// Exchange is the registry-credential exchange.
//
// The path, in order:
//
//  1. the request is shaped BEFORE any network call. A pasted
//     dockerconfigjson never reaches box as an opaque bearer;
//  2. the capability is spent at box, through Box.Redeem, naming the purpose
//     and the box it is being redeemed FOR. Box refuses an expired,
//     already-redeemed, wrong-purpose or wrong-box capability, and every one of
//     those refusals is passed through with box's own status and code;
//  3. the receipt is re-checked HERE against the box that asked. Box already
//     enforces this, and the local re-check is what makes the guarantee local:
//     a box_id in the receipt that is not the box that asked is a refusal, not
//     a subtlety;
//  4. an installation token is minted from the App key, and it must arrive
//     pull-only and still alive or the exchange refuses rather than handing
//     over something that will fail at image-pull time in a voice nobody can
//     attribute;
//  5. the dockerconfigjson is returned. It is never logged, never stored, and
//     never written anywhere by this service.
type Exchange struct {
	box       *Box
	authority TokenMinter
	registry  string
	now       func() time.Time
}

// NewExchange wires the exchange to box's door and the registry authority.
//
// `now` is injected in the suite so an expiry refusal can be proven without
// sleeping for an hour. Production calls NowClock.
func NewExchange(box *Box, authority TokenMinter, registryHost string) *Exchange {
	return &Exchange{
		box:       box,
		authority: authority,
		registry:  strings.TrimSpace(registryHost),
		now:       time.Now,
	}
}

// NowClock is the production clock.
func NowClock() time.Time { return time.Now() }

// Clock overrides the clock. It is exported for the suite and for nothing else.
func (e *Exchange) Clock(now func() time.Time) { e.now = now }

// Call trades a capability for a credential.
//
// capability is the raw bearer token; boxID names the box it is being spent
// for. Both are required and both are shaped before the network.
func (e *Exchange) Call(ctx context.Context, capability, boxID string) (*Minted, error) {
	now := e.now()

	if strings.TrimSpace(capability) == "" {
		return nil, &Refusal{Status: 400, Code: "capability_required",
			Message: "a registry.pull capability is required"}
	}
	if !capabilityShape.MatchString(capability) {
		return nil, &Refusal{Status: 400, Code: "capability_malformed",
			Message: "that is not a minted capability — a dockerconfigjson belongs in the OLD runbook: it is redeemed, not pasted"}
	}
	if strings.TrimSpace(boxID) == "" {
		return nil, &Refusal{Status: 400, Code: "box_id_required",
			Message: "box_id is required: a registry.pull capability is bound to exactly one box"}
	}
	if !boxIDShape.MatchString(boxID) {
		return nil, &Refusal{Status: 400, Code: "box_id_malformed", Message: "box_id must be a UUID"}
	}

	receipt, err := e.spend(ctx, capability, boxID)
	if err != nil {
		return nil, err
	}

	// The receipt is re-checked against the box that asked. This is belt and
	// braces over box's own binding, and it is the half that makes the
	// guarantee true even if a caller ever reached the exchange by another
	// route.
	if receipt.Purpose != ExchangePurpose {
		return nil, &Refusal{Status: 403, Code: "capability_wrong_purpose",
			Message: fmt.Sprintf("box's receipt is for purpose '%s', not %s", receipt.Purpose, ExchangePurpose)}
	}
	if receipt.BoxID != boxID {
		return nil, &Refusal{Status: 403, Code: "capability_wrong_box",
			Message: "box's receipt is for another box, not this one"}
	}
	// A receipt with no expiry is a shape this exchange does not consume: box
	// always renders one, and the credential's own TTL is what actually bounds
	// the exchange, so a missing one is a defect rather than a bypass.
	if receipt.ExpiresAt == "" {
		return nil, &Refusal{Status: 502, Code: "bad_upstream",
			Message: "box's receipt carries no expires_at"}
	}
	if _, err := time.Parse(time.RFC3339, receipt.ExpiresAt); err != nil {
		return nil, &Refusal{Status: 502, Code: "bad_upstream",
			Message: "box's receipt carries an unparseable expires_at"}
	}

	minted, err := e.authority.InstallationToken(ctx)
	if err != nil {
		// Returned UNWRAPPED, exactly as the Ruby original did: the HTTP
		// surface maps an authority failure to its own refusal, because a
		// misconfigured authority and a GitHub outage are the same answer to
		// the caller and neither is the caller's fault.
		return nil, err
	}

	// The registry the credential is minted for is this service's, not
	// GitHub's, so the credential is rebuilt with it now that the token exists.
	perRequest := &Minted{
		token:       minted.token,
		expiresAt:   minted.expiresAt,
		permissions: minted.permissions,
		registry:    e.registryHost(),
	}

	return guardCredential(perRequest, now)
}

// registryHost is the host the credential is minted for, defaulting to ghcr.io
// when the environment does not name one.
func (e *Exchange) registryHost() string {
	if e.registry == "" {
		return DefaultRegistryHost
	}
	return e.registry
}

// spend spends the capability at box, translating box's own refusals out
// unchanged and an unreachable box into 502 box_unreachable.
func (e *Exchange) spend(ctx context.Context, capability, boxID string) (Receipt, error) {
	// Per-call client carrying the capability, mirroring the Ruby original:
	// a Box that holds a token is a Box that can spend it twice.
	box := &Box{BaseURL: e.box.BaseURL, Client: e.box.Client}
	receipt, err := box.Redeem(ctx, capability, boxID)
	switch {
	case err == nil:
		return receipt, nil
	case isBoxRefusal(err):
		var refusal *BoxRefusal
		errors.As(err, &refusal)
		return receipt, &Refusal{Status: refusal.Status, Code: refusal.Code, Message: refusal.Message}
	case isUnreachable(err):
		var unreachable *BoxUnreachable
		errors.As(err, &unreachable)
		return receipt, &Refusal{Status: 502, Code: "box_unreachable", Message: unreachable.Error()}
	default:
		return receipt, &Refusal{Status: 502, Code: "bad_upstream", Message: err.Error()}
	}
}

func isBoxRefusal(err error) bool {
	var refusal *BoxRefusal
	return errors.As(err, &refusal)
}

func isUnreachable(err error) bool {
	var unreachable *BoxUnreachable
	return errors.As(err, &unreachable)
}

// guardCredential refuses a credential that is not pull-only or is already
// dead. Both are the failure the installer's preflight exists to prevent: write
// the Secret, schedule the pods, and fail at image-pull time in a voice nobody
// can attribute.
//
// The order is the Ruby original's and it is load-bearing: expired before
// unusable before too-short-lived before not-pull-only, so the answer to a
// given credential is the same answer in both implementations.
func guardCredential(credential *Minted, now time.Time) (*Minted, error) {
	if credential.Expired(now) {
		return nil, &Refusal{Status: 502, Code: "credential_expired",
			Message: "the minted credential is already expired — nothing to hand over"}
	}
	if !credential.Usable(now) {
		return nil, &Refusal{Status: 502, Code: "credential_unusable",
			Message: "the minted credential carries no usable lifetime"}
	}
	if credential.SecondsRemaining(now) < MinimumSeconds {
		return nil, &Refusal{Status: 503, Code: "credential_too_short_lived",
			Message: fmt.Sprintf("the minted credential has less than %ds of life left — retry the exchange", MinimumSeconds)}
	}
	if !credential.PullOnly() {
		return nil, &Refusal{Status: 502, Code: "credential_not_pull_only",
			Message: "the minted credential is not pull-only — the installation's permissions must be read:packages and nothing else"}
	}
	return credential, nil
}
