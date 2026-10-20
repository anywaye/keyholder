#!/bin/sh
#
# kit template — the provenance stamp. Copy to `docker/provenance.sh` in the
# service repo beside `docker/entrypoint.sh`, or leave it in `docker/` and
# COPY it from there.
#
#   cp <kit>/docker/provenance.sh docker/provenance.sh
#
# ---------------------------------------------------------------------------
# WHAT THIS IS FOR, IN ONE SENTENCE
# ---------------------------------------------------------------------------
# A tag is a mutable name, so an image pulled as `:e2e` cannot say which commit
# is inside it; this stamps the image so that the thing running can name what
# it was built from, and so that the name is CHECKABLE rather than decorative.
#
# It is the second half of P3-19 (one artifact, every environment). That packet
# moved every e2e tier onto a pulled image, which was correct and left this hole:
# a consumer that pulls cannot tell whether the bytes contain the fix merged
# five minutes ago or the one before it.
#
# ---------------------------------------------------------------------------
# THE FORMAT, AND WHY IT IS THIS ONE
# ---------------------------------------------------------------------------
# Four places were available. Measured, not assumed:
#
#   1. OCI image LABELS (what this does). `docker image inspect` reads them off
#      a PULLED image with the tool every consumer in this fleet already runs,
#      and they survive `docker pull` with no buildx, no network round trip and
#      no extra binary. Verified on both the label path and the file path:
#        $ docker image inspect stampprobe:2 --format '{{json .Config.Labels}}'
#        {"org.opencontainers.image.revision":"0123…4567", …}
#      Cost: they are metadata, so a `--no-cache` rebuild changes them — but so
#      does any other stamp, and they are the only sink that is BOTH readable by
#      the consumer and impossible to forget, because they live in the
#      Dockerfile every build path goes through.
#
#   2. A buildx PROVENANCE ATTESTATION. `provenance: mode=max` is already on in
#      `ci/image.reusable.yml`, so an attestation exists for
#      images built by that workflow — and it is the wrong answer for a
#      CONSUMER. Reading one is `docker buildx imagetools inspect` or
#      `docker attestation verify`, both of which fetch a REFERREER from the
#      registry over the network; the e2e tier pulls from a plain-HTTP registry
#      on `localhost:16010` and a referrer fetch against that is a second thing
#      to configure. Worse, an attestation is attached by the WORKFLOW, and the
#      e2e artifacts are pushed by `bin/e2e-stack publish-siblings` with a bare
#      `docker build`. The stamp would be absent exactly where this packet needs
#      it most. Kept on, still — it costs one manifest entry — but not counted.
#
#   3. An OCI ANNOTATION on the manifest list. Same reachability problem as (2),
#      and worse: annotations sit on the INDEX, not on the per-platform config,
#      so `docker image inspect` does not show them at all.
#
#   4. A MANIFEST BESIDE THE IMAGE — a second object in the registry holding
#      {tag, sha256, commit}. Rejected outright: it is a join between two
#      independently mutable things, so "the registry and the source disagree"
#      becomes a state you cannot detect. This packet's whole point is that the
#      stamp must be ABLE TO DISAGREE VISIBLY, and a side manifest is the one
#      shape where it cannot.
#
# And a fifth, which is a sink rather than a format, and is also here:
#
#   5. A FILE IN THE IMAGE (`/app/kit-provenance.json`). Labels live in the
#      image CONFIG, which a running process cannot reach — there is no docker
#      socket, no CLI, and in several of these images no shell. So "the thing
#      running can name what it was built from" is FALSE for labels alone. The
#      file is derived from the same validated fields by the same script, and
#      `tests/provenance_test.sh` asserts the two SINKS AGREE, which is what
#      stops the file from becoming a second, hand-editable lie.
#
# ---------------------------------------------------------------------------
# THE FIVE FIELDS, AND WHY EXACTLY FIVE
# ---------------------------------------------------------------------------
#   source            org.opencontainers.image.source      owner/repo
#   revision          org.opencontainers.image.revision    40 hex
#   built_at          org.opencontainers.image.created     RFC3339 UTC
#   source_dirty      com.cafaye.kit.source.dirty          clean|dirty
#   template_version  com.cafaye.kit.template.version      vN.N.N
#
# Three are standard OCI keys, so a tool that knows nothing about cafaye reads
# them. Two are kit's own namespace, which is the whole of the private surface.
#
# WHAT IS DELIBERATELY ABSENT, because each was tempting:
#   - the BRANCH. A branch is a moving name: stamping one reintroduces exactly
#     the ambiguity the stamp removes, and `type=ref,event=branch` already
#     publishes it as a TAG where a human wants it.
#   - the dirty FILE LIST. `source_dirty` is a flag. Which paths were dirty is a
#     developer's working state and, on this fleet, a local absolute path.
#   - the BUILDER'S HOSTNAME / the runner. It is infrastructure identity, it
#     outlives the artifact's meaning, and on the e2e path it is a laptop.
#   - a VERSION of the software. kit's header already argues this in the
#     workflow: a release tag is a claim, and cutting one is a decision.
#   - `unknown` as an acceptable value for `source` and `revision`. It IS
#     accepted (an unstamped local build must not be refused), but `verify`
#     treats it as a FAILURE when an expectation was given — which is the only
#     honest reading of "I do not know what this is" in an assertion.
#
# ---------------------------------------------------------------------------
# REDACTION AT THE IO BOUNDARY — HOW, NOT A LIST OF BANNED WORDS
# ---------------------------------------------------------------------------
# These images are pulled by anything with registry access, so the stamp is a
# PUBLICATION SURFACE. The rule is therefore a CLOSED GRAMMAR, not a denylist:
#
#     A value may be stamped if and only if it matches the exact shape of the
#     field it is being stamped into. There is no escape hatch, no "extra"
#     field, and no way to add a field without writing its shape — which is what
#     makes this structural rather than a list somebody has to remember to
#     extend when they add the next field.
#
# Measured consequences, each refused BY SHAPE and not by keyword (a keyword
# denylist is what a secret scanner is, and what lets the next novel shape through):
#
#   kaka@cafaye.com            an email. No grammar in the set admits `@`.
#   a branch name              ASYMMETRIC, and stated rather than papered over.
#                              `worker/kit-provenance-01` is shape-IDENTICAL to
#                              `owner/repo`, so no grammar can refuse it in the
#                              `source` field — there is no regex that separates
#                              a repository from a branch with two segments and a
#                              hyphen. It IS refused in every other field
#                              (`revision` is 40-hex, `built_at` is RFC3339), and
#                              that is the whole of the defence. It is also not a
#                              leak: the registry publishes that string as a
#                              TAG already (`type=ref,event=branch`), to everyone
#                              with pull access, which is exactly the population
#                              that can read the stamp. The shapes that DO leak —
#                              local paths, emails, hostnames, credentials — are
#                              all refused, and the rule is therefore not "no
#                              secret is stamped" but the sharper one: **nothing
#                              is stamped that the registry reader did not
#                              already have.**
#   /Users/kaka/Code/any/moon   a local path. `source` requires exactly two
#                              `[a-z0-9._-]` segments; this has six and starts
#                              at `/`.
#   pg.corp.internal:5432      an internal hostname. `source` carries NO scheme
#                              and NO host — that is the point of the grammar,
#                              and it is why `https://github.corp/x` is refused
#                              too.
#   ghp_16C7…                  a credential. Not hex-40, not two path segments.
#
# The `source` grammar deserves the emphasis: **it admits exactly one `/`.**
# That single character budget is what makes "owner/repo" expressible and every
# path, URL and hostname above inexpressible, and it is why the host is not
# merely omitted from the format but STRUCTURALLY ABSENT from it.
#
# ---------------------------------------------------------------------------
# THE SUBCOMMANDS
# ---------------------------------------------------------------------------
#   stamp --validate        read the fields from the environment, exit non-zero
#                           on the first field whose value is not its shape.
#   stamp --args            print the `--build-arg` lines a builder hands to
#                           `docker build`. Runs validation FIRST, so a builder
#                           cannot pass an unvalidated value into the image.
#   stamp --write FILE      write the JSON stamp. Runs inside the build (a
#                           Dockerfile RUN), with the same fields.
#   stamp --verify IMAGE    CONSUMER SIDE. Read the stamp off a PULLED image
#                           and print it; with `--expect-revision SHA` also
#                           ASSERT it, and exit non-zero when it disagrees.
#
# `--verify` is the answer to "a stamp nothing reads is a label on a picture".
# It is what `bin/e2e-stack` calls after it pulls, and it is the smallest
# consumer change in the fleet: two lines, one of them the print.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A TEMPLATE AND NOT A LIBRARY
# ---------------------------------------------------------------------------
# Services adopt kit by COPYING. So this file multiplies seven-fold across the
# Dockerfiles and then once per adopting repository, and it must stay small and
# boring: POSIX `sh`, no dependencies, no `bash`, no `pipefail` (it runs inside
# a `python:*-slim`, an `oven/bun:*-slim` and a `debian:*-slim` — the same
# argument `docker/entrypoint.sh` makes in its own header), and no network.
set -eu

