> **This file is the argument.** It is written before the code is read, because
> the one judgement call in this packet — where the exchange lives — is the
> thing a successor most needs to be able to disagree with on purpose. The
> sections below it are the record.

# registry — the capability exchange

`registry` is the fleet's registry-credential exchange. It trades a box-bound,
purpose-bound `registry.pull` capability for a short-lived, pull-only
dockerconfigjson.

It exists because, until it did, `kit`'s installer redeemed its capability at
`box` and then **refused**: nothing in the fleet traded that receipt for a
credential, so no image could be pulled and substrate steps 6-11 could not run.
That refusal is the whole reason for this service.

## The exchange, in one paragraph

A box presents its single-use, minutes-lived, box-bound capability to
`POST /v1/registry-credentials`, as an `Authorization: Bearer`, with `box_id`
in the body. `registry` spends that capability at `box`'s existing redeem route
— naming the purpose and the box it is being spent FOR — and `box` refuses an
expired, already-redeemed, wrong-purpose or wrong-box capability *before the
credential is minted*, with `box`'s own status and code, which `registry`
passes through unchanged. On a successful spend, `registry` mints a GitHub App
installation access token and answers the base64 dockerconfigjson. The
capability is spent exactly once, and the credential appears in exactly one
place: the HTTP response body.

```
box                                       registry                        GitHub
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
(`REPORT-repair-h-registry-pull.md` in `box`) already declined to hold one "for
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
- **Never echoed.** `Minted#inspect` and `#to_s` render the redacted form, so
  an interpolated value, a log line, or a stack trace carrying the credential
  prints its shape and not its secret. The service's own logger records the
  outcome and nothing else. `test/credential_safety_test.rb` asserts all of it,
  including the negative control: no source file writes to stdout.

## Dependencies, and the exception

The fleet's rule (2026-10-13) is that a good existing library is the default
and writing our own is the exception whose reason is written at the code site.

- **`jwt`** — used, for the GitHub App JWT. It is *the* library for that.
- **`net/http`** (stdlib) — used for the single installation-token request.
  `octokit` would be the library-shaped answer, and it is a full GitHub API
  client whose middleware, paginator and sawyer/faraday tree this service would
  inherit to make exactly one request. The reason is written at the code site
  in `lib/registry/authority.rb`.
- **`rack`/`puma`/`rack-test`** — the runtime and the in-process HTTP driver,
  so the exchange's suite tests the shipped code path rather than a mock.

No database. No ActiveRecord. The capability is `box`'s row, not ours, and the
credential is minted per request and never stored.

## Running it

```sh
export REGISTRY_BOX_URL=https://box.svc.cafaye.test
export REGISTRY_GITHUB_APP_ID=123456
export REGISTRY_GITHUB_APP_KEY="$(cat cafe-registry.pem)"
export REGISTRY_GITHUB_INSTALLATION_ID=987654
bundle exec puma -p 9292
```

`bin/prime` runs the gate. `test/` is the suite.

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
