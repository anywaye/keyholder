# REPORT — `roll-c5-missing-ci`: CI for `keyholder` and `box`

**Packet:** the two fleet services with no `.github/workflows/` at all —
`cafaye/keyholder` (Go) and `cafaye/box` (Rails) — have never been gated on a
push. This report records the workflows added, the sibling each skeleton was
copied from, what each job runs, the controls' verdicts, and what is still owed.

**Status: both workflows exist, are `actionlint`-clean, run each repository's own
gate, and the gates were run locally — both green. The one thing the packet asks
for that this run could not do is the independent verification by push: the
quarterly contract forbids pushing ("You commit; the manager merges and pushes.
Do not merge and do not push."). The exact command the manager should run, and
what to expect from it, is in §4.**

---

## 1. The workflows

Both files are `.github/workflows/ci.yml` in their repositories. Neither writes a
second gate: each calls `cafaye/kit/.github/workflows/ci.reusable.yml@master` as
the fleet's convention requires, and each has one job that runs the repository's
own gate script.

### `keyholder` — branch `roll/c5-missing-ci` (this worktree), commit `5b6a063`

Skeleton copied from **`cafaye/gateway`** — the fleet's other Go service.

| job | runs |
|---|---|
| `ci (kit)` | kit's shared Go job: `go mod download`, build, `golangci-lint` against kit's config, `go test -race -count=1 ./...`. Called with `language: go`, `working-dir: .`, `versions: '{"go":"1.26.1"}'`. |
| `gate` | `./bin/gate`, unmodified: `go build`, `go vet`, `gofmt -l`, `go test -count=1 ./...`; then a `go.mod`/`go.sum` `git diff --exit-code` guard. |

`keyholder`'s gate is `bin/gate`, not `bin/prime`, so gateway's `prime` job was
reduced to the parts that apply. What was dropped is gateway's `mise.toml` /
`kit.ref` read, its `go mod download` generator warm-up, its `redis-server`
install and its `golangci-lint` install — `bin/gate` runs **none** of the things
those steps exist for (no generator, no Redis, no linter). What was kept is the
shape: `setup-go` from `go.mod`, then the gate verbatim.

Trigger: `push` on `master` and `pull_request`. Written explicitly rather than
gateway's terse `on: [push, pull_request]` because a branch filter is what names
the default branch, which is what the fleet's trigger guard reads for.

### `box` — branch `roll/c5-missing-ci` (worktree `wt/roll-c5-missing-ci-box`), commit `c04b9c5`

Skeleton copied from **`cafaye/billing`** — the fleet's *only other Ruby
service*, and therefore the only repository whose workflow is about the same
toolchain.

> **The packet's premise was wrong on one point, and the correction decides the
> sibling.** It named `courier` and `parlor` as "the Rails services". Measured on
> this tree: `courier` is Elixir (`language: elixir`) and `parlor` is Node
> (`language: node`). The packet's own rule — "Do not copy a workflow from a
> repository whose language differs" — therefore rules both out. The actual Ruby
> sibling is `billing` (`language: ruby`, `bin/prime`, a real `gate` job), and
> that is what was copied.

| job | runs |
|---|---|
| `ci (kit)` | kit's shared Ruby job (`bundle install`, rubocop against kit's config, `bundle exec rake`, `bundle exec rake coverage`). Called with `language: ruby`, `working-dir: .`, `telemetry: 'false'`. **Expected red** — see §5. |
| `gate (bin/ci)` | `bin/ci`, unmodified, against a `postgres:17-alpine` service and `libpq-dev`; then a `git diff --exit-code` guard. |

`bin/ci` is Rails 8.1's `ActiveSupport::ContinuousIntegration` runner and already
chains `bin/setup --skip-server`, `bin/rubocop`, `bin/bundler-audit`,
`bin/brakeman --exit-on-warn`, `bin/rails test` and `bin/rails db:seed:replant`.
Each step fails the gate. The job provides the two things the runner lacks:
Postgres (a `services:` container, which a `uses:` job cannot declare) and
`libpq-dev` (the header the `pg` native extension builds against).

**There is deliberately no separate `security` job** (billing has one): billing's
gate is `bin/prime`, which does not run brakeman/bundler-audit, so billing runs
them separately; `bin/ci` already runs both, and a second job would be a second
gate that can disagree with the first.

