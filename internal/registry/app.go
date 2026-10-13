package registry

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// App is the HTTP surface: one exchange route and a health check. Nothing else.
//
// The credential never touches a log. The response body is written once, by
// net/http, to the socket. This service's own logger records the request's
// OUTCOME — status, box, seconds of life, whether the credential was pull-only
// — and never the body. Minted renders as its redacted form through every
// fmt verb, so even a stack trace or an interpolated value that happens to
// carry the credential prints its shape and not its secret.
//
// Route shape, and the one that was rejected: POST /v1/registry-credentials
// with the capability in the Authorization bearer and box_id in the body. The
// sketched POST /v1/capabilities/:token/registry-credential puts the credential
// in a URL path — a path is logged by every proxy in front of a service, is
// kept in access logs, and ends up in crash reporters. A bearer header is how
// the fleet already presents a capability (box's redeem route), so the same
// idiom here is both the safer and the more consistent choice.
type App struct {
	exch   *Exchange
	logger io.Writer
}

// NewApp wires the HTTP surface to an exchange and a log sink.
func NewApp(exchange *Exchange, logger io.Writer) *App {
	return &App{exch: exchange, logger: logger}
}

// Handler is the service's whole routing table, on the standard library's
// ServeMux. There is no framework and no router package: three routes do not
// need one, and a router is a dependency that has to be kept current.
func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.health)
	mux.HandleFunc("GET /health", a.health)
	mux.HandleFunc("POST /v1/registry-credentials", a.exchange)
	mux.HandleFunc("/", a.notFound)
	return mux
}

// ServeHTTP lets an App be used directly as an http.Handler, for the suite and
// for any in-process embedding.
func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) { a.Handler().ServeHTTP(w, r) }

func (a *App) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// credentialResponse is the 200 body. Its field order is the wire order and
// matches the Ruby original's.
type credentialResponse struct {
	Registry         string `json:"registry"`
	ExpiresAt        string `json:"expires_at"`
	SecondsRemaining int    `json:"seconds_remaining"`
	DockerConfigJSON string `json:"dockerconfigjson"`
}

// exchange is the one route that matters.
func (a *App) exchange(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	capability := bearer(r)
	boxID, refuse := readBoxID(r)
	if refuse != nil {
		a.refusal(w, http.StatusBadRequest, "malformed_body", "the request body is not JSON")
		return
	}

	credential, err := a.exch.Call(ctx, capability, boxID)
	switch {
	case err == nil:
		// The credential's shape is what gets logged, never its value: the
		// redacted form carries everything an operator needs to confirm the
		// exchange worked, and nothing a registry could be handed.
		a.log(http.StatusOK, boxID, credential.Redacted())
		writeJSON(w, http.StatusOK, credentialResponse{
			Registry:         credential.Registry(),
			ExpiresAt:        credential.ExpiresAt().UTC().Format(time.RFC3339),
			SecondsRemaining: credential.SecondsRemaining(time.Now()),
			DockerConfigJSON: credential.EncodedDockerConfigJSON(),
		})

	default:
		var refusal *Refusal
		if errors.As(err, &refusal) {
			a.log(refusal.Status, boxID, refusal.Code+": "+refusal.Message)
			a.refusal(w, refusal.Status, refusal.Code, refusal.Message)
			return
		}

		var authorityErr *AuthorityError
		if errors.As(err, &authorityErr) {
			// An upstream failure is not the caller's fault and is not a secret:
			// the request is refused and the capability stays spent, exactly as
			// a failed image pull would be.
			//
			// 503, not 502 as the Ruby original answered. This is the one
			// deliberate deviation in the port and it is made on purpose: the
			// service could not mint, which is an availability answer, and the
			// half-built credential it refuses to hand over is exactly what
			// `credential_too_short_lived` answers with. The code is unchanged
			// — `authority_error` — so a caller reading the body sees the same
			// vocabulary either way.
			a.log(http.StatusServiceUnavailable, boxID, "authority: "+authorityErr.Kind)
			a.refusal(w, http.StatusServiceUnavailable, "authority_error", authorityErr.Error())
			return
		}

		a.log(http.StatusInternalServerError, boxID, fmt.Sprintf("unhandled: %T", err))
		a.refusal(w, http.StatusInternalServerError, "internal_error", "the exchange failed")
	}
}

// readBoxID reads the body and answers the box_id it names. A non-nil refusal
// means the body is not JSON — and nothing else, so that a body that is valid
// JSON with no box_id in it is answered as a missing box, not as a parse error.
func readBoxID(r *http.Request) (string, *Refusal) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return "", &Refusal{Status: http.StatusBadRequest, Code: "malformed_body"}
	}
	if strings.TrimSpace(string(body)) == "" {
		return "", nil
	}
	var payload struct {
		BoxID string `json:"box_id"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", &Refusal{Status: http.StatusBadRequest, Code: "malformed_body"}
	}
	return payload.BoxID, nil
}

// bearer reads the capability from the Authorization header. Anything that is
// not a bearer is an absent capability, which is its own refusal rather than a
// malformed one.
func bearer(r *http.Request) string {
	header := r.Header.Get("Authorization")
	scheme, value, found := strings.Cut(header, " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return ""
	}
	return strings.TrimSpace(value)
}

func (a *App) refusal(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
}

func (a *App) notFound(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusNotFound, map[string]any{
		"error": map[string]string{"code": "not_found", "message": "no such route"},
	})
}

type logLine struct {
	Event  string `json:"event"`
	Status int    `json:"status"`
	BoxID  string `json:"box_id"`
	Note   string `json:"note"`
}

// log writes the outcome and nothing else.
//
// The box's id is not a secret — the operator is enrolling this box. What is
// refused is a line naming the capability or the credential: a log line is the
// one place a secret is copied, and the copy outlives the credential.
func (a *App) log(status int, boxID, note string) {
	line, err := json.Marshal(logLine{
		Event:  "registry.credential_exchange",
		Status: status,
		BoxID:  boxID,
		Note:   note,
	})
	if err != nil {
		return
	}
	_, _ = io.WriteString(a.logger, string(line)+"\n")
}

// writeJSON answers with JSON and nothing that carries a credential.
func writeJSON(w http.ResponseWriter, status int, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		http.Error(w, `{"error":{"code":"internal_error","message":"the exchange failed"}}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