PROG='kit-provenance'

# --- the five fields, and the grammar of each --------------------------------
#
# `key`      the OCI label key. Three are standard; two are kit's namespace.
# `env`      where the value is read from. These are the build-arg names, so the
#            Dockerfile, the workflow and this file agree by construction.
# `shape`    what a value must look like. Read as a `case` glob, not a regex,
#            because `case` is the only pattern matcher POSIX `sh` has and a
#            second regex engine would be a dependency.
#
# The order is the order the failure is reported in, and it is field order
# rather than alphabetical: source, then revision, then the rest. A caller with
# four unset fields is told about the one that would have been most misleading.
FIELDS='source revision built_at source_dirty template_version'

# hex40: 40 lowercase hex characters. Lowercase because `git rev-parse` emits
# that and a stamp that varies in case for the same commit is a stamp two
# consumers can disagree about. `unknown` is the honest "nobody told me".
shape_source() {
  case "$1" in
    unknown) return 0 ;;
    # EXACTLY one slash, two segments, no leading dot, no scheme, no host, no
    # port. `owner/repo` and nothing else.
    */*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    */*/*) return 1 ;;                     # two or more slashes: a path, a URL
    ./* | */. | .*) return 1 ;;           # a dot segment: a relative path
  esac
  # Each segment: [a-z0-9._-]+ with no leading dash, no trailing dot. This is
  # what refuses `@` (email), `:` (host:port) and every scheme separator.
  printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?/[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'
}

