# IPTCVD Pipeline

A governed development pipeline for Claude Code, sized to your plan.

Every change goes through **Idea → Plan → Test → Create → Verify → Document**,
and no gate closes on an assertion — each one closes on a file.

At install time you pick your Claude Code plan. The installer builds the roster,
the verification fan-out and the token budget that plan can actually afford:

| Plan | Agents | Skills | Rules | Verify | Debate | Reporting |
|---|---|---|---|---|---|---|
| **Pro** | 7 | 7 | 5 | one reviewer, then QA | single critic | monthly `/report` |
| **Max** | 11 | 9 | 6 | 3 parallel, read-only | + proposal & judge | monthly `/report` |
| **Max 20x** | 24 | 14 | 7 | 5 parallel, read-only | + agent teams / workflows | `/studio-report` on OTel |

All three share the same enforcement layer: six hooks, path-scoped rules, a
committed gate file that carries the plan's *content*, and agent memory in
version control. The tiers differ in how many specialists exist and how wide the
verification fan-out is — never in how strict the gates are.

---

## Why this exists

Three claims, and the whole repo is built around them:

1. **CLAUDE.md is advisory. Hooks are deterministic.** Anthropic's own docs say
   Claude reads memory files and *tries* to follow them, without a guarantee of
   compliance. So anything that must hold — no code before an approved plan, no
   undocumented change — is a hook, not a sentence in a prompt.
2. **More agents is not more quality.** Every subagent is a fresh context
   window. A 24-agent roster on a project that needs seven is slower, more
   expensive, and *less* coherent. That is why the plan question exists.
3. **"Done" is a claim, not evidence.** The failure mode that kills spec-driven
   setups is accepting an agent's assertion of completion. Every gate here
   demands an artifact — a passing run, a screenshot, a report file.
4. **A guard that has not been tested against its bypasses is decoration.** The
   first three claims are only worth what the enforcement layer is worth, and a
   hook that never fires produces exactly the same green output as a hook that
   works. So every guard in here ships with the bypasses that defeated it, in
   `test/hooks.sh` — and `qa.sh --mutate` puts each of those defects *back*, one
   at a time, and requires a suite to go red. A suite nobody has watched fail is
   not evidence; it is a habit.

### What claim 4 cost, in this repo

These are measured, not hypothetical. With the gate CLOSED, against the
pre-2.1 `gate-check.sh`:

| Spelling of the same file | Verdict |
|---|---|
| `src/services/dues.ts` (relative — the only one tested) | blocked |
| `/home/u/proj/src/services/dues.ts` — **what Claude Code actually sends** | allowed |
| `C:\Users\u\proj\src\services\dues.ts` | allowed |
| `./src/services/dues.ts` | allowed |
| `docs/../src/services/dues.ts` — an allow rule used as a prefix | allowed |
| `src/services/LatestReport.ts` — contains "test" | allowed |
| `src/http/InspectorController.ts` — contains "spec" | allowed |

`verify.sh` reported PASS on all of it, because it fed the one spelling that
worked. Separately: `gate-check` was registered on `Edit|Write` only, so
`sed -i`, `cat >`, `cp`, `npm i` and a `python` one-liner each walked straight
past every gate; and `filter-output`'s `cmd | grep | head` rewrite returned
**exit 0 for a failing test suite**, which is the evidence claim 3 rests on,
inverted by the tool meant to produce it.

All of it is fixed, and all of it is now a test.

---

## Install

```bash
git clone https://github.com/harudayoo/IPTCVD-Pipeline.git ~/.iptcvd-pipeline
cd /path/to/your/project
~/.iptcvd-pipeline/install.sh
```

The installer asks which plan you are on and installs the matching pipeline:

```
Which Claude Code plan is this pipeline for?
The roster, the verification fan-out and the token budget all follow from this.

  1) Pro     7 agents, sequential, one Opus call per feature
     Lean pipeline for a shared Opus/Sonnet pool. One agent per phase, no
     fan-out, no debate protocol. Roughly one context window per phase.

  2) Max     11 agents, conductor-routed, 3-way parallel verify
     The nine-agent core plus evidence-producing verification. Adds the IDEA
     phase, a conductor that enforces phase order, and the two-proposal debate
     protocol for irreversible decisions.

  3) Max 20x 24 agents, 5-way parallel verify, 3-level debate, telemetry
     The complete roster: specialist designers per surface, five-lens parallel
     verification, agent-team escalation for genuinely uncertain work, and a
     measured monthly report.

Choose [1-3]:
```

Skip the prompt when you already know:

```bash
~/.iptcvd-pipeline/install.sh --plan max20x --target /path/to/your/project
```

Preview without writing anything:

```bash
~/.iptcvd-pipeline/install.sh --plan max --target /path/to/project --dry-run
```

**Read `install.sh` before running it.** It writes into your repository. It
takes a backup of anything it touches, but you should still know what it does.
There is deliberately no `curl | bash` one-liner.

### Requirements

| | |
|---|---|
| Required | `bash`, `awk`, `grep`, `sed`, `git` |
| Recommended | `jq` — hooks use it when present and fall back to a shell parser when absent |
| Optional | `python3` — the report scripts. Required in practice on Max 20x. |

Works on Linux, macOS and WSL.

---

## Which plan should I pick?

Pick by what you can afford to run every day, not by what is impressive.

**Pro** — Opus and Sonnet share one usage pool. This roster spends Opus exactly
once per feature, on the plan critique, which is the one place a wrong answer is
expensive to reverse. Everything else is Sonnet, sequential. If you are new to
this, start here even on a bigger plan: it is the smallest thing that still
enforces every gate.

**Max** — you can afford a conductor that never writes code, an IDEA phase with
its own artifact, and three reviewers in parallel instead of one. This is the
blueprint's "start with nine", plus `qa-runner` and `security-auditor` because
verification that produces no evidence is not verification.

**Max 20x** — you can afford specialists per surface (`data-architect`,
`api-designer`, `ui-designer`, `security-architect`, `devops-planner`), a
five-lens verify fan-out, three levels of debate including agent teams, and a
monthly report built on OpenTelemetry rather than anecdote.

You can change your mind:

```bash
~/.iptcvd-pipeline/install.sh --plan pro --target .   # switches tiers
```

A tier change backs up and removes the agents, skills and rules the old tier
owned and the new one does not, then re-renders `CLAUDE.md` and
`settings.json`. Your `PROFILE.md`, `agent-memory/` and `docs/specs/` are left
alone.

---

## The three-step setup

### 1. Install

```bash
~/.iptcvd-pipeline/install.sh --plan <pro|max|max20x> --target .
```

Detects your stack, scaffolds `.claude/` and `docs/`, records the chosen tier in
`.claude/state/studio.json`, and writes `docs/setup/PROFILE.md` with its best
guesses. Anything it could not determine is marked `NEEDS_REVIEW`. Existing
files are backed up to `.claude/.backup-<timestamp>/`; `CLAUDE.md` is never
overwritten.

### 2. Confirm the profile

Open `docs/setup/PROFILE.md`. Fill every `NEEDS_REVIEW` field, then **run every
command in the table yourself** and record the exit code in the verification log.

> A field is not confirmed until its command has executed.

Two traps the installer will flag but cannot fix for you:

- **Watching test scripts.** If `npm test` starts a watcher, the output-filter
  hook will hang. You need the non-interactive form (`vitest run`, `jest --ci`,
  `--watch=false`).
- **Lint vs format.** The post-edit hook wants the command that *fixes*, not
  the one that *checks*.

### 3. Configure

```bash
~/.iptcvd-pipeline/configure.sh --target .
```

Substitutes the placeholders throughout `.claude/`. **It refuses to run while
`NEEDS_REVIEW` is present.** That refusal is the point: a half-configured hook
that silently matches nothing is worse than no hook at all.

If you genuinely want to proceed early, `--allow-incomplete` leaves the
unconfigured hooks inert *and loud* — they warn on stderr rather than passing
quietly.

`configure.sh` reads the installed tier and prunes the UI-only pieces when your
profile says the project has no UI. On Pro that is three files; on Max 20x it is
eleven.

---

## Verifying the install

```bash
~/.iptcvd-pipeline/verify.sh --target .
```

Exercises every hook with synthetic input, checks the installed inventory
against your tier's manifest, flags any agent left behind by a tier switch,
estimates your skill-listing cost against the cap, and audits which hooks fire
on which events — including third-party ones. Expect roughly 38 checks on Pro,
45 on Max, 64 on Max 20x.

**A hook you have not watched fire is a hook you do not have.**

Then, inside Claude Code:

```
/doctor      # duplicate agent names, oversized memory, skill listing overflow
/hooks       # confirm all five registered
/context     # pre-prompt total should sit under ~15% of the window
```

### Eight test layers

| Script | Checks | Run it |
|---|---|---|
| `./verify.sh --target .` | one **install** — hooks fire on the spellings that ship, inventory matches the tier, budget, hook audit, ratchet, hook integrity | after every install, configure, or hook edit |
| `./test/hooks.sh` | what the hooks **do** — every bypass shape, both doors, exit-status preservation, and the documented phase sequence end to end | after touching any hook |
| `./test/profile-validation.sh` | what `configure.sh` must **refuse** — values that would corrupt or subvert a hook | after touching the profile or configure |
| `./test/ratchet.sh` | that the ratchet **ratchets** — shrink allowed, growth refused, new crossings refused | after touching the ratchet |
| `./test/coverage.sh` | that the coverage gate reads the **total** — five runners' real output, each with a per-unit decoy above it | after touching the coverage gate |
| `./test/mutation.sh` | that the suites above can **fail** — every shipped defect put back, one at a time | after adding or changing an assertion |
| `./qa.sh` | the **templates** — frontmatter, manifest integrity, placeholder coverage, guard hygiene, docs drift | before changing this repo, and in CI |
| `./test/integration.sh` | the **lifecycle** — six stacks, upgrade, tier switch, uninstall, degraded environments | before a release |

`test/hooks.sh` is the one that matters most and the one that did not exist.
It builds a synthetic project, substitutes the placeholders the way
`configure.sh` would, and asserts 114 behaviours — the bypass matrix above,
twenty shell-write forms that must block, eleven everyday commands that must
not, the two allowlist-disarm tokens, the filter's exit status in both
directions, that the two `Bash` hooks have no command in common, and that both
measurement logs actually get written.

Its own assertions are mutation-checked, and that check is automated rather
than remembered. `bash qa.sh --mutate` copies the tree once per mutation,
reintroduces a defect this repository has actually shipped, and requires the
named suite to go red — 22 of them, covering the gate, both doors, the
evidence filter, both ratchets and the template contract. It reports three
outcomes, and the third is the one that matters: a mutation whose anchor text no
longer exists is **BROKEN**, not caught. An un-applied mutation runs a clean
tree and is of course green, and counting that as a pass is how a mutation suite
rots into a very slow way of running the tests twice.

It earned its place on the first run: **5 of 22 mutations escaped**, in a suite
set that had been green the whole time.

| Escape | What it turned out to be |
|---|---|
| `filter-exit-status` | `qa.sh` checked for `PIPESTATUS` with a bare `grep`, which matched the **comment explaining why PIPESTATUS is needed**. The exit-status fix could be deleted and the shape check stayed green. It now strips comments first, as two neighbouring checks already did |
| `gate-keystroke-answer` | the one-token case passed `--problem "x" --red "y"`, and the **red** guard refused first. The problem-length guard had no coverage at all; each field is now poisoned with the other left valid |
| `gate-empty-problem` | omitting a flag entirely was never tested — and once it was, it turned out the dense-length guard refuses it anyway. The `MISSING` check buys the *diagnosis*, not the refusal, so the test now asserts the message |
| `profile-accepts-pipe` | an **equivalent mutant**: `check_row_shape` refuses the malformed row before the value-level guard is reached, so behaviour genuinely did not change. The mutation was re-pointed at the guard that enforces the rule |
| `profile-accepts-newline` | the CR/newline guard had **no test whatsoever** — and it is the guard whose own first version was broken (`"$(printf '\n')"` collapses to the empty string, making the pattern `**`, which matched every value there is). The fix for the false-green incident this repo documents had itself shipped untested |

