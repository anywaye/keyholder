> **This file is the argument.** It is written before the code is read, because

**Current direction (2026-10-19):** Ship is the product. The cafaye stack is internal infrastructure; we are not selling or supporting it as a standalone product as of this date. We continue to develop and improve it, treating the founder as the primary customer and keeping "build once, run everywhere" true, with the expectation that it may be offered again later.
> the one judgement call in this packet — where the exchange lives — is the
> thing a successor most needs to be able to disagree with on purpose. The
> sections below it are the record.

# keyholder — the capability exchange

> **This file is the argument.** It is written before the code is read, because
> the one judgement call in this packet — where the exchange lives — is the
> thing a successor most needs to be able to disagree with on purpose. The
> sections below it are the record. It named the service `registry` when it was
> written, and it is now `keyholder` — so the argument below still says
> `registry` wherever it is quoting the service it argued about, and everywhere
> else the service is `keyholder`. The noun that did not change is the one that
> matters: the registry the credential is FOR, ghcr.io.

`keyholder` is the fleet's registry-credential exchange. It trades a box-bound,
purpose-bound `registry.pull` capability for a short-lived, pull-only
dockerconfigjson.

It exists because, until it did, `kit`'s installer redeemed its capability at
`box` and then **refused**: nothing in the fleet traded that receipt for a
credential, so no image could be pulled and substrate steps 6-11 could not run.
That refusal is the whole reason for this service.

## The exchange, in one paragraph

A box presents its single-use, minutes-lived, box-bound capability to
`POST /v1/registry-credentials`, as an `Authorization: Bearer`, with `box_id`
in the body. `keyholder` spends that capability at `box`'s existing redeem route
— naming the purpose and the box it is being spent FOR — and `box` refuses an
expired, already-redeemed, wrong-purpose or wrong-box capability *before the
credential is minted*, with `box`'s own status and code, which `keyholder`
passes through unchanged. On a successful spend, `keyholder` mints a GitHub App
installation access token and answers the base64 dockerconfigjson. The
capability is spent exactly once, and the credential appears in exactly one
place: the HTTP response body.

```
box                                       keyholder                      GitHub
 |  POST /v1/registry-credentials           |                               |
 |  Authorization: Bearer cap_…             |                               |
 |  {"box_id": "…"}                        |                               |
 |----------------------------------------->|  POST /v1/capabilities/redeem   |
 |                                          |-------------------------------->|
 |                                          |   {token, purpose, box_id}     |
 |                                          |<--------------------------------|
 |                                          |   {capability:{…}}  or  410    |
 |                                          |                               |
 |                                          |  POST /app/installations/…/at  |
 |                                          |-------------------------------->|
 |                                          |<--------------------------------|
 |  {"dockerconfigjson": "eyJhdXRocyI…"}   |   {token, expires_at, perms}   |
 |<-----------------------------------------|                               |
```

## Where the exchange lives — the judgement call, and the defence

Three options were on the table. The brief named them; this is the one chosen
and why.

### Option (a) — a route on `box`, behind the redeem — **rejected**

One service, no new deployment. But `box` would have to *hold registry
material* to mint a dockerconfigjson, and `box`'s own boundaries refuse exactly
that, twice:

- `docs/BOUNDARIES.md:6` — *"Box holds no readable customer secret… Box is a
  courier, never a vault. The same rule applies to any future secret-shaped
  value."*
- `docs/BOUNDARIES.md:8` — *"Box … holds no SSH key, no box credential and no
  root."*

A GitHub App private key is a secret-shaped value, so (a) asks a service to
cross a boundary it wrote down. The previous packet's report
(`REPORT-repair-h-registry-pull` in `box`) already declined to hold one "for
boundary 6 and this packet's own avoid list". Doing it now behind a route
instead of in a route changes nothing about who holds the key.

There is a second, quieter reason: a route on `box` would make the credential's
lifetime a property of the *control plane*, which is Cafaye-side, while the
box it is minted for is the thing being installed. Keeping them apart is what
lets `registry` be the only process that can hand out a pull credential, so an
audit of the fleet's registry material is one process, not a control plane with
a registry-shaped feature.

### Option (b) — a small standalone `registry` service — **CHOSEN**

An extra service. In exchange:

- the credential's source material lives in one process whose only job is
  holding it. If that process is compromised, the blast radius is the App's
  permission set — `read:packages` on the fleet's own repositories — and not a
  capability of `box`;
- `box` stays credential-free, and its boundaries are satisfied rather than
  interpreted;
- `box` remains the one door that spends capabilities. `registry` *calls* that
  door rather than replacing it, so the single-use, purpose-bound, box-bound
  guarantees are enforced by the code that already enforces them
  (`Capability.redeem!`), and are not re-implemented — badly — in a second
  service;
- the exchange is testable on its own: the four refusals in this suite are
  assertions against the shipped code path, not against `box`.