shape_revision() {
  case "$1" in
    unknown) return 0 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

shape_built_at() {
  case "$1" in
    unknown) return 0 ;;
  esac
  # RFC3339 in UTC, to the second. A local timestamp with a zone offset is
  # ambiguous in a label nobody parses carefully, and `date -u` is one flag.
  printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

shape_source_dirty() {
  # A FLAG, deliberately. `dirty: modified paths` is the shape that leaks a
  # developer's working directory, and there is no grammar in this set that
  # would accept it.
  case "$1" in
    unknown | clean | dirty) return 0 ;;
  esac
  return 1
}

shape_template_version() {
  case "$1" in
    unknown) return 0 ;;
  esac
  printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
}

# `expect` — what the shape is, printed in the failure so the caller is told the
# RULE and not merely that it broke. A redaction failure a developer cannot
# act on is one they will work around by stamping `unknown` everywhere.
expect_source() { printf 'owner/repo, or "unknown" (lowercase, exactly one "/", no scheme, no host, no port)'; }
expect_revision() { printf '40 lowercase hex characters, or "unknown"'; }
expect_built_at() { printf 'RFC3339 UTC to the second (YYYY-MM-DDTHH:MM:SSZ), or "unknown"'; }
expect_source_dirty() { printf 'one of clean, dirty, unknown — a FLAG, never a file list'; }
expect_template_version() { printf 'vN.N.N, or "unknown"'; }