Three real gaps, one test passing through the wrong guard, one equivalent
mutant. That ratio is normal, and it is the argument for the harness: none of
the five is visible from a green run, and four of them are in assertions
somebody wrote *specifically* to catch the defect that walked past them.

Writing the CR case also caught the harness lying again, which is the failure
mode this repo keeps rediscovering. `setfield.py` read the injected value with
Python's default text mode — **universal newlines**, which silently rewrites a
lone carriage return to a newline. The case was therefore writing a newline
into the profile row, testing something else entirely, and reporting that
`configure.sh` accepts a value it in fact rejects. The product was correct; the
test was not. Same shape as the MSYS path rewriting documented in that suite,
and the reason every value there now travels through a file opened with
`newline=""`.

All of it runs in CI across 11 jobs. Three of them run the hook suite three
ways — with `jq`, without `jq`, and with both `jq` and `python` **present on
PATH and exiting 127** — because each hook has three JSON parsers and only
**one** of them runs on any given machine. The branch CI takes and the branch
your laptop takes have to agree byte for byte; a filter bug confined to the `jq`
branch is invisible locally and red on every push.

The third of those is the configuration that found real bugs, and it is the one
usually left out. `command -v jq` proves a file is on PATH, not that it runs — a
jq built against the wrong libc, a shim, a half-finished install all satisfy it
and then fail. Every parser chain here therefore falls *through* a failure
rather than returning from it.

`qa.sh` is deliberately strict about failures that are invisible at install time
and expensive later: an agent whose `name:` does not match its filename never
gets delegated to, a duplicate name silently shadows one definition, and a
placeholder nothing substitutes leaves a hook inert forever.

---

## What gets installed

```
.claude/
├── agents/          the tier's roster
├── skills/          the tier's playbooks
├── rules/           path-scoped standards, loaded only when a match is read
├── hooks/           gate-check, bash-gate, filter-output, post-edit, doc-check
├── scripts/         gate.sh, hook-integrity.sh, ratchet.sh, coverage-gate.sh
├── agent-memory/    committed — this is the institutional memory
├── workflows/       Max 20x only
└── state/           gate.json, studio.json, doc-map.json, hooks.sha256,
                     gate-log.tsv, size-baseline.tsv, coverage-floor.txt
docs/
├── setup/           PROFILE.md
├── adr/             TEMPLATE.md
├── specs/<slug>/    idea, plan, critique, acceptance, verification, evidence/
├── design/          direction, tokens, components   (Max, Max 20x)
├── api/             generated reference             (Max 20x)
├── runbooks/        ops procedures                  (Max 20x)
├── handoff/
└── reports/
.github/workflows/   ci.yml (+ e2e.yml if HAS_UI) — written by /ci-scaffold
CLAUDE.md            (or CLAUDE.studio.md if you already had one)
```

### Pro — 7 agents

| Agent | Model | Memory | Writes | Job |
|---|---|---|---|---|
| `planner` | sonnet | project | docs | Scope, acceptance criteria, file map, rejected alternatives |
| `critic` | **opus** | project | docs | Attacks the plan before any code exists. Once per feature. |
| `test-designer` | sonnet | project | tests | Failing tests from the acceptance criteria |
| `implementer` | sonnet | project | source | Turns red tests green, nothing more |
| `reviewer` | sonnet | project | none | Correctness, security, contract drift, standards |
| `qa-runner` | sonnet | local | evidence | Real browser, every breakpoint. Playwright scoped inline. |
| `doc-writer` | sonnet | project | docs | Docs, ADRs, changelog, handoff |

Phases: `plan → critique → test → create → verify → document`.

Discipline knowledge lives in `.claude/rules/`, not in separate agents — which
is how one `implementer` covers front-end and back-end. Rules load automatically
based on which files are touched, and cost nothing until then.

### Max — 11 agents

Adds `conductor` (owns phase order, never writes code) and `product-analyst`
(the IDEA phase), and splits the Pro roster into the blueprint's named
specialists: `system-architect`, `red-team-critic`, `backend-engineer`,
`frontend-engineer`, `code-reviewer`, `security-auditor`.

Phases: `idea → plan → test → create → verify → document`.

Verify dispatches `code-reviewer`, `security-auditor` and `qa-runner` in
parallel from one call. Adds `/debate` and `/design-tokens`, and the
`database.md` rule.

### Max 20x — 24 agents

| Phase | Agents |
|---|---|
| Orchestration | `conductor` |
| Idea | `product-analyst`, `ux-researcher` |
| Plan | `system-architect`, `data-architect`, `api-designer`, `ui-designer`, `security-architect`, `devops-planner`, `red-team-critic` |
| Test | `test-designer`, `a11y-perf-budgeter` |
| Create | `backend-engineer`, `frontend-engineer`, `db-engineer`, `infra-engineer` |
| Verify | `code-reviewer`, `security-auditor`, `qa-runner`, `perf-a11y-auditor`, `seo-auditor` |
| Document | `doc-writer`, `memory-curator`, `report-generator` |

Six phase playbooks (`/phase-idea` … `/phase-document`) instead of one
`/feature`. Adds the `seo.md` rule, `/studio-report` with three Python scripts,
and telemetry keys wired but switched off.

Model routing follows one policy across every tier: **haiku** for mechanical
scan work, **sonnet** for building, **opus** for irreversible decisions and
adversarial reasoning. The installer prints which agents are on Opus, because
that is where the cost is.

### The six hooks — identical on every tier

| Hook | Event | Behaviour on misconfiguration |
|---|---|---|
| `gate-check` | PreToolUse (Edit/Write) | **Fails closed** for protected source, open for everything else |
| `bash-gate` | PreToolUse (Bash) | **Fails closed** for a parse failure naming a guarded root; open otherwise |
| `filter-output` | PreToolUse (Bash) | Fails open — a broken filter must never block work |
| `post-edit` | PostToolUse (Edit/Write) | Fails open |
| `doc-check` | Stop | Fails open |
| `session-log` | SessionStart | Fails open — a recorder that can block a session start is one you delete |