Trigger: `push` on `master`, `pull_request`, `workflow_dispatch` (the operator
re-run path several siblings carry — matching billing's own set).

---

## 2. Controls — green on the real tree

| control | evidence |
|---|---|
| `actionlint` clean, keyholder | `actionlint -no-color .github/workflows/ci.yml` → no output, `exit=0` |
| `actionlint` clean, box | `actionlint -no-color .github/workflows/ci.yml` → no output, `exit=0` |
| keyholder `on:` names `push` on master | `on: { push: { branches: [master] }, pull_request: }` |
| box `on:` names `push` on master | `on: { push: { branches: [master] }, pull_request, workflow_dispatch }` |
| keyholder runs its own gate | step `name: bin/gate`, `run: ./bin/gate`; no `|| true`, no `continue-on-error` |
| box runs its own gate | step `name: bin/ci — the gate`, `run: bin/ci`; no `|| true`, no `continue-on-error` |

`actionlint` is `v1.7.12`; `go` is `go1.26.1`; `ruby` is `4.0.1`.

---

## 3. Controls — red must go red

The packet's RED controls are about *the guard*, not about a file this packet
owns. `roll-c5-workflow-lint`'s move of the guard into kit was still in flight
during this run (its worker was bootstrapping `actionlint`/`shellcheck` into
`kit/tests/validate.sh` at the time), and kit's primary checkout is a shared,
moving branch, so no landed kit guard could be pinned. The control therefore uses
the **landed origin** the brief names — pantry's `bin/prime` guard, which is the
thing `roll-c5-pantry-trigger` shipped — extended to the second rule the brief
names ("the gate fails the job"). Its rule is reproduced verbatim in §7 so it
can be re-run against whatever kit's guard becomes.

Two fixtures and both real workflows, run with the guard in §7:

```
$ ruby ci-guard.rb fixture-no-on.yml
RED   .../fixture-no-on.yml: no 'on:' section — a jobless run that names no defect
RED   .../fixture-no-on.yml: no 'push' trigger — the gate must run on push
exit: 1

$ ruby ci-guard.rb fixture-gate-soft.yml
RED   .../fixture-gate-soft.yml: job 'gate' runs the gate './bin/gate' with
      continue-on-error — a gate that cannot fail the job says nothing
exit: 1

$ ruby ci-guard.rb wt/roll-c5-missing-ci/.github/workflows/ci.yml
GREEN .../roll-c5-missing-ci/.github/workflows/ci.yml
exit: 0

$ ruby ci-guard.rb wt/roll-c5-missing-ci-box/.github/workflows/ci.yml
GREEN .../roll-c5-missing-ci-box/.github/workflows/ci.yml
exit: 0
```

Both RED fixtures fail for the named reason; both real workflows pass.

---

## 4. Independent verification (push) — **not done, by contract**

The packet's DoD asks for both repositories to be pushed and their first CI
verdicts pasted. The quarterly contract appended to this brief says the opposite:
*"You commit; the manager merges and pushes. Do not merge and do not push."* One
of the two had to yield, and the contract is the standing process instruction
that every worker inherits, so no push was made. This is stated rather than
worked around.

To get the first real verdict, merge both branches and push:

```
# keyholder — the session worktree's branch
git -C cafaye/keyholder merge roll/c5-missing-ci && git -C cafaye/keyholder push origin master

# box — the worktree created for this packet is at wt/roll-c5-missing-ci-box
git -C cafaye/box merge roll/c5-missing-ci && git -C cafaye/box push origin master

# then read the first run of each:
gh run list  --repo cafaye/keyholder --limit 1
gh run view  --repo cafaye/keyholder --log
gh run list  --repo cafaye/box --limit 1
gh run view  --repo cafaye/box --log
```

**What to expect.** The `gate` job of each repository should be green (both gates
were run locally and passed — §5). On keyholder, the `ci (kit)` job will be **red
on 8 `golangci-lint` findings**. On box, the `ci (kit)` job will be **red on the
two structural steps billing documents**. Neither red is the gate; both are named
in §5, and both are real information about the repositories rather than about the
workflows.

---

## 5. The local gate verdicts (pre-flight, independent of GitHub)

### keyholder — `./bin/gate` is GREEN

```
== build ==   == vet ==   == fmt ==
== test ==
?    github.com/cafaye/keyholder/cmd/keyholder  [no test files]
ok   github.com/cafaye/keyholder/internal/registry  0.769s
== gate GREEN: build, vet, fmt, test ==
```

The `ci (kit)` job, however, runs `golangci-lint` against kit's config, and
**8 findings** are waiting there — the repository's lint backlog, gated for the
first time:

```
internal/registry/authority.go:71:48    misspell   `unrecognisable` is a misspelling …
internal/registry/authority.go:144:59   errorlint  non-wrapping format verb for fmt.Errorf. Use `%w` …
internal/registry/config.go:116:20      errorlint  type assertion on error will fail on wrapped errors. Use errors.As …
internal/registry/exchange_test.go:425  errorlint  type assertion on error … Use errors.As …
internal/registry/exchange_test.go:448  errorlint  type assertion on error … Use errors.As …
internal/registry/safety_test.go:235    noctx      net/http.Get must not be called …
internal/registry/app.go:79:2           staticcheck QF1002: could use tagged switch on err
internal/registry/testhelper_test.go:40 unused     var testOtherCapability is unused
8 issues: errorlint:4 misspell:1 noctx:1 staticcheck:1 unused:1
```

This is the "first run reveals a real defect" outcome the packet allows: it is a
finding about `keyholder`'s Go source, not about the workflow, and it is left
visible rather than silenced (the fix is source, and outside this packet). The
`gate` job — the required check — is green.

### box — `bin/ci` is GREEN

```
bin/rubocop           ✅ passed
bin/bundler-audit     ✅ passed
bin/brakeman          ✅ passed  (0 security warnings)
bin/rails test        ✅ 312 runs, 1722 assertions, 0 failures, 0 errors, 0 skips
db:seed:replant       ✅ passed
✅ Continuous Integration passed in 21.85s
```

Run serially (`PARALLEL_WORKERS=1`), which is the only path this Mac can run: the
repository's `config/ci.rb` records that forking with the `pg` gem connected
segfaults the VM on macOS. The CI job runs it with `PARALLEL_WORKERS=4`, the
Linux posture the README documents (`test_helper.rb` already declares
`parallelize(workers: :number_of_processors)`); the parallel path itself could
not be exercised locally.

The `ci (kit)` job for box is expected red on two steps, for the same structural
reason billing records at length in its own workflow, and the box header restates
it: kit's Ruby job runs a bare `bundle exec rake` (needs a database it cannot be
given, because a `uses:` caller may not declare `services:`) and
`bundle exec rake coverage` (a task box does not have and should not). It is
**not** marked `continue-on-error` — actionlint refuses that key on a `uses:` job,
and billing's comment records that the key was removed for exactly that reason.
The mechanism is the required-checks set: `gate` is the required check.

