# AGENTS.md — keyholder

Fleet registry-credential exchange: trades a box-bound `registry.pull` capability
for a short-lived, pull-only dockerconfigjson. Go service.

## Build / test / deploy
- Gate: `./bin/gate` (builds, vets, lints, tests, renders chart). Exit 0 = green.
- Needs `helm` on PATH for the chart-render step.
- No database, no network needed for the gate.

## Where things live
- Source: `cmd/`, `internal/`, `migrations/`
- Chart: `chart/`
- Manifest: `cafaye.yml`

## Conventions
- Secrets: no `.env` files with values. Use `cafe secret set/get/list` (dev) and `cafe dev` (injects). Manifests declare env vars via `env:` block. See `docs/secrets.md`.
- Capability is spent exactly once; credential appears only in the HTTP response body.
- Depends on `box` (redeems capability there) and GitHub App installation tokens.