field_value() {
  case "$1" in
    source) printf '%s' "${KIT_PROVENANCE_SOURCE:-}" ;;
    revision) printf '%s' "${KIT_PROVENANCE_REVISION:-}" ;;
    built_at) printf '%s' "${KIT_PROVENANCE_BUILT_AT:-}" ;;
    source_dirty) printf '%s' "${KIT_PROVENANCE_SOURCE_DIRTY:-}" ;;
    template_version) printf '%s' "${KIT_PROVENANCE_TEMPLATE_VERSION:-}" ;;
  esac
}

fail_field() {
  # The message is the whole product of this function, so it names FOUR things:
  # the field, the value, the shape it wanted, and the fact that the value was
  # REFUSED rather than mangled. Never print the value to a registry log
  # unredacted — but here it came from the caller's own environment and the
  # caller has it, so showing it is what makes the failure fixable. What is
  # never done is falling back to a truncated or sanitised version of it.
  printf '%s: refusing to stamp %s=%s\n' "$PROG" "$1" "$2" >&2
  printf '%s:   it must be %s\n' "$PROG" "$(expect_$1)" >&2
  printf '%s:   this value was NOT stamped and NOT truncated. A stamp that lies is worse than no stamp.\n' "$PROG" >&2
  exit 2
}

validate() {
  # An UNSET field is `unknown`, not an error: a developer's local
  # `docker build` must not be refused for not knowing its own commit. That
  # leniency stops at the boundary — `--verify` fails an `unknown` when an
  # expectation was supplied, which is where "I do not know" has to become a
  # red test.
  for f in $FIELDS; do
    v="$(field_value "$f")"
    [ -n "$v" ] || v='unknown'
    "shape_$f" "$v" || fail_field "$f" "$v"
  done
}

# --- --args ------------------------------------------------------------------
#
# One `--build-arg` per field, every time, including for `unknown`. An ARG a
# Dockerfile does not declare is ignored by buildkit with a warning nobody
# reads, so always passing them means a Dockerfile that forgot the ARG gets a
# stamp of `unknown` — visible, and therefore fixable — instead of no label.
emit_args() {
  validate
  for f in $FIELDS; do
    v="$(field_value "$f")"
    [ -n "$v" ] || v='unknown'
    printf -- '--build-arg\nKIT_PROVENANCE_%s=%s\n' "$(_build_arg_suffix "$f")" "$v"
  done
}

_build_arg_suffix() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# --- --write -----------------------------------------------------------------
#
# Writes the file sink. Called from a Dockerfile RUN, so it is `printf` and not
# a jq/awk pipeline: this executes inside a `distroless`-alike, and every
# external tool it could use is one that might be absent from the next base.
#
# No value is interpolated into the JSON unescaped. Every grammar above is a
# subset of `[A-Za-z0-9._:/-]`, so escaping is unreachable in practice — and it
# is unreachable BY CONSTRUCTION rather than by review, which is the property
# worth having. A field whose grammar ever admitted a quote or a backslash
# would turn this into an injection, and the grammar is the place that stops.
write_stamp() {
  out="${1:-/app/kit-provenance.json}"
  validate
  src="$(field_value source)"; [ -n "$src" ] || src='unknown'
  rev="$(field_value revision)"; [ -n "$rev" ] || rev='unknown'
  at="$(field_value built_at)"; [ -n "$at" ] || at='unknown'
  dirty="$(field_value source_dirty)"; [ -n "$dirty" ] || dirty='unknown'
  tv="$(field_value template_version)"; [ -n "$tv" ] || tv='unknown'
  printf '{\n  "source": "%s",\n  "revision": "%s",\n  "built_at": "%s",\n  "source_dirty": "%s",\n  "template_version": "%s"\n}\n' \
    "$src" "$rev" "$at" "$dirty" "$tv" >"$out"
  printf '%s: wrote %s\n' "$PROG" "$out" >&2
}