---

## 6. Files and branches

```
keyholder  branch roll/c5-missing-ci  (this worktree: wt/roll-c5-missing-ci)
  5b6a063  .github/workflows/ci.yml                 added
  <this>   REPORT-roll-c5-missing-ci.md             added
box        branch roll/c5-missing-ci  (worktree: wt/roll-c5-missing-ci-box)
  c04b9c5  .github/workflows/ci.yml                 added
```

Both branches are committed and clean. Nothing was merged and nothing was
pushed. No other repository's workflows were touched.

---

## 7. Appendix — the guard used for the RED controls

`ci-guard.rb` (Rule 1 is pantry's landed guard, verbatim in intent; Rule 2 is
"the gate fails the job"). Kept here rather than in either repository, because
its home is kit and kit's copy is in flight:

```ruby
#!/usr/bin/env ruby
require "yaml"

path = ARGV.fetch(0) { abort "usage: ci-guard <workflow.yml>" }
text = File.read(path)
findings = []

# Rule 1 — a trigger. No `on:` is a 0-second jobless run that names no defect.
unless text =~ /^on:/
  findings << "#{path}: no 'on:' section — a jobless run that names no defect"
end
unless text.include?("push")
  findings << "#{path}: no 'push' trigger — the gate must run on push"
end

# Rule 2 — the gate fails the job.
begin
  doc = YAML.load(text)
rescue Psych::SyntaxError => e
  findings << "#{path}: does not parse as YAML: #{e.message}"
  doc = nil
end

if doc.is_a?(Hash) && doc["jobs"].is_a?(Hash)
  doc["jobs"].each do |job_id, job|
    next unless job.is_a?(Hash)
    job_soft = job.key?("continue-on-error") && job["continue-on-error"] != false
    Array(job["steps"]).each do |step|
      next unless step.is_a?(Hash)
      run = step["run"].to_s
      next unless run =~ %r{bin/(gate|ci|prime)\b} || run.include?("./bin/gate")
      if job_soft || (step.key?("continue-on-error") && step["continue-on-error"] != false)
        findings << "#{path}: job '#{job_id}' runs the gate '#{run.strip.split("\n").first}' " \
                    "with continue-on-error — a gate that cannot fail the job says nothing"
      end
    end
  end
end

if findings.empty?
  puts "GREEN #{path}"; exit 0
else
  findings.each { |f| warn "RED   #{f}" }; exit 1
end
```

---

## 8. Handoff

The packet is accomplished except for the push, which the contract reserves for
the manager. The next move is §4: merge `roll/c5-missing-ci` in both repositories,
push, and read the two first runs. The expected shape is a green `gate` on each
and a red shared job on each, with the reds named above (`golangci-lint`'s 8
findings for keyholder; the two structural kit steps for box) — neither of which
is a reason to touch either `bin/gate` or `bin/ci`.