Five of those guard. The sixth only counts, and it is the newest thing here
because of an argument this repo lost with itself: the two largest token levers
in the pipeline were asserted in prose and measured by nothing, which is the
same defect as an 800-line rule that thirteen files quietly ignore. `bash-gate`
is listed above `filter-output` in `settings.json` and that is **not** an
execution order — Claude Code runs all matching hooks in parallel and does not
document which decision wins when one returns `deny` and another `allow`.
Nothing here depends on it. The two are safe together because their domains do
not overlap, which is a property, and `test/hooks.sh` §10b tests it.

`bash-gate` is the other door. `gate-check` is registered on `Edit|Write`, so
without it the entire pipeline is one `sed -i` away from irrelevant — and an
agent writing through the shell is not an exotic case, it is the common one. It
does not re-implement the gate: it extracts the write *targets* from the command
and hands each to `gate-check.sh`, so there is one rulebook and one block
message, and adding a key covers both doors at once. It recognises redirects
(`>`, `>>`, `>|`, `&>`), `sed -i`, `perl/ruby -i`, `tee`, `sponge`, `cp/mv/ln/
rsync/install` (including `-t DIR`), `rm`, `dd of=`, `git checkout/restore/
apply/mv/rm/clean`, `patch`, awk redirects, interpreter writes, and the
manifest-rewriting forms of `npm`/`pnpm`/`yarn`/`composer`/`cargo`/`go`/`pip`.
It fails **open** on anything it cannot parse, because a wrong block costs a
retry on every unrelated command — with one exception: a payload it cannot parse
at all that plainly names a guarded root is refused rather than guessed at.

There is deliberately **no exemption list** in it. The obvious one — keep the
pipeline's own tooling runnable while the gate is closed — is matched by
substring against a string the caller fully controls, so appending a trailing
comment disables the whole shell gate in one token:

```bash
sed -i 's/x/y/' src/app.ts   # .claude/hooks/
```

It was also unnecessary: the scripts are invoked as `bash .claude/scripts/…`,
and `bash` is not a program the hook extracts targets from. The safest allowlist
is the one you can delete. Both forms are in `test/hooks.sh`.

`filter-output` is the largest token saving here: it rewrites test and build
commands so only failures return to the model, turning tens of thousands of
tokens into hundreds. It also filters the profile's dependency-audit command,
watching for `vulnerabilit` in addition to `FAIL`/`ERROR` — an audit finding
doesn't announce itself the way a test failure does, and a filter that only knew
the test vocabulary would quietly eat a real high/critical finding.

Heavy MCP servers are declared **inline in one agent's frontmatter**, never in
`.mcp.json`: Playwright on `qa-runner`, Chrome DevTools on `perf-a11y-auditor`.
Those tool definitions never enter your main session. This is worth several
thousand tokens per session and is the reason this is an install script rather
than a Claude Code plugin — plugin subagents ignore the `mcpServers` field.

---

## The gate carries the plan, not just its name

A gate whose whole state is `{"phase":"create"}` certifies that a plan exists.
It does not certify what the plan said — and the two phases with an artifact but
nothing gate-readable are reliably the two that get skipped. IDEA, because
stating the problem feels like overhead once you can already see the fix. TEST,
because writing the test *after* the code still produces a green suite, and a
test that has never failed reads as coverage while proving nothing.

So the gate carries the answers:

```bash
bash .claude/scripts/gate.sh create \
  --problem "National finance summed every chapter's dues into the total" \
  --red     "DuesTest::national_excludes_chapter fails: expected 0, got 41250"
```

| Key | Required when | Answers |
|---|---|---|
| `problem` | every guarded edit | what breaks, and what is out of scope |
| `red` | every guarded edit | the test failing *now*, or `"n/a: <why>"` |
| `reuse` | **creating** a file in a shared-surface directory | reuse X / extend X / new because X cannot Y |
| `deps` | editing a dependency manifest | what you checked first, and why it does not cover this |

`gate.sh` refuses a keystroke: a one-word `--problem`, or a bare `--red n/a`
with no reason, is rejected. The hook cannot judge whether a change is testable,
so it does not try — it requires the answer to be **stated**, and the reviewing
agent checks the stated answer against the diff.

Opening the gate belongs to the **TEST** phase, because that is the phase that
produces the evidence `--red` wants. Every later transition inside the slice
uses `advance`, which carries the notes forward:

```bash
bash .claude/scripts/gate.sh plan                 # source stays blocked
bash .claude/scripts/gate.sh test
bash .claude/scripts/gate.sh create --problem "…" --red "…"   # source opens
bash .claude/scripts/gate.sh advance verify       # stays open for review fixes
bash .claude/scripts/gate.sh advance document     # closes
bash .claude/scripts/gate.sh idle                 # re-arms for the next change
```

`advance` exists because a phase change is not a new plan. Writing
`{"phase":"verify"}` by hand — which is what "update gate.json: set phase to
verify" means when read literally — **erases** `problem` and `red`, so the gate
slams shut on a slice that had answered everything correctly, one phase after
the mistake was made. Every phase skill now calls `gate.sh`, and `test/hooks.sh`
walks the whole documented sequence to prove it still opens and closes.

`reuse` exists because "reuse what is already here" stays advisory until
something asks. Declare the directories where near-duplicates breed —
components, pages, services — as **Shared surfaces** in `PROFILE.md`; leave it
blank to switch the gate off, which is a decision rather than a default.
Editing an existing file in them is never gated. Only the birth of a new one.

`deps` exists because a dependency is the most expensive kind of reuse —
transitive packages, a CVE surface, a licence, an upgrade obligation — and the
manifests sit outside every source root, so both hooks waved them through.
Lockfile restores (`npm ci`, `composer install`) and `npm audit fix` stay
ungated: blocking a cold checkout, or the remediation path for a known CVE,
costs more than the note it would collect.

### The gate cannot be the thing that guards the gate

`gate-check.sh` allows every write under `.claude/` — it must, or a broken
install would be unrepairable from inside a session. The cost is that the
cheapest bypass in the whole pipeline is:

```bash
echo 'exit 0' >> .claude/hooks/gate-check.sh
```

Afterwards every hook still "runs", every check still reports green, and nothing
in the working tree looks wrong. So the guard moves one level out.
`hook-integrity.sh` records a checksum of every hook and of `settings.json` into
`.claude/state/hooks.sha256` at configure time, and the `pipeline-guards` CI job
checks it on every push. A session may still edit a hook — that is legitimate —
but the edit is now a visible diff to a checksum file rather than four
characters nobody reads twice. Re-record deliberately:

```bash
bash .claude/scripts/hook-integrity.sh --update   # commit BOTH together
```

### A standard nothing measures is a preference

`.claude/rules/*.md` state a file-size bar and a coverage minimum. Written down
is not enforced. On the codebase this pipeline was extracted from, the 800-line
bar had been in the standards for months and was measured by nothing: 13 files
sat over it, topping out at 2,100 lines — and 28 of that repo's 30
`react-hooks` violations lived inside a single 1,476-line file. That is not a
coincidence. Nobody refactors a file they cannot hold in their head, so defects
accumulate where the lines do. The 80% coverage minimum was worse: every CI job
set `coverage: none`, so the number had **never once been produced**.

Two scripts turn both into numbers, and both are ratchets rather than cleanups —
which is what makes them adoptable on a tree that is already over the bar:

```bash
bash .claude/scripts/ratchet.sh              # file size; CI runs this
bash .claude/scripts/ratchet.sh --update     # re-record, deliberately
bash .claude/scripts/ratchet.sh --list       # what is over the bar, largest first

<test command> --coverage | tee coverage.txt
bash .claude/scripts/coverage-gate.sh coverage.txt
```

| | |
|---|---|
| a baselined file | may **shrink**, never grow |
| an unlisted file | may not cross the bar at all |
| the bar itself | lives in the baseline file, so changing it is a committed diff somebody can object to — not an edit to a tool |
| coverage | fails **below** the floor, and also fails far **above** it, asking for the floor to be raised. A floor that drifts far below reality certifies nothing while still looking like a gate |
| a runner that prints no total | is **refused**, never guessed at — see below |

That last row was not a design principle; it was a bug report. `coverage-gate.sh`
parses five ecosystems, and until `test/coverage.sh` existed exactly one of them
had been exercised — against text written to match the pattern it was testing.
Checked against real output, four of the five were wrong, and two were wrong in
the shape that matters:

| | was | actually |
|---|---|---|
| `go test -cover ./...` | reported the **last package's** figure as the project total — 50.0% measured on a tree whose real total was 28.6%, and which package sorts last is arbitrary | refused: Go prints no aggregate there, so the gate names `go tool cover -func`, which does |
| SimpleCov's `SimpleFormatter` | reported the **last file's** figure — 100.0% | refused: per-file rows, no total |
| `go tool cover -func` | rejected — Go's only genuine total | parsed |
| PHPUnit | claimed in a comment, matched by nothing | parsed; only **Pest** prints `Total: n %` |
| SimpleCov (default) | looked for `Line Coverage: 91.2%`, which SimpleCov has never printed | parsed: `Line coverage: 123 / 456 (26.97%)` |

A refusal is recoverable. A confident wrong number becomes the floor, and a
floor is the one figure nobody re-derives later.

`configure.sh` records the size baseline against the tree as it is on the day
you install, so the bar applies to what happens next rather than to a backlog
nobody agreed to fix this week. The coverage floor starts **unset** and reports
the real number rather than failing a build over a figure nobody has seen; arm
it by committing that number. An unarmed floor still annotates the CI run,
because nobody reads stdout in a green job.

Regenerating either baseline is allowed. The point was never that it is
impossible — it is that it is **visible**. Without a ceiling, the cheapest way
past a hard limit on a legacy tree is to delete the limit, and that happens
quietly.

### Whether the pipeline is followed is now a query

Every gate decision appends a row to `.claude/state/gate-log.tsv`:

```bash
bash .claude/scripts/gate.sh log
```

Blocks trending down across features means the workflow is being internalised.
Blocks flat and high means the gate is in the wrong place. Source edits with
**zero** blocks and no `gate.sh create` on record means a bypass nobody has
found yet — and that last line is the one worth watching, because it is the only
signal that separates "the pipeline is followed" from "the pipeline is inert".

### And so is what the token levers actually did

Two levers here move more tokens than everything else combined, and until
recently both were prose:

```bash
bash .claude/scripts/savings.sh
```

**Output filtering** now records one row per test, build, typecheck and audit
run — bytes in, bytes returned, exit code. Both raw logs are **gitignored and
machine-local**: they are instrument readings, not the record. In this repo's own suite a 400-line
test run measured **14,752 bytes in, 134 bytes returned**, with the failure and
the exit status both intact. That is the shape of number `DESIGN-RATIONALE` §14
calls defensible: a mechanism, a count, and a measurement. The old claim was
"tens of thousands of tokens become hundreds", which is the same sentence
without any of the three. The logged columns are **bytes**, because bytes are
what a shell can count; `savings.sh` converts at ~4 bytes/token and labels that
conversion indicative, which you should too.

**`/clear` between phases** is the other one, and it is the awkward case: it is
the largest lever in the pipeline and **no hook can enforce it**, because no
hook can make somebody type `/clear`. So it is measured instead — the same move
as `hook-integrity.sh`, which does not prevent a hook edit and instead turns it
into a diff somebody sees. `session-log` records how each session began and
what the gate was doing at the time, which makes the interesting ratio
readable:

| | |
|---|---|
| clears >> compacts | the lever is being pulled; a feature costs about one window per phase |
| compacts >> clears | the window is filling before it is dropped — the whole conversation re-sent at cache-read price instead of discarded at zero |
| compacts landing mid-`create` | that feature overran its window; the phase is too big, or the briefing was too thin |

Neither log is read by any gate, and deleting either is safe. They are
measurements, not state.

#### When someone else works on the same repository

The raw logs stay machine-local — they are per-run rows, and committing them
would mean a conflict on nearly every push for a file nobody reads during a
merge. What gets shared is the monthly **total**:

```bash
bash .claude/scripts/savings.sh --record      # this month
bash .claude/scripts/savings.sh --record 2026-08
```

That writes one row to `docs/reports/savings/<you>.tsv` — **one file per
developer**, named from your git identity, so two people never write the same
path and the merge problem does not exist. Commit it. From then on `savings.sh`
prints a per-developer table and a `PROJECT` total, and `/report` uses that
instead of one laptop's numbers.