The cost is real and is named rather than minimised: one more service to
deploy, one more URL in the substrate's manifest, one more thing that must be
up for a box to boot. `kit`'s installer already validates a set of URLs at
preflight, so the shape of that requirement is not new.

### Option (c) — mint a GitHub token from an operator's deploy bot — **rejected**

Least code. It also reintroduces exactly the thing the capability posture exists
to remove: a long-lived operator secret, living in an environment, handed to a
service that does not need to be its owner. `kit`'s installer retired
`KIT_SUBSTRATE_PULL_SECRET` in W2-P4 for this reason (`tests/substrate_test.sh`
§13a still asserts the name is gone), and a `registry` service that takes the
same value back is a rename.

The distinction that makes (b) defensible is not "long-lived vs short-lived" —
both hold long-lived material. It is **what the material can do**:

| | option (c)'s PAT | this service's App key |
|---|---|---|
| usable against `ghcr.io` directly | **yes** — it is a registry password | **no** — `ghcr.io` cannot authenticate an RSA key |
| scope | whatever the operator's token can read | exactly `read:packages` on the repositories the App is installed on |
| a leak means | rotate the account's token, and hope | nothing: everything derived from it is already dead |
| revoking it | rotate, and every copy in every log dies with it | nothing needs rotating — the tokens expire on GitHub's clock |

An App key cannot be used against a registry. It can only say "I am this app,
now" to GitHub, which answers with an installation access token that expires
within the hour, on GitHub's clock. That is the same posture
`Capability::TTL_MINUTES` keeps for enrollments — **revocable by expiry rather
than by rotation** — applied to the credential's source.

## The credential

Short-lived, single-purpose, and invented under the conditions the brief names:

- **Short-lived.** The lifetime is *GitHub's*, read from the minted token's
  `expires_at`, never asserted by us. The exchange refuses to hand over a
  credential with less than 60 seconds on it — a credential that dies mid-pull
  fails at image-pull time in a voice nobody can attribute, which is the exact
  failure `kit`'s preflight exists to prevent.
- **Pull-only.** Declared by construction: the App's permission set is
  `read:packages`. Asserted at runtime too — `Minted#pull_only?` reads the
  permissions GitHub actually granted, and the exchange refuses a credential
  that can push (`credential_not_pull_only`). A posture with a runtime check
  behind it is a posture; one without is a comment.
- **Never echoed.** `Minted` implements `fmt.Formatter`, so EVERY formatting
  verb renders the redacted form — and the token is an unexported field with no
  accessor at all, which is the structural half of the guarantee. An
  interpolated value, a log line, or a stack trace carrying the credential
  prints its shape and not its secret. The service's own logger records the
  outcome and nothing else. `internal/registry/safety_test.go` asserts all of
  it, including the negative control: no source file reaches for stdout.

## Dependencies, and the exception

The fleet's rule (2026-10-13) is that a good existing library is the default
and writing our own is the exception whose reason is written at the code site.

- **`golang-jwt/jwt/v5`** — used, for the GitHub App JWT. It is *the* RS256
  library for Go, and the reason is written at the code site in
  `internal/registry/authority.go`. The claims are the three GitHub documents
  — `iss`, `iat`, `exp` — and RS256 is pinned rather than inferred.
- **`net/http`, `net/http/httptest`, `encoding/json`, `crypto/*`** (stdlib) —
  used for the single installation-token request, the redeem request, the HTTP
  surface on `http.ServeMux`, and the in-process HTTP driver, so the suite
  tests the shipped code path rather than a mock. `octokit`'s Go equivalent
  (`go-github`) would be the library-shaped answer for the one request, and it
  is a full GitHub API client whose paginator, middleware and own dependency
  tree this service would inherit to make exactly one call. The reason is
  written at the code site, as the fleet's rule requires.
- **deliberately NOT a dependency**: no GitHub API client, no router package,
  no web framework. Three routes do not need one, and every extra dependency is
  one more thing that must be vetted before it can hold the fleet's registry
  material.

No database, no ORM, no cache. The capability is `box`'s row, not ours, and the
credential is minted per request and never stored.

## Running it

```sh
export REGISTRY_BOX_URL=https://box.svc.cafaye.test
export REGISTRY_GITHUB_APP_ID=123456
export REGISTRY_GITHUB_APP_KEY_FILE=/var/run/secrets/cafaye/app-key.pem
export REGISTRY_GITHUB_INSTALLATION_ID=987654
./bin/keyholder            # or: go run ./cmd/keyholder
```

`REGISTRY_GITHUB_APP_KEY` (the PEM itself, in the environment) is still
accepted; the mounted file is preferred, because a value in an environment is
readable by anything that can read `/proc` for the process. `PORT` defaults to
9292, `REGISTRY_REGISTRY_HOST` to `ghcr.io`.

