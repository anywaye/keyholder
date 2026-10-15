# REPORT — `adopt-digest-keyholder`: the chart half of the image-digest pin

**Packet:** kit's `chart.reusable.yml` writes `image.digest: "sha256:<64 hex>"` into this
repository's `chart/values.yaml` before `helm package` on every `push: true` run, and INSERTS
the key when a chart has not adopted it. This repository never adopted the other half: the
Deployment template rendered `{{ .Values.image.repository }}:{{ .Values.image.tag }}` and
never read `image.digest`, so a digest-pinned chart rendered an unchanged spec. Measured
across the fleet (2026-10-15): republish after republish, Argo diffed the rendered Deployment
as identical, reported `Synced`, rolled nothing; the manager worked around it by pinning a
sha tag in the Application values. This packet makes that workaround unnecessary here: the
template reads the field, the committed digest is the registry's current one, and the gate
proves both renders.

---

## 1. The contract I followed, quoted

All quotes are `cafaye/kit/.github/workflows/chart.reusable.yml` (read from this worktree's
sibling `../kit`, no changes there):

**The spec section** (lines 58–76):

> `#   3. THE IMAGE DIGEST — THE ONE THAT REACHES THE POD, AND THE ONE THAT WAS`
> `#      MEASURED MISSING. The `appVersion` tag is overwritten on every push`
> `#      ... the rendered Deployment was`
> `#      textually IDENTICAL before and after a build, so Argo's diff reported`
> `#      `Synced`, rolled nothing ... A DIGEST cannot move, so this workflow writes the digest of`
> `#      the image the compose run just built into the chart's `values.yaml``
> `#      (`image.digest`) BEFORE `helm package`: the chart that lands in the`
> `#      OCI registry names the bytes the registry holds beside it, a new build`
> `#      is a textual diff Argo rolls ...`

**The stamp step's own comment on this repository's defect** (lines 349–351, the INSERT branch
of `pin the image by digest`):

> `# INSERT it, for a chart that has not adopted the field yet: the`
> `# publish pins what the template can read, and a deployment that`
> `# does not render image.digest ignores a value it never reads.`

**How the step refuses a malformed digest** (lines 297–302):

> `# IT REFUSES RATHER THAN WRITES A MALFORMED DIGEST: a value that is`
> `# not `sha256:<64 hex>` would render `repository@nonsense`, which`
> `# looks like a pin and fails at image-pull with nothing naming this`
> `# step. `sha256:` plus 64 lowercase hex is the registry's own manifest`
> `# digest grammar ...`

with the enforcement at line 315: `if ! printf '%s' "$IMAGE_DIGEST" | grep -qE '^sha256:[0-9a-f]{64}$'; then ... exit 1`.

**Who supplies the value** (lines 290–292):

> `# WHO SUPPLIES THE VALUE: the composer, from the image job's build`
> `# output (`needs.image.outputs.digest`) — derived, never typed ...`

**Verification of the caller half** (this repository, not changed): `.github/workflows/publish.yml`
line 59 calls the composer — `uses: cafaye/kit/.github/workflows/publish.reusable.yml@master`
with `push: true` (line 61) — and the composer hands the image job's digest to the chart job
(`publish.reusable.yml` line 275: `image-digest: ${{ needs.image.outputs.digest }}`). No
finding there; nothing in `.github/workflows/` was touched.

**Compatibility with the stamp step's own mechanics**, checked against my committed
`chart/values.yaml`: the step's replace path does `sed "s|^  digest:.*|  digest: \"$IMAGE_DIGEST\"|"`
after asserting `grep -cE '^  digest:'` is exactly 1 — the committed file has exactly one line
matching `^  digest:`, at the image block's own 2-space indent, and the comment block above it
contains no second one. The `grep -qE '^image:[[:space:]]*$'` guard is satisfied.

## 2. The change