Re-running `--record` for a month **replaces** that month's row rather than
appending, so regenerating a report twice cannot double the project total.

Solo, none of this happens: nothing is written until you ask, and the scope
line says plainly that the figures are one machine's. The moment a second
file appears, that caveat stops being printed — because it stops being true.
The count is read from the directory, never assumed, which is the only reason
it can be trusted to change.

---

## When *not* to run the pipeline

The pipeline has a floor, and pretending otherwise is how it gets abandoned.
`/feature` dispatches a subagent per phase plus the verify fan-out — on Max 20x
that is ten to twelve fresh context windows. Against a one-line change, that is
two orders of magnitude of overhead for a change that was never going to
benefit from a plan.

**Run `/feature` when** the change has a design question in it, touches more
than one file, changes behaviour anyone could observe, or is a bug fix — bug
fixes go through the pipeline no matter how small, because the failing test is
the whole point.

**Do not run it for** a typo in a string or comment, a log-level change, a
version bump you already decided on, a formatting-only pass, or a revert.

The gate still applies to all of those, and that is deliberate: it costs two
commands, not two phases.

```bash
bash .claude/scripts/gate.sh test
bash .claude/scripts/gate.sh create   --problem "Invoice export header said 'Totl'" --red "n/a: string literal, no behaviour to pin"
# ... make the change ...
bash .claude/scripts/gate.sh idle
```

`--problem` has a floor of twelve characters of content, not a sentence quota.
It is cheap on purpose. What it buys is that the trivial change is still on the
record, so `gate.sh log` can tell "a small change" from "a bypass nobody has
found yet" — which is the one signal the log exists to protect.

If you find yourself resenting the two commands, that is worth noticing rather
than working around: it usually means the change is not as trivial as it
looked, or that the gate is guarding a path that should not be guarded. Both
are `PROFILE.md` conversations, not reasons to reach for a hook-skipping commit
flag.

---

## DevSecOps coverage

Session-level rules are advisory the moment the session ends. `devops.md` and
two skills exist so this pipeline's standards are also checked by something that
runs whether or not anyone is in a Claude Code session:

- **`.claude/rules/devops.md`** — loads whenever a workflow, Dockerfile, or
  compose file is touched. Covers promotion-gated triggers, ephemeral test
  infrastructure, reading full (not truncated) audit output, severity-gated
  dependency scanning, the static-analysis-baseline pattern for suppressing an
  existing false-positive backlog without lowering the check, and treating an
  unfixable pinned-dependency CVE as tracked debt rather than a silenced gate.
- **`/ci-scaffold`** — run once, early. Reads the confirmed commands in
  `docs/setup/PROFILE.md` and writes a real `.github/workflows/ci.yml` (lint,
  type-check, dependency audit, test, build) plus `e2e.yml` if the project has a
  UI and a browser test runner. It only proposes commands already confirmed in
  the profile, never a guessed one.
- **`/security-audit`** — run any time, not only at the verify gate. Runs the
  profile's dependency-audit command in full, scans the diff for
  committed-secret patterns, and checks changed authorisation code against two
  recurring failure classes: a raw permission check bypassing a resolver that
  exists specifically to apply an override, and a query that crosses a
  tenant/owner boundary without a server-side scope filter.

`security.md`'s **Authorisation source of truth** and **Cross-tenant scope**
rules are the same two patterns generalised — `/security-audit` is the callable
check, the rule is what the reviewing and implementing agents load automatically
while a session is open.

---

## Daily use

### Pro

```
/ci-scaffold                        # once, early — writes real CI, not just rules
/clear
/feature add invoice CSV export     # → planner writes plan.md; you approve it
run the critique phase              # → critic (opus, once); resolve blockers
/clear
run the test phase                  # → red tests + evidence
run the create phase                # → green tests + evidence
/clear
run the verify phase                # → reviewer, then qa-runner
/security-audit                     # anything touching auth, data scope, or a dependency
run the document phase
/handoff
```

### Max

```
/feature add invoice CSV export     # → conductor takes it from here,
                                    #   one phase and one gate per turn
/debate                             # before approving a plan on the escalation list
/clear                              # after the plan gate and after create
/handoff
```

### Max 20x

```
use the conductor agent to start: add invoice CSV export
/phase-idea → /phase-plan → /debate → /phase-test → /phase-create
            → /phase-verify → /phase-document
/studio-report 2026-08              # month end
```

Three `/clear` calls per feature is not excessive. It is the difference between
a feature costing one context window and costing four.

---

## After install: two things people skip

### Seed the agent memory

`memory: project` writes to `.claude/agent-memory/`, which is **committed to
git** — unlike auto memory, which is machine-local and never reaches a subagent.
One read-only pass per specialist, one per session:

```
Use the system-architect agent to survey this codebase's architecture: module
boundaries, the layering convention actually in use, where business logic
lives, and the three most significant design decisions visible in the code.
Write findings to your agent memory. Modify no file.
```

Repeat for the reviewing, security and implementing agents your tier installed.
Then write `.claude/skills/codebase-map/SKILL.md` from what they found, and
commit `.claude/agent-memory/`. Roughly an hour of wall-clock, and from then on
each agent starts with real knowledge of your code instead of guesses.

### Take a baseline

Read `/usage` immediately before and after your first complete feature — the
*weekly* bar, press `w`. Write it to `docs/reports/baseline.md`.

| Cost per medium feature | What it means |
|---|---|
| under 5% of weekly | Comfortable. Consider widening the verify fan-out. |
| 5–10% | Healthy. Leave it alone for five more features. |
| over 10% | Cut, in this order: narrow the verify fan-out to the critical path, move an Opus agent to Sonnet, merge verify and document. **Never the gates.** |

Without the baseline you cannot tell later whether any change you make is an
improvement or a regression. On Max 20x this matters most: `/studio-report`
compares against `docs/reports/baseline.md`, and with no baseline every saving
it reports is invented.

Record `savings.sh` in the same file, and record it **empty**:

```bash
bash .claude/scripts/savings.sh >> docs/reports/baseline.md
```

