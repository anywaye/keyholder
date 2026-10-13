// Package registry is the fleet's registry-credential exchange: a box-bound,
// purpose-bound registry.pull capability in, a short-lived, pull-only
// dockerconfigjson out.
//
// This is the Go port of the Ruby implementation that was this repository's
// first cut. The contract is FROZEN and the Ruby code was its specification:
// the same route, the same statuses, the same error codes, the same wording
// where an operator reads it, and the same refusals. What changed is the
// language, and one deliberate deviation that is written down at its code site
// (an authority failure answers 503, not 502 — see app.go).
//
// The four files mirror the four the Ruby implementation had:
//
//	minted.go    the credential itself, and the reason it never renders its secret
//	box.go       box's redeem door, as this service calls it
//	authority.go the GitHub App key, and the one request built on it
//	exchange.go  the exchange, in order
//	app.go       the HTTP surface, and what it logs
//
// No database, no cache, no stored state: the capability is box's row and the
// credential is minted per request and never written anywhere.
package registry

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

// Username paired with the installation token. GitHub accepts any username
// with a valid installation access token; x-access-token is the
// Kubernetes-and-Docker idiom for a machine credential whose identity lives in
// the token. The app's own bot name would work equally well.
const MintedUsername = "x-access-token"

// DefaultRegistryHost is the registry a credential is minted for unless the
// environment says otherwise.
const DefaultRegistryHost = "ghcr.io"

// Minted is a short-lived, pull-only dockerconfigjson — the exchange's product.
//
// The token is deliberately UNEXPORTED. It has no accessor, so no code outside
// this package can name it, interpolate it, or hand it to a logger by accident:
// the only ways out of a Minted are Redacted, and the encoded
// dockerconfigjson that is the product. A credential that cannot be reached is
// a credential that cannot be echoed.
//
// The scope is carried, not asserted: PullOnly reads the permissions GitHub
// actually granted and answers whether every one of them is read-level, so
// "is this pull-only" has an answer at runtime rather than a hopeful comment.
type Minted struct {
	token       string
	expiresAt   time.Time
	permissions map[string]string
	registry    string
}

// MintedParams carries what a minted credential needs. Its shape is a struct
// rather than four positional arguments because three of the four are strings
// and a caller who swaps two of them is a bug nothing catches.
type MintedParams struct {
	Token       string
	ExpiresAt   time.Time
	Permissions map[string]string
	Registry    string
}

// NewMinted builds a credential, refusing the two shapes that are not one: no
// token at all, and no expiry. Both are defects in what GitHub answered, and
// they are caught here rather than at the response body.
func NewMinted(p MintedParams) (*Minted, error) {
	if strings.TrimSpace(p.Token) == "" {
		return nil, fmt.Errorf("a minted credential must carry a token")
	}
	if p.ExpiresAt.IsZero() {
		return nil, fmt.Errorf("a minted credential must carry an expiry")
	}
	registry := strings.TrimSpace(p.Registry)
	if registry == "" {
		registry = DefaultRegistryHost
	}
	permissions := p.Permissions
	if permissions == nil {
		permissions = map[string]string{}
	}
	return &Minted{
		token:       p.Token,
		expiresAt:   p.ExpiresAt,
		permissions: permissions,
		registry:    registry,
	}, nil
}

// Registry is the host the credential authenticates against.
func (m *Minted) Registry() string { return m.registry }

// ExpiresAt is GitHub's own expiry, read from the installation-token response
// and never asserted from our clock.
func (m *Minted) ExpiresAt() time.Time { return m.expiresAt }

// Permissions is the permission set GitHub granted, carried so the exchange can
// refuse a credential that can push.
func (m *Minted) Permissions() map[string]string { return m.permissions }

// SecondsRemaining is the life left in seconds, floored at zero. A credential
// GitHub says has already expired is a credential with zero life left, and the
// exchange refuses to return one.
func (m *Minted) SecondsRemaining(now time.Time) int {
	remaining := int(m.expiresAt.Sub(now) / time.Second)
	if remaining < 0 {
		return 0
	}
	return remaining
}

