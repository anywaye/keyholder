#!/usr/bin/env bash
# ci/pipeline.sh — keyholder's pipeline, on the instabox backend or any
# other.
#
# WHY A SERVICE NEEDS ONE. The backend's job is only to provide an
# environment and call this script; the gate, the build and the ship are the
# project's. `bin/gate` already exists and `bin/publish` already ships an
# image and a chart — this file is the wiring between them that Actions used
# to hold, moved into the repository where it can be run by hand, by a
# sandbox, or by a runner.
#
# WHERE THE FACTS COME FROM: `ci/ci.yml` IN THIS REPOSITORY.
# Every fact this file uses about how the repository is built — the
# toolchain pin in mise.toml, the gate entrypoint, and the PATH entry CI
# adds — is visible in that workflow file, and THAT FILE IS THE SOURCE OF
# TRUTH. When the workflow changes, change this file with it.
#
# WHAT THE BACKEND PROVIDES (kit's backends/README.md is the contract):
# WORKSPACE, GH_TOKEN, CI. Anything else this repository's pipeline needs it
# declares, and the backend materializes it from `~/ci-env.d/<project>.env`.
#
# THE DATABASE. The gate needs no database, no cluster and no network (the
# workflow's `gate` job names none), so this pipeline wires none. A gate
# that starts one Postgres per job on Actions is the project that needs a
# database here; this project is not one.
#
# GATE CONCURRENCY. Nothing in this file sets CI_GATE_SERIAL: which projects
# need it is recorded in kit's backends/README.md, and keyholder is not one
# of them.
set -euo pipefail

# ---------------------------------------------------------------------------
# keyholder
# ---------------------------------------------------------------------------
# `run from anywhere`: the repository root is derived from this file, not from
# the caller's cwd.
#
# THE PIPELINE NEVER MOVES THE CHECKOUT, and this is not a style choice. A
# pipeline that `git fetch`es + `git reset --hard`s destroys any tree it is
# run against to verify. The AGENT owns the checkout's position — it fetches
# the commit and resets before calling in (see kit's agent.sh) — and a
# pipeline that also resets is a pipeline that deletes a worker's uncommitted
# packet. The gate runs on whatever tree it is given, which is the only
# property that makes it a verification tool.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
REPO_NAME="$(basename "$REPO_DIR")"

WORKSPACE="${WORKSPACE:-$(cd "$REPO_DIR/../.." && pwd)}"
export CI="${CI:-1}"
export WORKSPACE

log() { printf '\n== %s\n' "$1"; }

log "pipeline: $REPO_NAME at $REPO_DIR"

# ===========================================================================
# THE GATE. `bin/gate`, the entrypoint `ci/ci.yml`'s `gate`
# job names ("bin/gate"). A gate the workflow names and the pipeline does
# not is a pipeline that is green while testing nothing — read the file, do
# not assume.
# ===========================================================================
GATE=(./bin/gate)

# ===========================================================================
# PATHS THIS REPOSITORY'S CI ADDS. The one `echo … >> $GITHUB_PATH` line in
# `ci/ci.yml` (`golangci-lint, the version mise.toml pins`
# installs into `$HOME/.local/bin`), in the order the workflow appends it.
# Without it the gate fails for a reason that has nothing to do with the
# tree — `bin/gate` exits 127 with no linter on PATH.
# ===========================================================================
PATHS=("$HOME/.local/bin")

if [ "${#PATHS[@]}" -gt 0 ]; then
  for d in "${PATHS[@]}"; do
    # One entry per directory, in the order the workflow appends them: PATH is
    # searched front to back and a later entry must not shadow an earlier one.
    export PATH="$d:$PATH"
  done
fi

log "the toolchain the repository pins"
# `mise install` materializes the versions in mise.toml; `mise exec` runs the
# gate under them, so a developer, a runner and this sandbox all use the same
# compiler. When there is no mise.toml, or no mise, the gate runs on whatever
# this machine ships — which is what the workflow does on a runner without
# the setup step, and is reported rather than hidden.
if [ -f mise.toml ] && command -v mise >/dev/null 2>&1; then
  mise install
  GATE=(mise exec -- "${GATE[@]}")
elif [ -f mise.toml ]; then
  echo "pipeline: mise.toml is present and mise is NOT on PATH — the gate runs on the machine's own toolchain"
fi