An empty filter log on day one is the useful reading, not a missing one. It is
the zero that every later "the filter saved N bytes" is measured from, and it
is also the check that the hooks are firing at all — a filter log still empty
after a week of real work does not mean the filter saved nothing. It means the
hook is not running, and `/hooks` is where to look.

---

## Recommended companions

Not installed by this repo — they are Claude Code plugins and MCP servers you
add yourself. Keep the list short; every one has a standing token cost.

```bash
/plugin install security-guidance@claude-plugins-official
/plugin install <language>-lsp@claude-plugins-official   # install the LSP binary first
claude plugin add anthropic/frontend-design              # if the project has a UI
claude mcp add context7 -s user -- npx -y @upstash/context7-mcp@latest
```

Code-intelligence plugins are a token optimisation, not a convenience: one "go
to definition" replaces a grep plus reading three candidate files.

Two always-on MCP servers maximum. Everything heavier gets scoped to a single
agent's frontmatter, the way `qa-runner` does with Playwright.

### Design-taste skills

A family of third-party skills exists to stop AI-generated UI regressing to the
same generic default. They all install as ordinary `.claude/skills/<name>/`
entries and are fully compatible with this pipeline — they supply *taste*,
which is the one thing the pipeline deliberately does not encode.

| Skill | Best at | Licence |
|---|---|---|
| [`anthropic/frontend-design`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/frontend-design) | Committing to an aesthetic direction before writing code | Official |
| [`pbakaus/impeccable`](https://github.com/pbakaus/impeccable) | Design-system enforcement, 59 detector rules, live in-browser editing | Apache-2.0 |
| [`nextlevelbuilder/ui-ux-pro-max-skill`](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | Searchable style / palette / font-pairing databases and a design-system generator | MIT |
| [`nxpatterns/claude-taste-skill`](https://github.com/nxpatterns/claude-taste-skill) | A lighter all-rounder, with per-style variants | MIT |
| [`emilkowalski/skills`](https://github.com/emilkowalski/skills) (`emil-design-eng`) | Motion and micro-interaction: easing, duration, what should *not* animate | MIT |

**Take two, then at most one more.** `frontend-design` for direction and
`emil-design-eng` for motion cover the two things the pipeline is genuinely
missing and overlap almost nothing. Then add **either** Impeccable (enforcement)
**or** UI-UX Pro Max (generation) — never both. They contradict each other: one
rejects Inter on principle, the other ships a font-pairing database that
recommends it, and unlike disagreeing *agents* there is no `/debate` judge for
skills. The arbitration has to happen at install time, by you.

| Tier | Skills installed | Add |
|---|---|---|
| Pro | 7 | `frontend-design` |
| Max | 9 | `frontend-design` + `emil-design-eng` |
| Max 20x | 14 | those two, plus at most one system skill |

Four things make this safe, and the repo implements all four:

- **Direction is locked in `CLAUDE.md`.** Every tier's constitution ships a
  `frontend-direction` block. `CLAUDE.md` loads in full, every session, ahead of
  any skill body — so your direction is what the skills decorate rather than
  decide. `configure.sh` strips the block on projects with no UI.
- **The token layer is the contract.** `frontend.md` now says design tooling
  writes `{{TOKEN_FILE}}`, never literals into components — a generated
  component carrying raw values is the same review blocker as a hand-written
  one. `code-reviewer` enforces it.
- **The gate does not move.** Impeccable's live editing will be blocked outside
  the `create` phase. That is the gate working. Iterate during CREATE, or in a
  scratch directory outside your source roots — never by widening
  `gate-check.sh`.
- **`verify.sh` measures the cost.** It estimates the skill-listing total,
  warns as you approach the cap Claude Code truncates at, names every
  third-party skill, and flags two hooks firing on the same event and matcher —
  which is what happens when Impeccable's detector lands next to `post-edit.sh`.

```
7. Context budget
  18 skills · ~1185 tokens of listing (estimate)
  third-party skills: emil-design-eng impeccable taste-skill ui-ux-pro-max

8. Hook audit
  PostToolUse   Edit|Write   .claude/hooks/post-edit.sh
  PostToolUse   Edit|Write   .claude/skills/impeccable/hooks/detect.sh  (third-party)
  WARN PostToolUse: multiple hooks on matcher(s) Edit|Write — both fire on every matching call.
```

Studio-owned files and third-party ones stay separable: `install.sh --force`
preserves foreign hooks and foreign skills, and `--uninstall` removes only what
the tier's manifest listed. A design plugin survives a pipeline upgrade, and
rolling one back is a first-class outcome.

**Adopt one at a time and measure it.**
[`docs/DESIGN-STACK.md`](docs/DESIGN-STACK.md) is the full procedure — the
picks, the `/context` and `/doctor` loop, the rollback criteria, and the signal
that actually matters: these skills earn their keep by moving design decisions
*earlier*, into PLAN where they are cheap. If your verify phase is still full of
design findings after adopting one, it is decorating the output rather than
improving the input.

---

## Updating

```bash
cd ~/.iptcvd-pipeline && git pull
cd /path/to/project && ~/.iptcvd-pipeline/install.sh --target . --force
~/.iptcvd-pipeline/configure.sh --target .
~/.iptcvd-pipeline/verify.sh --target .
```

With no `--plan`, the installer reuses the tier recorded in
`.claude/state/studio.json`. It backs up before replacing. Your `PROFILE.md`,
`CLAUDE.md`, `agent-memory/` and everything under `docs/specs/` are left alone.

`--force` never resets `docs/setup/PROFILE.md` — every value in it was confirmed
by running a command, so it is your data. If a newer version of the toolkit adds
a profile field, the installer names it and writes a fresh render alongside as
`PROFILE.studio.md` rather than overwriting yours. To start the profile over,
delete it and re-run.

Always run `verify.sh` after an upgrade. The hooks fail **closed**: an
unconfigured `gate-check.sh` refuses source writes rather than waving them
through, so a half-finished upgrade is loud instead of silent.

### A note on the name

This project was called `claude-studio` before it was IPTCVD Pipeline — the
acronym is the pipeline itself, Idea · Plan · Test · Create · Verify · Document.
The rename deliberately stopped at the surface. Everything you read or type
changed; everything written **into your project** kept its old spelling:

| Still named `studio` | Why |
|---|---|
| `.claude/state/studio.json` | renaming it makes every existing install read as uninstalled on the next `configure.sh` |
| `CLAUDE.studio.md`, `PROFILE.studio.md` | files already sitting in people's repositories |
| `/studio-report` | a command in muscle memory and in `docs/reports/` paths |
| `<!-- studio:… -->` markers | the anchors `configure.sh` uses to rewrite a block idempotently |

A cosmetic rename that breaks working installs is a bad trade. If you want the
internals renamed too, that is a migration with a test, not a find-and-replace.

## Uninstalling

```bash
~/.iptcvd-pipeline/install.sh --target . --uninstall
```

Removes `.claude/agents`, `skills`, `rules`, `hooks`, `state` and `workflows`
after taking a backup. Leaves `docs/`, `CLAUDE.md` and `settings.json` for you
to clean up deliberately.

---

## Customising

`templates/` is a pool of resources plus one manifest per tier:

```
templates/
├── agents/          every agent definition, pooled
├── skills/          every skill, pooled
├── rules/           every path-scoped rule, pooled
├── common/          hooks and docs scaffolding — shared by all tiers
└── tiers/<tier>/
    ├── manifest.conf     which agents, skills and rules this tier installs
    ├── CLAUDE.md.tmpl    the constitution for this tier's phases
    ├── settings.json.tmpl
    ├── gate.json
    └── {agents,skills,rules}/   optional per-tier overrides
```

`install.sh` contains no per-tier logic. To add an agent to a tier, drop the
file in `templates/agents/` and add its name to that tier's `TIER_AGENTS`. The
installer fails before writing anything if a manifest names a resource that does
not exist.

A file in `templates/tiers/<tier>/skills/<name>/` overrides the pooled one of
the same name — that is how `/feature` means a different playbook on Pro and Max
while keeping the same command name.

Two rules of thumb regardless of tier:

- **Add a rule rather than an agent.** Rules are free until a matching file is
  read; agents cost a context window every time they run.
- **Only add an agent when you can name the failure it prevents.** Measure with
  `/usage` before and after.

---

## Known limitations

- The gate hook protects only the source roots named in your profile. Files
  outside them are not gated, by design.
- `bash-gate` fails **open** on shell forms it cannot parse. It does not cover a
  write performed by a script invoked by path (`./tool.sh` that writes source
  internally), or one made inside an interactive editor session. Those remain
  the Edit/Write door's job. The list of what it *does* cover is in the header
  of the hook, and every entry on it is a test in `test/hooks.sh`.
- `hook-integrity.sh` makes disarming the pipeline **visible**, not impossible.
  Anyone with commit access can re-record the manifest. It is defence in depth
  against a silent edit, not a permission system.
- The `permissions.deny` list is defence in depth too, and weaker than it looks:
  the patterns are prefix-matched, so a reworded command sidesteps them and
  `bash -c` sidesteps all of them. Treat the hooks as the control surface and
  the deny list as a guardrail against the one-keystroke version.
- `doc-check` is a blunt instrument: it asks whether `docs/` changed at all, not
  whether the *right* doc changed. The monthly report catches the rest. It
  nudges while a phase is in flight and only blocks once the gate returns to
  idle — an unconditional block on `Stop` means the session cannot hand control
  back at all between the first source edit and the doc being written, which
  costs a full conversation re-send per forced turn and gets the hook deleted.
- The report scripts need `python3`. On Pro and Max you can skip them; on Max
  20x `/studio-report` is a headline feature and will not run without it.
- `tokens.py` falls back to parsing local session transcripts when no OTLP
  collector is configured. That format is internal to Claude Code and changes
  between releases — the script labels those numbers as indicative, and you
  should too. The durable route is a collector.
- Telemetry and agent teams ship **disabled** on Max 20x. Both are opt-in edits
  to `.claude/settings.json`; agent teams cost roughly 7× a single session.
- `/ci-scaffold` proposes a workflow from the profile's confirmed commands; it
  does not run or validate it. Commit it and watch the first real run before
  trusting it as a merge gate.
- The dependency-audit command is detected per ecosystem (`composer audit`,
  `npm`/`pnpm`/`yarn audit`, `pip-audit`, `cargo audit`, `govulncheck`). Some
  are not installed by default for their ecosystem — the profile records the
  command; installing the tool is on you.
- `security.md`'s scope-boundary and resolver-pattern rules describe two
  *shapes* of authorisation bug, not a scanner. They tell a reviewing agent what
  to look for; they do not replace a real SAST or dependency tool.
- Hook **order is not a thing you have.** Claude Code runs all matching hooks in
  parallel and does not document which decision wins when one returns `deny`
  and another `allow`. Nothing in this pipeline depends on an order; if you add
  a `Bash` hook of your own that both rewrites commands *and* refuses some,
  you are the one introducing the race, and `test/hooks.sh` §10b is the shape
  of test that would catch it.
- `savings.sh` reports **bytes** as measured and **tokens** as an estimate at
  ~4 bytes/token. That ratio is a rule of thumb for prose and is optimistic for
  test output, where stack traces, paths and punctuation tokenise worse. Quote
  the byte columns; treat the token column as indicative.
- `session-log` can tell a `/clear` from a compact. It cannot tell a *useful*
  clear from a reflexive one, and it will not notice a session you should have
  cleared and did not — only the ones that started. It is an instrument on the
  lever, not a judge of how you pulled it.
- Claude Code changes weekly. If a frontmatter field or command in here stops
  matching `code.claude.com/docs`, the docs win. Open an issue.

## Further reading

- [`docs/DESIGN-RATIONALE.md`](docs/DESIGN-RATIONALE.md) — the full architecture
  this repo implements: the primitive-selection heuristic, the token cost model,
  the twelve levers, the three debate levels, and the complete 24-agent roster.
  Read this before changing a tier's shape.
- [`docs/DESIGN-STACK.md`](docs/DESIGN-STACK.md) — which third-party design
  skills to add, how to adopt them without loosening a gate, and how to tell
  whether one earned its listing space.
- [`docs/SETUP-SPEC.md`](docs/SETUP-SPEC.md) — the step-by-step build of the Pro
  tier, if you would rather assemble it by hand than run the installer.

## Licence

MIT.