`./bin/gate` runs the gate: it builds the binary, runs `go vet ./...`, checks
the source is gofmt-clean, and runs `go test ./...`. No database, no network, no
cluster — the only verification this packet needs.

## The contract

```
POST /v1/registry-credentials
Authorization: Bearer cap_<64 hex>
{"box_id": "<uuid>"}

200 { registry, expires_at, seconds_remaining, dockerconfigjson }
400 capability_required | capability_malformed | box_id_required | box_id_malformed | malformed_body
403 capability_wrong_purpose | capability_wrong_box   (passed through from box)
409 capability_redeemed                            (passed through from box)
410 capability_expired                             (passed through from box)
502 box_unreachable | bad_upstream | credential_expired | credential_not_pull_only
503 credential_too_short_lived | authority_error
```

The capability travels in the bearer, **not** in the path as the brief's
sketched `POST /v1/capabilities/:token/registry-credential` would have it: a
URL path is logged by every proxy in front of a service, lands in access logs
and crash reporters, and outlives the credential. It is also the idiom the
fleet already uses at `box`'s redeem route, so the installer speaks it the same
way twice.

## What this service does not do

- It does not mint capabilities. Minting is a claimed account's flow at `box`
  (`CapabilitiesController#create`); an agent acting alone is refused there.
- It does not hold a GHCR password or a PAT, ever, in any form.
- It does not persist a credential. Nothing is written to disk.
- It does not verify anything itself. Identity is `identity`'s job, and
  capability spending is `box`'s; this service forwards and trusts the answer
  it gets back, which is the same division of labour `box` follows with
  `identity`.

## The measurement

`script/exchange_proof.rb` runs the whole path with every shipped component on
a socket, and prints a transcript with the credential redacted:

```
box        real Rails (RAILS_ENV=test, its own database) — mints with
           Capability.mint!, spends through the real
           POST /v1/capabilities/redeem route
keyholder  the real ./bin/keyholder binary, built by the gate, with
           registry.NewExchange configured exactly as cmd/keyholder
           configures it in production
github     a socket stub that answers
           POST /app/installations/:id/access_tokens and VERIFIES the App's
           RS256 assertion against the public half of the key the service holds
```

Only GitHub is faked, and it is faked at the wire boundary. The capability is
minted by box's own code; the spend, the redemption and the credential are all
real HTTP against the real routes. Minting is the one step the HTTP surface
cannot perform on its own — it is a claimed account member's flow, and the
member is `identity`.

The proof needs box's Rails app and a database, so it is not part of the gate:
the gate is the suite, and the proof is what a manager runs end to end.

```
$ BOX_DIR=../box ruby script/exchange_proof
== minted four capabilities through Capability.mint! (Capability::TTL_MINUTES = 15) ==
   live         cap_bd418bd8…bd25 (68 bytes)
   expired      cap_386c9e64…99ca (68 bytes)
   otherbox     cap_3c413f0f…d349 (68 bytes)
   wrongpurpose cap_9c45d9dc…27a8 (68 bytes)

== 1. a live capability buys a short-lived, pull-only credential =="
   exchange(LIVE capability, this box)
     status  200
     registry           ghcr.io
     expires_at         2026-10-13T06:15:44Z
     seconds_remaining  3599
     dockerconfigjson   eyJhdXRocyI6eyJnaGNy… (192 bytes, base64)
     decoded            {"auths":{"ghcr.io":{"username":"x-access-token","password":"<REDACTED 66-byte installation token>","email":""}}}

== 2. the SAME capability cannot buy a second credential ==
     status  409
     error   capability_redeemed — capability has already been redeemed

== 3. an expired capability is refused ==
     status  410
     error   capability_expired — capability has expired

== 4. a capability for another box is refused ==
     status  403
     error   capability_wrong_box — capability is bound to a different box

== 5. a capability minted for another purpose is refused ==
     status  403
     error   capability_wrong_purpose — capability is minted for a different purpose

== 6. the credential appears in exactly one place: the response body ==
   {"event":"registry.credential_exchange","status":200,"box_id":"aaa…","note":"Minted(registry=ghcr.io, expires_at=2026-10-13T06:15:44Z, seconds_remaining=3599, pull_only=true, permissions=packages)"}
   …
PROOF GREEN — the receipt-to-credential path ran end to end, and every refusal is the refusal named.
```

Every one of those refusals is `box`'s status and `box`'s error code, passed
through: the exchange does not spend a capability it cannot verify, and it
never invents a reason box did not give it. The service's log line still names
itself `registry.credential_exchange`, and that is not an oversight — it is the
one word in the output that means what it always meant, changed only in the
manifest and the repository name. Note what the transcript does NOT
contain, on either side: the capability token, the dockerconfigjson, and the
installation token. The only copy of the credential is the response body.