# --- --verify ----------------------------------------------------------------
#
# THE CONSUMER SIDE, and the reason the stamp is not decorative.
#
# Reads the LABEL sink (not the file), because the labels are what survives a
# `docker pull` into a consumer's daemon, and prints them. With
# `--expect-revision SHA` it ASSERTS, and that assertion is what the packet
# means by "provable able to fail": a tag that resolves to a different commit
# is a non-zero exit, not a log line somebody reads.
#
# The consumer side's read of the five extracted values, by FIELD name, so the
# checks below iterate `$FIELDS` rather than repeating five `sed` results. It is
# a `case` and not `${!var}` indirection because this file is POSIX `sh`.
_verify_got() {
  case "$1" in
    source) printf '%s' "${got_src:-}" ;;
    revision) printf '%s' "${got_rev:-}" ;;
    built_at) printf '%s' "${got_at:-}" ;;
    source_dirty) printf '%s' "${got_dirty:-}" ;;
    template_version) printf '%s' "${got_tv:-}" ;;
  esac
}

# `unknown` is a FAILURE here, deliberately, and that asymmetry is the whole
# design: an unstamped build is fine to CREATE and is not fine to ASSERT ABOUT.
#
# ---------------------------------------------------------------------------
# THE FOUR VERDICTS, and why they are four and not two
# ---------------------------------------------------------------------------
# Before this revision `--verify` had exactly one failure mode that mattered:
# `[ -n "$expect_rev" ] || return 0`, so with no expectation it returned 0 for
# whatever the labels said — including Bun's, inherited from a base image. The
# codes are now four DISTINCT answers and none of them is 0 by accident:
#
#   0  the stamp is well-shaped, it is OURS, and every expectation given was met
#   4  the image carries NO labels at all. Unchanged, and LOAD-BEARING.
#   5  an expectation the CALLER GAVE was not met (`--expect-revision`,
#      `--expect-source`, or an `unknown`/absent answer to one)
#   6  the labels are present and are NOT a valid cafaye stamp: a field violates
#      its own grammar, a field that identifies the build is absent, or the
#      stamp carries nothing in kit's own namespace
#
# 4 AND 6 ARE NOT COLLAPSED, and a successor must not collapse them: something
# upstream depends on telling "this image was built without the stamp" (an image
# from before the packet) apart from "this image carries somebody else's stamp"
# (an image whose provenance is unknown and must not be trusted as ours). A
# caller that only tests `!= 0` still works; a caller that tests `== 4` still
# means "predates the stamp".
emit_verify() {
  image="$1"
  expect_rev="${2:-}"
  expect_src="${3:-}"
  command -v docker >/dev/null 2>&1 || {
    printf '%s: docker is not on PATH, so a pulled image cannot be asked what it is\n' "$PROG" >&2
    exit 3
  }

  labels="$(docker image inspect "$image" --format '{{json .Config.Labels}}' 2>/dev/null || true)"
  if [ -z "$labels" ] || [ "$labels" = 'null' ]; then
    printf '%s: %s carries no labels at all — it was built without the stamp.\n' "$PROG" "$image" >&2
    printf '%s:   (kit: docker/Dockerfile.<lang> declares the ARGs and the LABELs; this image predates it, or was built elsewhere.)\n' "$PROG" >&2
    exit 4
  fi

  got_rev="$(printf '%s' "$labels" | sed -n 's/.*"org\.opencontainers\.image\.revision":"\([^"]*\)".*/\1/p')"
  got_src="$(printf '%s' "$labels" | sed -n 's/.*"org\.opencontainers\.image\.source":"\([^"]*\)".*/\1/p')"
  got_at="$(printf '%s' "$labels" | sed -n 's/.*"org\.opencontainers\.image\.created":"\([^"]*\)".*/\1/p')"
  got_dirty="$(printf '%s' "$labels" | sed -n 's/.*"com\.cafaye\.kit\.source\.dirty":"\([^"]*\)".*/\1/p')"
  got_tv="$(printf '%s' "$labels" | sed -n 's/.*"com\.cafaye\.kit\.template\.version":"\([^"]*\)".*/\1/p')"

  printf 'provenance: %s\n' "$image"
  printf '  source:           %s\n' "${got_src:-<absent>}"
  printf '  revision:         %s\n' "${got_rev:-<absent>}"
  printf '  built_at:         %s\n' "${got_at:-<absent>}"
  printf '  source_dirty:     %s\n' "${got_dirty:-<absent>}"
  printf '  template_version: %s\n' "${got_tv:-<absent>}"

  # --- THE SHAPE, on the consumer side --------------------------------------
  #
  # THE SAME `shape_*` functions `validate` uses, and deliberately not a second
  # grammar. `validate` applied all five to a BUILD ARG, and `--verify` applied
  # none to a LABEL, which is how `oven-sh/bun`'s
  # `https://github.com/oven-sh/bun` — two slashes over a budget of exactly one,
  # a scheme, a host, a port, five separate violations of a grammar this file
  # already wrote down — came to be printed here as though it were our own.
  #
  # A redaction rule that exists only at stamp time is not a rule about the
  # stamp; it is a rule about the moment of writing, and a PULLED image does not
  # pass through that moment.
  bad_shape=''
  absent_hard=''
  absent_soft=''
  for f in $FIELDS; do
    v="$(_verify_got "$f")"
    if [ -z "$v" ]; then
      # WHAT AN ABSENT FIELD MEANS HERE, decided rather than inherited.
      #
      # `validate` maps an absent field to `unknown`, because a developer's
      # unset build arg must not be refused. On the verify path that leniency is
      # withdrawn for the two fields that carry IDENTITY — `source` and
      # `revision`, the two a caller can `--expect`, and the two that answer
      # "what IS this?" — and ABSENCE IS A REFUSAL rather than a pass. Absent
      # and `unknown` mean the same thing to a reader ("nobody told me"), and
      # accepting one while failing the other is an inconsistency with no
      # defensible basis: the script already says `unknown` is "the honest 'I do
      # not know what this is'" and that in an ASSERTION it is a failure.
      #
      # The other three carry METADATA rather than identity, so an absent one is
      # a NOTE, not a refusal: refusing an image because it predates
      # `template_version` would be refusing it for being old, which is what
      # exit 4 already says and says better. `source_dirty: <absent>` was
      # printed and ignored for the whole life of the packet, and that is now
      # said out loud on every run rather than left to the reader's inference.
      case "$f" in
        source | revision) absent_hard="$absent_hard $f" ;;
        *) absent_soft="$absent_soft $f" ;;
      esac
      continue
    fi
    "shape_$f" "$v" || bad_shape="$bad_shape $f"
  done

  if [ -n "$bad_shape" ] || [ -n "$absent_hard" ]; then
    printf '%s: FAIL %s carries labels, and they are not a cafaye provenance stamp.\n' "$PROG" "$image" >&2
    for f in $bad_shape; do
      printf '%s:   %-16s = "%s" — it must be %s\n' "$PROG" "$f" "$(_verify_got "$f")" "$(expect_$f)" >&2
    done
    for f in $absent_hard; do
      printf '%s:   %-16s is absent, and on --verify an absent identity field is a REFUSAL, not a pass.\n' "$PROG" "$f" >&2
    done
    printf '%s:   org.opencontainers.image.* are STANDARD OCI labels that every base image sets,\n' "$PROG" >&2
    printf '%s:   and an image built FROM a stamped one INHERITS them. This stamp names "%s",\n' "$PROG" "${got_src:-nothing at all}" >&2
    printf '%s:   which is not us. A verifier a third party'"'"'s labels can satisfy is not a verifier.\n' "$PROG" >&2
    return 6
  fi

  if [ -n "$absent_soft" ]; then
    printf '%s: note: %s absent — metadata rather than identity, so an old image is not refused for it.\n' "$PROG" "$absent_soft" >&2
  fi

  # --- OWNERSHIP, HALF ONE: is this stamp OURS AT ALL? ----------------------
  #
  # Asked ALWAYS, and it needs no flag, and that is the point: this half is what
  # makes the defect impossible by default rather than by a caller remembering.
  #
  # `org.opencontainers.image.*` is the STANDARD half of the format and every
  # published base image sets it — `oven/bun` sets source, revision and created,
  # and an image built `FROM oven/bun` carries them whether or not anybody built
  # it. `com.cafaye.kit.*` is kit's OWN namespace, and a base image cannot supply
  # it by accident. So the ABSENCE of kit's namespace is evidence of
  # non-authorship, and its presence is evidence of nothing in particular: anyone
  # who wants to forge a label can, and a format cannot defend against that. The
  # honest claim is the negative one, and it is the one that is load-bearing —
  # the defect this packet fixes is INHERITANCE, which this cannot miss.
  #
  # AT LEAST ONE kit key, not both. The question is "did kit's build write
  # this?", and one value in the private namespace answers it; requiring both
  # would be a second copy of `tests/provenance_test.sh` part B's five-key
  # agreement check, and a check that is a copy of another check goes red twice
  # for one cause. Measured: this is the branch `cafaye/gateway:e2e` takes.
  if [ -z "$got_dirty" ] && [ -z "$got_tv" ]; then
    printf '%s: FAIL %s carries only org.opencontainers.image.*, so those labels came from the BASE\n' "$PROG" "$image" >&2
    printf '%s:   IMAGE it was built FROM and not from a kit Dockerfile: nothing here set\n' "$PROG" >&2
    printf '%s:   com.cafaye.kit.*, and that namespace is the one part of a stamp a third-party\n' "$PROG" >&2
    printf '%s:   base image cannot supply by accident.\n' "$PROG" >&2
    printf '%s:   source reads "%s" — whoever built that base image, it is not us.\n' "$PROG" "${got_src:-<absent>}" >&2
    printf '%s:   Pass --expect-source owner/repo to assert the repository as well.\n' "$PROG" >&2
    return 6
  fi

  # --- OWNERSHIP, HALF TWO: is it the repository the caller named? -----------
  #
  # `--expect-source` mirrors `--expect-revision` exactly: given, it is an
  # ASSERTION and a mismatch is exit 5; that is the case a perfectly well-formed
  # foreign source (`oven-sh/bun`, no scheme, two clean segments — which passes
  # every grammar in this file) can only be caught by.
  #
  # NOT GIVEN IS A WARNING AND NOT A FAILURE, and this overrules the packet's
  # recommendation to fail loudly. The reason is exit-code cost, stated plainly
  # rather than assumed: exit 4 is already load-bearing for "no labels at all",
  # so the cost of a new mandatory failure here is that every printing-form
  # caller written by kit's own FIRST MOVE — `provenance.sh --verify IMG || true`
  # in `parlor/bin/e2e-stack` and `site/bin/e2e-stack` — would print a FAIL and
  # continue, which is WORSE than a warning: it teaches a reader that this line
  # is noisy. A check that cries wolf on a green tree is not obeyed on a red one.
  #
  # What the recommendation asked for is not lost, only made impossible to
  # ignore: the warning names the source, says in words that ownership was NOT
  # established, and names the flag that would establish it. Half one above still
  # fails the run without the flag, so the defect that motivated the
  # recommendation — a silent default — is closed by the namespace check rather
  # than by breaking every caller at once.
  if [ -n "$expect_src" ]; then
    if [ -z "$got_src" ] || [ "$got_src" = 'unknown' ]; then
      printf '%s: FAIL %s is stamped "%s" for source and %s was expected — an image that cannot name itself cannot be asserted about.\n' \
        "$PROG" "$image" "${got_src:-<absent>}" "$expect_src" >&2
      return 5
    fi
    if [ "$got_src" != "$expect_src" ]; then
      printf '%s: FAIL %s is built from %s, and %s was expected.\n' "$PROG" "$image" "$got_src" "$expect_src" >&2
      printf '%s:   a stamp that satisfies the grammar is not a stamp that is OURS. %s is a\n' "$PROG" "$got_src" >&2
      printf '%s:   well-formed and entirely foreign, which is the case shape cannot see.\n' "$PROG" >&2
      return 5
    fi
  else
    printf '%s: WARN no --expect-source was given, so OWNERSHIP OF THE REPOSITORY WAS NOT ESTABLISHED.\n' "$PROG" >&2
    printf '%s:      the source reads "%s", and every grammar in this file accepts it. Only\n' "$PROG" "$got_src" >&2
    printf '%s:      --expect-source owner/repo turns "it is shaped like ours" into "it IS ours".\n' "$PROG" >&2
  fi

  [ -n "$expect_rev" ] || return 0

  # `unknown` fails an assertion. See the note above: this is the one place the
  # leniency of `validate` is deliberately withdrawn.
  if [ "${got_rev:-}" = 'unknown' ] || [ -z "${got_rev:-}" ]; then
    printf '%s: FAIL %s is stamped "unknown" and %s was expected — an artifact that cannot name itself cannot be asserted about.\n' \
      "$PROG" "$image" "$expect_rev" >&2
    return 5
  fi
  if [ "${got_rev:-}" != "$expect_rev" ]; then
    printf '%s: FAIL %s is commit %s, and %s was expected.\n' "$PROG" "$image" "${got_rev:-<absent>}" "$expect_rev" >&2
    printf '%s:   the tag is a mutable name. This is the disagreement the stamp exists to make visible.\n' "$PROG" >&2
    return 5
  fi
  printf '%s: ok %s is %s\n' "$PROG" "$image" "$expect_rev"
  return 0
}

# --- entry -------------------------------------------------------------------

cmd="${1:---validate}"
shift 2>/dev/null || true
case "$cmd" in
  --validate) validate ;;
  --args) emit_args ;;
  --write) write_stamp "${1:-/app/kit-provenance.json}" ;;
  --verify)
    # `--verify IMAGE [--expect-revision SHA] [--expect-source owner/repo]`. The
    # flags are PARSED rather than read positionally, and that is not tidiness:
    # the first version took $2 as the expectation, so
    # `--verify IMG --expect-revision SHA` compared the revision against the
    # literal string "--expect-revision" and reported a mismatch on an image
    # that was correct. A check whose flag form is wrong fails in the direction
    # that looks like the bug it was written to catch.
    shift 0 2>/dev/null || true
    v_image=''
    v_expect=''
    v_expect_src=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expect-revision)
          [ "$#" -ge 2 ] || { printf '%s: --expect-revision needs a value\n' "$PROG" >&2; exit 64; }
          v_expect="$2"
          shift 2
          ;;
        --expect-revision=*) v_expect="${1#*=}"; shift ;;
        --expect-source)
          [ "$#" -ge 2 ] || { printf '%s: --expect-source needs a value\n' "$PROG" >&2; exit 64; }
          v_expect_src="$2"
          shift 2
          ;;
        --expect-source=*) v_expect_src="${1#*=}"; shift ;;
        -*) printf '%s: unknown flag %s\n' "$PROG" "$1" >&2; exit 64 ;;
        *)
          [ -z "$v_image" ] || { printf '%s: --verify takes one image reference\n' "$PROG" >&2; exit 64; }
          v_image="$1"
          shift
          ;;
      esac
    done
    [ -n "$v_image" ] || { printf '%s: --verify needs an image reference\n' "$PROG" >&2; exit 64; }
    # `--expect-source` is itself a stamp value, so it is checked against the
    # SOURCE GRAMMAR before it is used to judge anything. A caller that writes
    # `--expect-source https://github.com/cafaye/kit` would otherwise get a
    # mismatch against a correctly stamped image and read it as tampering.
    if [ -n "$v_expect_src" ]; then
      _es="$v_expect_src"
      case "$_es" in
        unknown) ;;
        *)
          if ! shape_source "$_es"; then
            printf '%s: refusing to ASSERT source=%s\n' "$PROG" "$_es" >&2
            printf '%s:   --expect-source must be %s\n' "$PROG" "$(expect_source)" >&2
            exit 2
          fi
          ;;
      esac
    fi
    emit_verify "$v_image" "$v_expect" "$v_expect_src"
    ;;
  --fields) printf '%s\n' $FIELDS ;;
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    printf '%s: unknown subcommand %s (want --validate, --args, --write FILE, --verify IMAGE, --fields)\n' "$PROG" "$cmd" >&2
    exit 64
    ;;
esac