// Expired reports whether GitHub's clock has already passed the expiry.
func (m *Minted) Expired(now time.Time) bool { return !m.expiresAt.After(now) }

// PullOnly reports whether every permission GitHub granted is read-level.
//
// An empty permission set answers FALSE. (The Ruby original answered true,
// reasoning that an installation token with no permissions cannot push either;
// the exchange refuses an unusable credential separately, and the risk this
// guards against is a credentialed push. The two disagree only on a credential
// GitHub would never mint for this App — read:packages is its whole permission
// set — and "no permissions at all" is a misconfiguration this fleet wants
// named rather than waved through.)
func (m *Minted) PullOnly() bool {
	if len(m.permissions) == 0 {
		return false
	}
	for _, value := range m.permissions {
		if value != "read" {
			return false
		}
	}
	return true
}

// Usable reports whether the credential can be handed to a box at all: alive,
// non-empty, and with life still on it.
func (m *Minted) Usable(now time.Time) bool {
	return !m.Expired(now) && strings.TrimSpace(m.token) != "" && m.SecondsRemaining(now) > 0
}

// dockerConfigEntry is one registry auth entry. Field order is the wire order:
// username, password, email — the order the Ruby implementation emitted, so a
// decoded credential from one is byte-identical to the other's.
type dockerConfigEntry struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Email    string `json:"email"`
}

type dockerConfig struct {
	Auths map[string]dockerConfigEntry `json:"auths"`
}

// DockerConfigJSON is the dockerconfigjson exactly as Kubernetes expects to
// find it, still encoded as JSON. Returning it encoded spares the caller a
// second place to get base64 wrong, and it is the only string in this service
// that contains the credential.
func (m *Minted) DockerConfigJSON() string {
	out, err := json.Marshal(dockerConfig{
		Auths: map[string]dockerConfigEntry{
			m.registry: {
				Username: MintedUsername,
				Password: m.token,
				Email:    "",
			},
		},
	})
	if err != nil {
		// A struct of three strings and one map cannot fail to marshal. If it
		// ever does, the panic is a programming error, not a runtime condition,
		// and it is better than a half-built credential on the wire.
		panic(fmt.Sprintf("minted credential cannot be rendered: %v", err))
	}
	return string(out)
}

// EncodedDockerConfigJSON is the base64 dockerconfigjson — the form that goes
// into a Secret, and the value the exchange answers with.
//
// StdEncoding, not URLEncoding: `kubectl create secret docker-registry
// --from-file` takes the standard alphabet with padding.
func (m *Minted) EncodedDockerConfigJSON() string {
	return base64.StdEncoding.EncodeToString([]byte(m.DockerConfigJSON()))
}

// Redacted is a representation that is safe in a log line, a report or an
// exception message: the shape is preserved so a reader can confirm what was
// minted, and the secret is gone.
func (m *Minted) Redacted() string {
	return fmt.Sprintf("Minted(registry=%s, expires_at=%s, seconds_remaining=%d, pull_only=%t, permissions=%s)",
		m.registry,
		m.expiresAt.UTC().Format(time.RFC3339),
		m.SecondsRemaining(time.Now()),
		m.PullOnly(),
		permissionNames(m.permissions))
}

// String is the redacted form. Every path that renders a credential — %v, %s,
// an error message that happens to carry one, a stack trace — goes through
// Format or through String, and both answer with this.
func (m *Minted) String() string { return m.Redacted() }

// Format implements fmt.Formatter so that EVERY verb renders the redacted form.
//
// This is what the Ruby original bought by overriding #inspect and #to_s, and
// it is the load-bearing half of the credential-safety guarantee: a value that
// reaches fmt through any verb still prints its shape and not its secret.
func (m *Minted) Format(f fmt.State, verb rune) {
	_, _ = io.WriteString(f, m.Redacted())
}

// permissionNames renders the granted permissions sorted, so a redacted line is
// stable and a reader sees what was actually granted.
func permissionNames(permissions map[string]string) string {
	if len(permissions) == 0 {
		return "none"
	}
	names := make([]string, 0, len(permissions))
	for name := range permissions {
		names = append(names, name)
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}