**`chart/templates/deployment.yaml`** — the image is now rendered two ways (the fleet's shape,
matching `cafaye/gateway`'s adopted chart):

```
{{- $digest := .Values.image.digest | default "" }}
{{- if $digest }}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) }}
{{- fail (printf "image.digest is %q, which is not sha256:<64 lowercase hex>. ..." $digest) }}
{{- end }}
image: "{{ .Values.image.repository }}@{{ $digest }}"
{{- else }}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
{{- end }}
```

- **digest set** → `repository@sha256:…` — the arm a published chart takes.
- **digest absent** → `repository:tag` — the committed-tag path, so a fresh clone with no
  digest renders exactly as before (an empty digest interpolated unconditionally would render
  `repository@`, a reference no registry answers).
- **digest malformed** → the render FAILS and names `image.digest`. This is the deliberate
  choice between the two template-side behaviours: a template cannot refuse at the source the
  way kit's pin step does, so it refuses the RENDER. Absence is legitimate (the tag arm);
  malformed never is — `repository@not-a-digest` would be the exact defect the kit step exists
  to prevent, a name that looks like a pin and fails at image-pull with nothing naming the
  field. Helm's `fail` is available to a template, so "absent-or-fail" resolves to fail for
  malformed, absent for missing — never a broken pin rendered.
- The rendered string is exactly the two shapes the kit grammar allows — `repository@digest`
  and `repository:tag`. There were no chart tests before this packet to keep or update; the
  chart test is new (below) and asserts both renders from the start.
- Grep confirms `deployment.yaml` is the only template naming the image
  (`chart/templates/service.yaml` and `ingress.yaml` reference no `image.*` values).

**`chart/values.yaml`** — `digest: "sha256:6f7355ce010c7ab544aca1a7702bd96c8ca472ad19617132cb99fef8d8303bdc"`
in the `image:` block (repository, digest, tag, pullPolicy — gateway's key order), with the
comment above it in the house voice: what writes it (the publish workflow, from the image
job's build output, before `helm package`), why it exists (the tag is a release constant
overwritten on every master push, so a digest cannot move is the only way a new build is a
diff Argo sees), and that the committed value is what a fresh clone renders.

**The digest is the registry's, not a human's.** Verified this run with
`docker buildx imagetools inspect ghcr.io/cafaye/keyholder:0.1.0`:

```
Digest:    sha256:6f7355ce010c7ab544aca1a7702bd96c8ca472ad19617132cb99fef8d8303bdc
```

— identical to the value the brief supplied, i.e. the brief's value came from the registry and
is committed unchanged.

**`bin/chart-test`** (new, executable) — the chart test, in `gateway`'s `bin/chart-test`
shape, adapted to this repository (chart dir `chart`, release name `keyholder`). It derives
the published path from `go.mod`'s module path, reads `appVersion` from `Chart.yaml`, and
READS the committed digest from the same `values.yaml` the Deployment renders (never types
one). It asserts:

1. the committed render is `image: "ghcr.io/cafaye/keyholder@<committed digest>"`, and is NOT
   named by the mutable tag;
2. a CHANGED digest changes the rendered image text — the property Argo's diff reads;
3. no digest (`--set image.digest=""`) renders `repository:tag`, and never a bare `repository@`;
4. a malformed digest — three shapes (`not-a-digest`, `sha256:abc`, `sha256:` + 63 hex + a
   non-hex char) — is REFUSED: the render fails and the error names `image.digest`;
5. `helm lint` passes;
6. the committed `values.yaml` carries a real digest at all (an empty one would make
   assertion 1 match the broken render — a check passing because the field is absent).

**`bin/gate`** — the chart test is now part of the gate this repository already runs
(locally and in CI's `gate` job), which is what makes the two renders the packet's proof
rather than a separate command nobody runs. `gateway` deliberately kept its chart-test
outside its gate (helm on the machine was the reason); this repository's gate already
carries the opposite discipline — it exits 127 rather than skip when `golangci-lint` is
absent, because "a step that quietly skips when the linter is absent is the whole defect: a
green that verified nothing" — so the chart step mirrors it: `helm` required on PATH (present:
v4.3.0, kit's own publish-path pin; GitHub's runners ship helm), version printed for the
record. No version pin was added to `mise.toml`: kit's `v4.3.0` pin governs `helm package` /
`helm push`, and the functions the render exercises (`fail`, `regexMatch`, `default`) are
stable across helm 3 and 4, so a second pin would only red the gate on a runner's own helm.
Ahead of the render, the same step refuses the COMMITTED digest statically — empty, or not
`sha256:<64 lowercase hex>` — the shape of `gateway`'s `bin/prime-go`, because the committed
value is the pin a fresh clone renders.

Nothing else changed: not the app, not the chart's other values, not `Chart.yaml`, not the
workflows.

## 3. The proofs

**Q2 — gate green** (`mise exec -- ./bin/gate`, exit 0), with the new step in place:

```
== build ==   ... == vet ==   ... == lint == lint config: ../kit/lint/golangci.yml
== fmt ==     ... == test ==  ok  github.com/cafaye/keyholder/internal/registry  0.953s
== chart ==
chart image: chart/values.yaml pins image.digest sha256:6f7355ce…3bdc — immutable, so a new build is a textual diff Argo rolls
helm version: v4.3.0+gbec5b06
== 1. committed values — the Deployment pulls the published image by digest
ok   - the container image is the published repository at the committed digest
ok   - the container image is NOT named by the mutable tag
== 2. a changed digest changes the rendered image — the diff Argo reads
ok   - a changed digest changes the rendered image (the diff Argo reads)
== 3. the other render: no digest falls back to the committed tag
ok   - no digest falls back to the committed tag  / no bare 'repository@'
== 4. a malformed digest is refused, not rendered      (3 shapes, each naming image.digest)
== 5. helm lint passes
== gate GREEN: build, vet, lint, fmt, test, chart ==
```

The baseline gate before the change was also green (the old chart rendered `:tag` and nothing
asserted it) — the packet's proof is the added assertions, not a red turned green.

**Q3 — the red proofs** (each captured, each ended with the tree restored and re-verified):

1. **Blank the committed digest → tag render asserted, and the gate refuses it.** Removing the
   `  digest:` line from `values.yaml`: `helm template` renders
   `image: "ghcr.io/cafaye/keyholder:0.1.0"` (the fresh-clone arm, unchanged from today), and
   the full gate exits 1 at the chart step:
   `bin/gate: chart/values.yaml sets no image.digest, and the Deployment renders its container
   image from exactly that value. ... The committed value is the pin a fresh clone renders, so
   it must be real.`
   With the digest emptied by `--set image.digest=""` on a template that still commits it, the
   render is the tag form and no bare `repository@` appears.
2. **Break the digest branch → the digest render red.** With `chart/templates/deployment.yaml`
   restored to its pre-packet tag-only image line, `bin/chart-test` exits 1 with **9
   failures**: the committed-digest render, its NOT-the-tag absence, the changed-digest
   render (both directions), and all three malformed refusals — i.e. the digest assertions
   cannot pass against a template that ignores the field. The tag arm and `helm lint` stayed
   green, as they should: the fallback arm is not what this packet is about.

After both proofs the tree was restored (`git status` clean) and the gate re-run to
GREEN (exit 0) — the state this report describes.

## 4. Worktrees used

- This packet: `/Users/kaka/Code/any/moon/wt/adopt-digest-keyholder` (branch
  `feat/digest-pin`, one commit: `2173aba` — "chart: render the image by digest, the field
  publish writes"). Not merged, not pushed; the manager merges and runs the live acceptance.
- Read-only: `../kit` (the contract, quoted above) and `../gateway` (the adopted reference —
  its chart, `bin/chart-test` and `bin/prime-go`'s digest guard). Neither was modified.

The sibling `adopt-digest-*` worktrees are the same packet's other repositories; untouched.

## 5. What the live acceptance should see

The manager pushes a trivial change to `master`; the composer builds the image, takes the
digest off the build output, and `pin the image by digest` REPLACES the committed line (its
replace path, count asserted 1) before `helm package`; the chart lands in
`oci://ghcr.io/cafaye/charts/keyholder:0.1.0` naming the new bytes; Argo refreshes, the
rendered Deployment differs by the digest alone, and it rolls — with no human step, and with
the Application's `targetRevision` untouched.