log "kit's lint config, which bin/gate refuses without"
# ci.yml's `kit (lint config)` step: kit's `lint/golangci.yml`, sparse-checked
# out beside the repository at `.kit/lint/golangci.yml`. The config is NOT
# copied — kit's own header says why ("Not copied into a service repo") and a
# copy is a second policy to drift. `bin/gate` resolves it from `.kit/` or
# from kit beside the tree (`../kit`); on a sandbox the sibling checkout may
# already sit at `$WORKSPACE/anywaye/kit`, so link it rather than cloning a
# second copy. When neither exists the gate fails with the message it already
# carries, rather than running the linter with no config (which exits 0 on a
# file the config rejects).
if [ ! -f .kit/lint/golangci.yml ] && [ -f "$WORKSPACE/anywaye/kit/lint/golangci.yml" ]; then
  mkdir -p .kit/lint
  ln -sfn "$WORKSPACE/anywaye/kit/lint/golangci.yml" .kit/lint/golangci.yml
  echo "pipeline: linked kit's lint config from the sibling checkout"
fi

log "golangci-lint, the version mise.toml pins"
# ci.yml's step of the same name: `bin/gate` runs `golangci-lint run` over
# kit's config and exits 127 when the binary is not on PATH — the refusal
# working, not a defect. `mise install` above provides the pinned version;
# this step is for a machine whose gate still cannot find it, and it reads
# the version out of mise.toml rather than retyping it. The RELEASE ARCHIVE
# is pinned by version, never the installer script at a moving ref.
if ! command -v golangci-lint >/dev/null 2>&1; then
  version="$(sed -n 's/^"golangci-lint" *= *"\(.*\)"/\1/p' mise.toml)"
  if [ -z "$version" ]; then
    echo "pipeline: mise.toml pins no golangci-lint, and bin/gate refuses" >&2
    echo "pipeline: to run without the binary. Restore the pin rather than" >&2
    echo "pipeline: installing whatever GitHub calls current." >&2
    exit 1
  fi
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
  esac
  base="https://github.com/golangci/golangci-lint/releases/download/v${version}"
  archive="golangci-lint-${version}-linux-${arch}.tar.gz"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/keyholder-lint.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  curl -sSfL "$base/$archive" | tar -xz -C "$tmpdir"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmpdir/golangci-lint-${version}-linux-${arch}/golangci-lint" "$HOME/.local/bin/golangci-lint"
  trap - EXIT
  rm -rf "$tmpdir"
  golangci-lint --version
else
  golangci-lint --version
fi

log "the gate"
# The command is a list, so a multi-word gate works without eval and nothing
# a project writes here is re-parsed.
"${GATE[@]}"

log "the gate left the lockfiles alone"
# ci.yml's `go.mod and go.sum are untouched` step: `bin/gate` runs `go build`
# and `go test`, and neither rewrites the manifests — but a `go get` or a
# `go mod tidy` left in a dependency bump would resolve a different tree
# than the one committed, and the run would stay green while doing it.
if ! git diff --exit-code -- go.mod go.sum; then
  echo "pipeline: bin/gate moved go.mod or go.sum — the build is no longer against the committed tree" >&2
  exit 1
fi
echo "pipeline: go.mod and go.sum unchanged by the gate"

# ===========================================================================
# SHIP. The default is the image+chart publish this repository already
# carries: `bin/publish` is kit's `templates/bin/publish.sh`, copied
# verbatim. Never rebuild what the gate just tested: publish the tree as it
# stands.
# ===========================================================================
if [ "${CI_DRY_RUN:-0}" = "1" ]; then
  log "gate passed; CI_DRY_RUN=1, not shipping"
  exit 0
fi

SHIPPED=""
if [ -f chart/Chart.yaml ]; then
  log "publish image + chart"
  # `--service-dir .` because we are already at the root; the tool derives the
  # image name, reads the chart's name and version from Chart.yaml, stamps the
  # chart with the PUSHED image's digest, and pushes to oci://ghcr.io/anywaye/charts.
  # It needs a registry login already in place — the operator does that once
  # with `bin/publish --sandbox` (token via stdin); see backends/README.md.
  ./bin/publish --service-dir .
  chart_name="$(sed -n 's/^name: *//p' chart/Chart.yaml | head -1)"
  chart_version="$(sed -n 's/^version: *//p' chart/Chart.yaml | head -1)"
  SHIPPED="image+chart ${chart_name}:${chart_version}"
else
  echo "pipeline: no chart/Chart.yaml — nothing to publish; the gate is the whole run"
fi

# ---------------------------------------------------------------------------
# the last line a log tail reads
# ---------------------------------------------------------------------------
# Naming WHAT shipped and the COMMIT it was built from is the whole point of
# this line: `agent[<project>]: shipped <sha>` says the pipeline returned 0,
# and this says what that meant. A run that shipped nothing says so.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$SHIPPED" ]; then
  log "pipeline: shipped $REPO_NAME $SHIPPED at $COMMIT"
else
  log "pipeline: passed $REPO_NAME at $COMMIT (nothing published)"
fi
