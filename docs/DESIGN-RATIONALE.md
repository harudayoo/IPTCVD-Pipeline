---
title: "Building an AI Web Development Studio in Claude Code"
subtitle: "A complete architecture and step-by-step build guide for a delegating, debating, self-verifying, self-documenting agent team"
date: "August 2026"
---

> **Scope note.** This is the architecture the repository implements, written
> for the largest configuration. `install.sh --plan max20x` builds the complete
> 24-agent roster described in §3.3; `--plan max` builds §3.2's "start with
> nine" plus `qa-runner` and `security-auditor`; `--plan pro` builds the smaller
> 7-agent pipeline documented in [`SETUP-SPEC.md`](SETUP-SPEC.md).
>
> Every tier shares §10's six hooks, §5's memory architecture, and §2's gate
> discipline unchanged. The tiers differ in roster size and verification
> fan-out, not in how strict the gates are. Read §0.2, §11 and §14 before
> choosing a tier — the honest constraints, the token economics and the
> anti-patterns apply to all three.

# 0. Read this first

## 0.1 What you are actually building

You are not building "a team of AI developers." You are building a **governed pipeline** with four properties, and the agents are only one of the four:

| Layer | What it does | Claude Code mechanism |
|---|---|---|
| **Process** | Forces work through Idea → Plan → Test → Create → Verify → Document, in that order | Skills (phase playbooks) + a gate file + hooks |
| **Roles** | Gives each phase a specialist with narrow tools and a narrow context | Subagents in `.claude/agents/` |
| **Enforcement** | Makes rules non-negotiable rather than advisory | Hooks (`PreToolUse`, `PostToolUse`, `Stop`), permission rules |
| **Institutional memory** | Accumulates what the team learns about *this* codebase | CLAUDE.md, `.claude/rules/`, subagent memory, `docs/`, Obsidian |

The single most important thing to internalise: **CLAUDE.md and agent prompts are advisory. Hooks and permissions are deterministic.** Anthropic's own documentation says Claude reads memory files and tries to follow them, without a guarantee of strict compliance. Every rule that genuinely must hold — "no code before an approved plan," "tests run before a phase closes," "no secrets in a diff" — must be implemented as a hook or a permission rule, not as a sentence in a prompt. Everything else is guidance.

The second most important thing: **more agents is not more quality.** Every agent, MCP server, plugin and skill description has a standing token cost. A pipeline of 24 agents that each burn a fresh context window will be slower, more expensive and *less* coherent than 9 sharp ones. This guide gives you the full roster, then tells you which nine to actually start with.

## 0.2 The honest constraints

Before the design, four things that will shape every decision downstream.

1. **Isolation costs context, and context is the budget.** A subagent starts with a fresh window. It does not see your conversation. Everything it needs must be in its system prompt, in CLAUDE.md, or in the delegation message. Poorly-briefed subagents re-discover the codebase every time, which is the single largest avoidable token cost in a multi-agent setup.
2. **Agent teams are expensive.** Anthropic's cost guidance puts agent teams at roughly seven times the token usage of a standard session when teammates run in plan mode, because each teammate is a separate Claude instance with its own window. Use them for genuine parallel exploration, not for sequential work.
3. **MCP servers tax every session.** Community measurements put Playwright at roughly 5k tokens of tool definitions, Chrome DevTools at 5–6k, Figma at 3–4k. Five servers can cost tens of thousands of tokens before you type anything. Tool search defers most of this, but the discipline still matters: skills cost roughly a hundred tokens at session start; MCP servers cost thousands.
4. **"Done" is a claim, not evidence.** The failure mode that kills spec-driven setups is accepting an agent's assertion of completion. Every gate in this design demands an artifact — a passing test run, a screenshot, a report file — not a sentence.

---

# 1. Choosing the right primitive

Claude Code offers seven ways to extend behaviour. Picking the wrong one is the most common architectural mistake, so this table is the reference you should return to whenever you are tempted to add something.

| Primitive | Lives in | Loaded | Use it for | Do **not** use it for |
|---|---|---|---|---|
| **CLAUDE.md** | `./CLAUDE.md`, `~/.claude/CLAUDE.md` | Every session, in full | Facts true in every session: build commands, layout, hard conventions | Procedures, long checklists, anything phase-specific |
| **Rules** | `.claude/rules/*.md` | Every session, or only when matching files are touched (`paths:` frontmatter) | Discipline standards scoped to a directory: API rules for `app/Http`, component rules for `resources/js` | Global policy (that is CLAUDE.md) |
| **Skills** | `.claude/skills/<name>/SKILL.md` | On demand, when invoked or matched | Repeatable procedures: the phase playbooks, report generators, release checklists | Facts you need in every turn |
| **Subagents** | `.claude/agents/<name>.md` | On delegation, fresh context | Bounded specialist work whose intermediate noise you never want to see | Work needing tight back-and-forth with you |
| **Hooks** | `settings.json`, agent/skill frontmatter | Deterministically, on lifecycle events | Enforcement, formatting, output filtering, gate checks | Anything requiring judgement |
| **Agent teams** | Experimental, env-gated | On request | Parallel exploration where workers must argue with each other | Sequential work, same-file edits |
| **Workflows** | `.claude/workflows/*.js` | On invocation | Fan-out over many items with codified orchestration you can rerun | Small tasks; anything needing mid-run input |

### The selection heuristic

Ask, in order:

1. *Must this be true in every single session?* → CLAUDE.md (and keep it under 200 lines).
2. *Is it true only when touching certain files?* → a path-scoped rule.
3. *Is it a procedure with steps?* → a skill.
4. *Does running it produce output I never want in my main context?* → a subagent.
5. *Must it happen regardless of what Claude decides?* → a hook.
6. *Do several independent investigators need to challenge each other?* → an agent team.
7. *Is it the same operation across 50+ items?* → a workflow.

If two answers apply, prefer the cheaper one. The ordering above is roughly cheapest to most expensive.

## 1.1 Token cost model of the extension layer

Rough, order-of-magnitude figures to plan against. Verify your own numbers with `/context` and `/usage`.

| Item | Cost at session start | Cost when used |
|---|---|---|
| CLAUDE.md line | ~10–15 tokens, every session | — |
| Path-scoped rule | 0 until a matching file is read | Full file |
| Skill | ~50–150 tokens (name + description in the listing) | Full body, then persists for the session |
| Subagent definition | ~30–80 tokens (name + description) | Its own full context window |
| MCP server | 2k–6k tokens of tool definitions (reduced by tool search) | Per-call results |
| Plugin | Sum of its skills, agents, hooks and MCP servers | Varies |

Two consequences worth acting on immediately:

- **A skill's body persists once invoked.** It stays in context for the rest of the session. Write skills as standing instructions, keep them under ~500 lines, and push reference material into sibling files that load only when needed.
- **The skill listing has a budget.** Claude Code caps how much of the name-and-description listing enters context (about 1% of the context window by default). Install 300 community skills and your descriptions get truncated, which silently breaks auto-triggering. Curate ruthlessly.

---

# 2. The IPTCVD framework, mapped to real mechanics

Your proposed framework — **Idea → Plan → Test → Create → Verify → Documentation** — is sound, and the ordering of *Test before Create* is its strongest feature. It makes the acceptance criteria a written artifact that exists before any implementation, which is exactly what stops an agent from grading its own homework.

Below, each phase gets: an owner, required inputs, a required output artifact, and an exit gate. The gate is the part that matters. **No phase closes on an assertion; each closes on a file.**

## 2.1 Phase definitions

### Phase 1 — IDEA
- **Owner:** `product-analyst`, with `ux-researcher` when there is a user-facing surface.
- **Input:** your raw request.
- **Output:** `docs/specs/<slug>/idea.md` — problem statement, who it is for, in-scope / out-of-scope, success metrics, open questions.
- **Gate:** open questions list is empty or explicitly deferred with a named owner. You approve.
- **Permission mode:** plan (read-only).

### Phase 2 — PLAN
- **Owner:** `system-architect`, drawing on `data-architect`, `api-designer`, `ui-designer`, `security-architect`, `devops-planner` as the surface demands.
- **Input:** approved `idea.md`.
- **Output:** `docs/specs/<slug>/plan.md` + one ADR per irreversible decision in `docs/adr/NNNN-*.md`.
- **Gate:** `red-team-critic` has filed `docs/specs/<slug>/critique.md` and every finding is either resolved in the plan or explicitly accepted with a reason. You approve.
- **Permission mode:** plan.

### Phase 3 — TEST
- **Owner:** `test-designer`, with `a11y-perf-budgeter` on UI work.
- **Input:** approved `plan.md`.
- **Output:** `docs/specs/<slug>/acceptance.md` (the test matrix in EARS-style "when X, the system shall Y" form) **plus actual failing test files committed to the repo**.
- **Gate:** the test suite runs and the new tests fail for the right reason. That failing run is captured to `docs/specs/<slug>/evidence/tests-red.txt`.
- **Why this matters:** a written test matrix is a promise; a red test run is a contract. Only the second one is falsifiable.

### Phase 4 — CREATE
- **Owner:** `backend-engineer`, `frontend-engineer`, `db-engineer`, `infra-engineer` — one owner per file set, never two agents in one file.
- **Input:** approved plan + red tests.
- **Output:** the implementation.
- **Gate:** the previously-red tests are green, lint and type checks pass, and the diff touches only files the plan named. Captured to `evidence/tests-green.txt`.

### Phase 5 — VERIFY
- **Owner:** `code-reviewer`, `security-auditor`, `qa-runner`, `perf-a11y-auditor`, `seo-auditor` — run in parallel, each read-only.
- **Input:** the diff.
- **Output:** `docs/specs/<slug>/verification.md` with severity-ranked findings, plus browser evidence (screenshots at each breakpoint, console log, network trace).
- **Gate:** zero criticals; every warning triaged. Findings that become work re-enter at Phase 3, not Phase 4 — a bug fix gets a failing test first.

### Phase 6 — DOCUMENT
- **Owner:** `doc-writer`, then `memory-curator`.
- **Input:** everything above.
- **Output:** updated `docs/` (API reference, runbook, changelog, ADR index), an updated `docs/handoff/<date>-<slug>.md`, and pruned agent memory.
- **Gate:** the docs-staleness check passes — no source file changed in this diff has a doc that is now older than it without an explicit exemption.

## 2.2 The gate file

Phases need a machine-readable state so hooks can enforce them. One small JSON file does it:

```json
// .claude/state/gate.json
{
  "feature": "invoice-export",
  "phase": "plan",
  "approved_phases": ["idea"],
  "spec_dir": "docs/specs/invoice-export",
  "owner_files": ["app/Services/Invoice/**", "resources/js/invoices/**"],
  "updated_at": "2026-08-04T09:14:00+08:00"
}
```

Everything downstream — the write-blocking hook, the report generator, the handoff writer — reads this file. It is the spine of the whole system, and it is twelve lines.

## 2.3 Where the framework needs adjusting

Two honest amendments to your framework, based on how the tooling actually behaves:

1. **Verify is not one step, it is a fan-out.** Security, performance, accessibility, SEO and correctness are genuinely independent lenses. Run them as parallel subagents from one dispatch; a single reviewer anchors on the first class of problem it finds and stops looking.
2. **Documentation must be a gate, not a phase.** If documentation is the last phase, it is the phase that gets skipped when you are tired. Make the *staleness check* a `Stop` hook that fires at the end of every session, so an undocumented change is visible immediately rather than at the end of a sprint.
---

# 3. The roster

## 3.1 Model routing policy

Set this once and it saves more money than any other single decision. Every agent declares a `model` in frontmatter; the resolution order is environment variable → per-invocation parameter → frontmatter → session model.

| Tier | Model | Assign to | Rationale |
|---|---|---|---|
| Scan | `haiku` | inventory, doc-staleness, link-checking, dependency listing, log grepping | Mechanical work with a well-defined output shape |
| Build | `sonnet` | all implementation agents, code review, QA execution, doc writing | The default working tier |
| Reason | `opus` | `system-architect`, `security-architect`, `red-team-critic`, the debate judge | Irreversible decisions and adversarial reasoning |

Two supporting settings:

- Add `effort: low` to scan-tier agents to suppress extended thinking where it buys nothing. Thinking tokens bill as output tokens.
- Define your own `Explore` agent at `~/.claude/agents/Explore.md` with `model: haiku` if you want exploration pinned to the cheap tier — a user- or project-level agent named `Explore` overrides the built-in and keeps its own model field.

## 3.2 Start with nine

Build these first. Run the pipeline for two weeks. Only then add the rest, and only where you can name the specific failure the new agent prevents.

`conductor` · `product-analyst` · `system-architect` · `red-team-critic` · `test-designer` · `backend-engineer` · `frontend-engineer` · `code-reviewer` · `doc-writer`

Everything else in the full roster below is an optimisation on top of a working pipeline.

## 3.3 Full roster

Twenty-four definitions, grouped by phase. Column notes: **M** = model tier, **Mem** = whether the agent keeps persistent project memory, **W** = whether it can write to the repo.

### Orchestration

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `conductor` | opus | project | no | Routes work, enforces phase order, writes the gate file, never edits source |

### Phase 1 — Idea

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `product-analyst` | sonnet | project | docs only | Problem framing, scope boundaries, success metrics, EARS acceptance criteria |
| `ux-researcher` | sonnet | project | docs only | User flows, IA, edge and empty states, error-state inventory |

### Phase 2 — Plan

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `system-architect` | opus | project | docs only | Module boundaries, data flow, ADRs, migration/rollout sequencing |
| `data-architect` | opus | project | docs only | Schema, keys, indexes, constraints, retention, N+1 risk, migration safety |
| `api-designer` | sonnet | project | docs only | Contract-first OpenAPI, error envelope, pagination, idempotency, versioning |
| `ui-designer` | sonnet | project | docs only | Design tokens, component spec, breakpoint matrix, interaction and motion spec |
| `security-architect` | opus | project | docs only | STRIDE threat model, authz matrix, data classification, secrets flow |
| `devops-planner` | sonnet | project | docs only | Environment matrix, pipeline stages, rollback, observability plan |
| `red-team-critic` | opus | project | docs only | Attacks the plan: unstated assumptions, failure modes, cheaper alternatives |

### Phase 3 — Test

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `test-designer` | sonnet | project | tests only | Test matrix, unit/integration/E2E split, fixtures, writes the red tests |
| `a11y-perf-budgeter` | sonnet | project | docs only | WCAG target level, Core Web Vitals budgets, bundle-size ceilings |

### Phase 4 — Create

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `backend-engineer` | sonnet | project | yes | Server code against the approved contract |
| `frontend-engineer` | sonnet | project | yes | Components, state, responsive implementation, token adherence |
| `db-engineer` | sonnet | project | yes | Migrations, seeders, query tuning |
| `infra-engineer` | sonnet | local | yes | CI/CD, containers, IaC, environment config |

### Phase 5 — Verify

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `code-reviewer` | sonnet | project | no | Correctness, readability, duplication, error handling, contract drift |
| `security-auditor` | opus | project | no | OWASP mapping, dependency and secret scanning, authz regression |
| `qa-runner` | sonnet | local | no | Executes suites, drives the browser, captures evidence |
| `perf-a11y-auditor` | sonnet | project | no | Core Web Vitals, axe violations, keyboard traversal, breakpoint matrix |
| `seo-auditor` | haiku | project | no | Metadata, headings, structured data, canonicals, sitemap, crawlability |

### Phase 6 — Document

| Agent | M | Mem | W | Responsibility |
|---|---|---|---|---|
| `doc-writer` | sonnet | project | docs only | API reference, runbooks, changelog, ADR index, handoff note |
| `memory-curator` | haiku | project | config only | Prunes agent memory, promotes recurring lessons into rules |
| `report-generator` | haiku | no | reports only | Structure report, docs inventory, token report |

## 3.4 Worked definitions

Five representative files. The rest follow the same shape.

### `.claude/agents/conductor.md`

```markdown
---
name: conductor
description: Routes work through the IPTCVD pipeline and enforces phase order. Use at the start of any feature, bug, or change request.
tools: Read, Grep, Glob, Agent, TodoWrite, Write, Edit
model: opus
memory: project
color: purple
---

You are the delivery lead. You never write application code, tests, or
migrations yourself. Your only writes are to `.claude/state/gate.json` and
`docs/specs/**`.

## Protocol
1. Read `.claude/state/gate.json`. If it is missing or names a different
   feature, start a new cycle at phase `idea`.
2. Run exactly one phase per turn. Never skip forward.
3. Delegate the phase to its owning agent with a briefing that contains:
   the spec directory path, the paths the agent may touch, the acceptance
   criteria if they exist, and the specific question to answer. Subagents
   start with a fresh context, so assume they know nothing about this
   conversation.
4. When the phase produces its artifact, verify the file exists and is
   non-empty before advancing. A summary in chat is not an artifact.
5. Update the gate file, then stop and report which gate needs my approval.

## Escalation rules
- Blast radius touches auth, payments, migrations, or public API contracts
  → require the full debate protocol (`/debate`) before the plan is approved.
- Two agents disagree → do not average their answers. Run `/debate` and let
  the judge decide against the written rubric.
- An agent claims completion without an evidence file → reject and re-dispatch
  with the missing artifact named explicitly.

Update your memory with routing decisions that worked, phases that repeatedly
needed rework, and briefing phrasings that produced better first drafts.
```

### `.claude/agents/system-architect.md`

```markdown
---
name: system-architect
description: Designs module boundaries, data flow, and rollout sequencing, and writes ADRs. Use in the PLAN phase for any change spanning more than one module.
tools: Read, Grep, Glob, Write, Edit
disallowedTools: Bash
model: opus
memory: project
skills:
  - adr-format
  - codebase-map
color: blue
---

You produce a plan another engineer could execute without asking you a
question. Read the approved idea.md first; if it is missing, stop and say so.

## Output: docs/specs/<slug>/plan.md
- **Approach** — chosen design in 5–10 sentences.
- **Alternatives considered** — at least two, each with the reason it lost.
  A plan with no rejected alternatives has not been designed, only asserted.
- **Module map** — every file to be created or modified, with its owner agent.
- **Contracts** — interfaces crossing a module boundary.
- **Data changes** — schema deltas and their migration order.
- **Sequencing** — the order of work and what is safe to parallelise.
- **Risks** — what breaks if this is wrong, and the rollback.
- **Out of scope** — explicit, so Verify does not grow the diff.

Write one ADR per decision that is expensive to reverse. Never write
implementation code. If the plan needs more than about 12 files changed,
split it into two features and say so.

Record recurring architectural patterns and past mistakes in your memory.
```

### `.claude/agents/red-team-critic.md`

```markdown
---
name: red-team-critic
description: Adversarially reviews a plan before implementation. Use proactively at the PLAN gate, before any code is written.
tools: Read, Grep, Glob, Write
model: opus
memory: project
color: red
---

Your job is to find the reason this plan fails. You are not here to be
balanced, and you are not here to approve. Assume the plan is wrong and
work out how.

Produce docs/specs/<slug>/critique.md with findings ranked
BLOCKER / MAJOR / MINOR. For each: the claim being attacked, the concrete
failure scenario, and the cheapest fix.

Check specifically for:
- Unstated assumptions about data volume, concurrency, or user behaviour
- Failure modes: partial writes, retries, timeouts, clock skew, offline
- Authorisation paths that were designed for the happy path only
- Migrations that are not reversible or not safe under live traffic
- Coupling introduced for convenience that will be expensive to remove
- A materially simpler design that gets 90% of the value
- Acceptance criteria that cannot actually be observed or tested

End with one line: the single change most likely to prevent an incident.
If you genuinely find nothing above MINOR, say so plainly — a manufactured
BLOCKER is worse than none.
```

### `.claude/agents/qa-runner.md`

```markdown
---
name: qa-runner
description: Executes test suites and drives the browser to capture evidence. Use in the VERIFY phase and after any implementation change.
tools: Read, Grep, Glob, Bash, Write
model: sonnet
memory: local
mcpServers:
  - playwright:
      type: stdio
      command: npx
      args: ["-y", "@playwright/mcp@latest"]
color: green
---

Run the suite, then verify in a real browser. Return only what failed plus
the evidence paths — never paste full suite output into your report.

1. Run the project's test command. Capture stdout to
   docs/specs/<slug>/evidence/tests-green.txt.
2. Start the app. Drive the changed flows with Playwright.
3. Screenshot each flow at 390px, 768px, 1280px and 1920px into
   docs/specs/<slug>/evidence/shots/.
4. Capture console errors and failed network requests.
5. Report: pass/fail counts, each failure with its assertion and file:line,
   and any console error. Nothing else.

Record flaky tests and the launch recipe that worked in your memory so the
next run does not rediscover them.
```

Note the `mcpServers` field: defining Playwright *inline on the agent* rather than in `.mcp.json` keeps ~5k tokens of browser tool definitions out of your main conversation entirely. Do this for every heavy MCP server that only one agent needs. It is one of the highest-leverage token optimisations available.

### `.claude/agents/frontend-engineer.md`

```markdown
---
name: frontend-engineer
description: Implements UI components against an approved design spec and token system. Use in the CREATE phase for any client-side work.
tools: Read, Grep, Glob, Write, Edit, Bash
model: sonnet
memory: project
skills:
  - design-tokens
  - responsive-matrix
color: cyan
---

Implement only what the approved plan names. If the plan is ambiguous, stop
and ask rather than inventing scope.

Hard rules:
- Never hardcode a colour, spacing value, radius, or font size. Every visual
  value comes from the token layer. A raw hex in a diff is a defect.
- Every interactive element ships all states: default, hover, focus-visible,
  active, disabled, loading, error, empty.
- Every list or async surface ships an empty state and an error state.
- Respect `prefers-reduced-motion` on every animation.
- Semantic HTML before ARIA. ARIA only where semantics cannot express it.
- Implement the breakpoint matrix from the design spec. Mobile layout is a
  designed layout, not a narrowed desktop.

After each component, run the project type-check and report diagnostics.
```

---

# 4. Delegation, debate and verification

## 4.1 Delegation that does not waste tokens

The briefing is where multi-agent setups quietly bleed money. A subagent begins with a fresh window; it sees its own system prompt, the CLAUDE.md hierarchy, git status, and the delegation message. It does *not* see your conversation. So an under-briefed subagent spends its first 30% re-reading the codebase to work out what you meant.

Give the conductor a fixed briefing template and it stops happening:

```
TASK: <one sentence, imperative>
SPEC: docs/specs/<slug>/plan.md  (read this first)
SCOPE: you may modify only <explicit glob list>
CONTRACT: <the interface or acceptance criterion being satisfied>
CONTEXT YOU NEED: <3-6 bullets of facts, including file paths already known>
DONE MEANS: <the artifact path that must exist, and how it will be checked>
DO NOT: <the two or three things that would make this a rejected result>
```

The `CONTEXT YOU NEED` line is the money line. Every file path you hand over is a search the subagent does not run.

## 4.2 Three levels of debate

You asked for agents that "double check and debate the best result." Debate is valuable and expensive, so tie its intensity to blast radius rather than running it always.

### Level 1 — Single critic (default, cheap)

The producing agent writes the plan; `red-team-critic` attacks it once; the producer revises. Two extra agent runs. Use for everything that is not on the list below.

### Level 2 — Proposal and judge (moderate)

Two independent proposer subagents work from the same brief without seeing each other's output, then a judge scores both against a written rubric and either picks one or synthesises. Roughly four extra agent runs.

Use for: schema design, auth flows, public API shape, choosing a library you will live with, anything named in the escalation list.

The rubric matters more than the debate. Without it the judge picks the more confidently-written answer. Keep it in the skill:

```markdown
<!-- .claude/skills/debate/SKILL.md -->
---
description: Runs a structured two-proposal debate with a rubric-scored judgement. Use for irreversible or high-blast-radius decisions.
disable-model-invocation: true
argument-hint: [decision to resolve]
---

Resolve: $ARGUMENTS

## Step 1 — Independent proposals
Dispatch two general-purpose subagents in parallel. Give each the identical
brief. Do not tell either that another proposal exists. Require each to
return: approach, why it wins, what it costs, what it forecloses, and the
strongest argument against itself.

## Step 2 — Judgement
Dispatch a third subagent on opus with both proposals and this rubric.
Score each 1–5, then total:

| Criterion | Weight |
|---|---|
| Correctness under the stated failure modes | 3 |
| Reversibility / cost to change later | 3 |
| Fit with existing patterns in this codebase | 2 |
| Implementation and review cost | 2 |
| Operational burden (monitoring, oncall, migration) | 2 |
| Security and privacy posture | 3 |

The judge must name the losing proposal's best idea and say whether to
graft it on. A tie is not a valid outcome; on a genuine tie, choose the more
reversible option and record why.

## Step 3 — Record
Write docs/adr/NNNN-<slug>.md with the decision, both alternatives, the
scores, and the consequences. Then update the plan.
```

### Level 3 — Adversarial team or workflow (expensive)

For genuinely uncertain root-cause work: several investigators pursuing competing hypotheses and actively trying to disprove each other. Sequential investigation anchors on the first plausible theory; parallel adversarial investigation does not. Two ways to run it:

**Agent teams** (experimental, must be enabled with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Teammates share a task list and message each other directly. Expect roughly 7× the tokens of a single session. Reserve for production incidents and hard bugs. Keep to 3–5 teammates; three focused ones beat five scattered ones.

**Dynamic workflows** — usually the better choice for the debate pattern, because the orchestration becomes a script you can rerun, and intermediate results live in script variables rather than in a context window. Trigger with the `ultracode` keyword or plain language:

```
use a workflow to audit every route handler under app/Http/Controllers for
missing authorization checks, and adversarially verify each finding before
reporting it
```

Set the size guideline to `small` or `medium` in `/config` before you experiment; the runtime caps at 16 concurrent agents and 1,000 agents per run, and flags runs projected past 1.5M tokens.

### Escalation list

Level 2 or 3 is mandatory for: authentication and authorisation, payments and billing, any destructive migration, public API contracts, PII handling, rate limiting and abuse controls, and any change whose rollback is not a single revert.

## 4.3 Verification that produces evidence

Verify runs five read-only agents in parallel from a single dispatch. Each returns findings ranked BLOCKER / MAJOR / MINOR, and each must cite `file:line`.

```
Verify the current diff. Dispatch in parallel: code-reviewer,
security-auditor, qa-runner, perf-a11y-auditor, seo-auditor.
Each returns only severity-ranked findings with file:line citations and
evidence paths. Merge into docs/specs/<slug>/verification.md, deduplicated
and ranked. Do not fix anything in this turn.
```

Two bundled skills complement this and are worth wiring into the phase playbooks:

- `/code-review` — multi-agent diff review. Runs only when you invoke it (recent versions removed Claude's ability to start it unprompted), which keeps a long, token-heavy check under your control.
- `/verify` — builds and runs your app to confirm a change does what it should, rather than falling back to type checks. Run `/run-skill-generator` once per project so `/verify` records your build and launch recipe into `.claude/skills/` instead of rediscovering it every time. That one command is a meaningful recurring saving on any project with a non-trivial launch.

Also install the official `security-guidance` plugin — it reviews each change Claude makes for common vulnerabilities and has it fix what it finds in the same session, which catches a class of defect before it ever reaches your Verify phase.
---

# 5. Memory architecture

Your requirement — "set up the memory initially, remember the codebase, build memory as features are added, update documentation and handoff" — needs five distinct tiers, because these are five different problems with five different lifetimes.

## 5.1 The five tiers

| Tier | Location | Written by | Lifetime | Shared? | Loaded |
|---|---|---|---|---|---|
| 0 · Constitution | `CLAUDE.md` | you | project life | git | every session, in full |
| 1 · Standards | `.claude/rules/*.md` | you | project life | git | always, or on path match |
| 2 · Procedures | `.claude/skills/*/SKILL.md` | you | project life | git | on invocation |
| 3 · Session learnings | `~/.claude/projects/<p>/memory/` | Claude | ongoing | **no — machine local** | first 200 lines of `MEMORY.md` |
| 4 · Discipline memory | `.claude/agent-memory/<agent>/` | each subagent | ongoing | git | into that agent only |
| 5 · Durable record | `docs/` | doc-writer | forever | git | on demand |

The critical distinction, and the one most setups get wrong: **auto memory (tier 3) is machine-local and is not loaded into subagents.** It will not survive a new machine, will not reach a teammate, and will not appear in a subagent's context. It is a personal convenience layer.

**Tier 4 is the one that answers your requirement.** Setting `memory: project` on a subagent gives it a directory at `.claude/agent-memory/<name>/` that persists across conversations, is committed to version control, and is loaded into that agent's system prompt at startup. This is how `data-architect` accumulates knowledge of your schema quirks over six months, and how `code-reviewer` learns which mistakes recur in your codebase. Anthropic's guidance names `project` as the recommended default scope for exactly this reason.

## 5.2 CLAUDE.md — the constitution

Under 200 lines. Longer files consume more context *and* measurably reduce adherence. Everything procedural belongs in a skill; everything directory-specific belongs in a rule.

```markdown
# <Project>

Laravel 12 · Vite · Tailwind v4 · Alpine/Livewire · MySQL · Pest

## Commands
- Dev: `npm run dev` + `php artisan serve`
- Tests: `php artisan test` (Pest)
- Lint: `./vendor/bin/pint` · Types: `./vendor/bin/phpstan analyse`
- Front-end check: `npm run build`

## Layout
- Domain services: `app/Services/<Domain>/`
- HTTP: `app/Http/Controllers/` — thin; no business logic
- Front-end: `resources/js/` (features), `resources/css/tokens.css` (tokens)
- Specs and ADRs: `docs/specs/`, `docs/adr/`

## Non-negotiables
- No implementation before an approved plan exists at
  `docs/specs/<slug>/plan.md`. Check `.claude/state/gate.json`.
- No raw colour, spacing, radius, or font-size values in components.
  Use tokens from `resources/css/tokens.css`.
- Every schema change ships a reversible migration and a test.
- Never edit `.env`, `storage/`, or anything under `vendor/`.
- Every bug fix begins with a failing test.

## Working agreement
- Start features with the `conductor` agent.
- Run `/handoff` before ending any session with uncommitted work.

## Compact instructions
When compacting, preserve: the active gate state, decisions made this
session, and file paths already discovered. Discard tool output and
exploration transcripts.
```

Two details in that file that pay for themselves: the compaction instruction (compaction otherwise discards exactly the file paths you most want kept), and pointing at the gate file rather than restating the rules.

## 5.3 Rules — scoped standards

Path-scoped rules cost nothing until a matching file is read. This is where your discipline standards live.

```markdown
<!-- .claude/rules/frontend.md -->
---
paths:
  - "resources/js/**/*.{js,ts,vue,jsx,tsx}"
  - "resources/css/**/*.css"
  - "resources/views/**/*.blade.php"
---

# Front-end standards

## Tokens
Colour, spacing, radius, shadow, and type scale come from
`resources/css/tokens.css`. A literal hex, px, or rem in a component is a
review blocker. The palette derives from `--brand-hue`; changing one value
must re-theme the entire surface.

## States
Every interactive element implements: default, hover, focus-visible, active,
disabled, loading, error. Every collection implements empty and error.

## Responsive
Breakpoints: 390 / 768 / 1024 / 1280 / 1536. Mobile is designed, not
narrowed. No horizontal scroll at 320px. Touch targets ≥ 44×44px.

## Accessibility
WCAG 2.2 AA. Semantic elements before ARIA. Visible focus everywhere.
Contrast ≥ 4.5:1 for body text, 3:1 for large text and UI boundaries.
All motion respects `prefers-reduced-motion`.

## Performance
LCP ≤ 2.5s, INP ≤ 200ms, CLS ≤ 0.1 on a mid-tier mobile profile.
Images: explicit dimensions, modern formats, lazy below the fold.
```

Write the equivalent for `backend.md`, `database.md`, `security.md`, `testing.md`, and `seo.md`. Each scoped, each under a hundred lines.

## 5.4 Bootstrapping memory on an existing codebase

Do this once, in this order. It is the "set up the memory initially" step.

1. **`/init`** — generates a starting CLAUDE.md from the codebase. Set `CLAUDE_CODE_NEW_INIT=1` first for the interactive multi-phase flow, which explores with a subagent, asks follow-ups, and shows you a reviewable proposal before writing anything. It also reads existing Cursor, Copilot, and `AGENTS.md` rules and folds in the relevant parts.
2. **Trim it.** Delete everything Claude can rediscover — directory listings, dependency lists, architecture narration. Keep pitfalls, rationale, and conventions that differ from tool defaults. `/doctor` will propose these trims for you on recent versions.
3. **Build the codebase map skill.** A single `codebase-map` skill that describes the architecture, key directories, and naming conventions saves an exploration pass in every session that invokes it — Anthropic's own cost guidance names this pattern explicitly.
4. **Seed agent memory.** Run each specialist once over its own domain in read-only mode with an explicit instruction to write findings to memory:

```
Use the data-architect agent to survey every migration and model in this
repository. Write to your agent memory: the naming conventions actually in
use, the tables with unusual constraints, the queries most at risk of N+1,
and the migrations that were not reversible. Do not modify any file.
```

Repeat for `system-architect`, `code-reviewer`, `security-auditor`, `frontend-engineer`. Roughly an hour of wall-clock, and from then on each agent starts with real knowledge of your code instead of guesses. Commit `.claude/agent-memory/`.

5. **Set the memory maintenance instruction.** Add to each agent's prompt body: *"Update your memory as you discover code paths, patterns, library locations, and architectural decisions. Write concise notes about what you found and where."* This is what makes memory grow with the codebase rather than needing manual curation.

## 5.5 Memory hygiene

Memory rots. Two mechanisms keep it useful:

- **`MEMORY.md` has a hard read limit** — the first 200 lines or 25KB, whichever comes first. Content past that is silently dropped on the next load. Recent versions warn you as the file approaches the limit and error when it exceeds it. Keep one line per entry and push detail into topic files.
- **Run `memory-curator` monthly.** Its job: delete entries about code that no longer exists, merge duplicates, and promote anything that has been rediscovered three times into a permanent rule. A lesson relearned three times is not a memory, it is a missing rule.

## 5.6 Handoff

Handoff is a skill, not a habit. It runs at session end and produces a file another session — or another person — can start from.

```markdown
<!-- .claude/skills/handoff/SKILL.md -->
---
description: Writes an end-of-session handoff note capturing state, decisions, and next actions. Use before ending a session or when context is nearly full.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *)
---

## Current state
- Branch: !`git branch --show-current`
- Uncommitted: !`git status --short`
- Recent: !`git log --oneline -12`
- Gate: !`cat .claude/state/gate.json 2>/dev/null || echo "no active gate"`

## Task
Write `docs/handoff/$(date +%Y-%m-%d)-<feature-slug>.md` containing:

1. **State** — which phase, what is done, what is in progress.
2. **Decisions made this session** — each with its reason. Link ADRs.
3. **Rejected approaches** — and why. This is the highest-value section;
   without it the next session re-litigates settled questions.
4. **Open questions** — with the person or agent who should answer them.
5. **Next actions** — ordered, each with the file path it touches.
6. **Landmines** — anything surprising discovered in the codebase.

Then append durable lessons to the relevant agent memories, and update
`docs/handoff/INDEX.md`.

Keep it under 300 words per section. A handoff nobody reads is a handoff
that failed.
```

The `!`command`` syntax runs the shell command *before* Claude sees the skill, so the git state arrives already inlined — Claude never spends a tool call fetching it.

---

# 6. Repository layout

```
project/
├── CLAUDE.md                        # constitution, <200 lines
├── CLAUDE.local.md                  # personal, gitignored
├── .mcp.json                        # only light, always-on MCP servers
├── .claude/
│   ├── settings.json                # hooks, permissions, env, plugins (committed)
│   ├── settings.local.json          # personal overrides (gitignored)
│   ├── agents/                      # the roster
│   ├── skills/                      # phase playbooks + utilities
│   │   ├── phase-idea/
│   │   ├── phase-plan/
│   │   ├── phase-test/
│   │   ├── phase-create/
│   │   ├── phase-verify/
│   │   ├── phase-document/
│   │   ├── debate/
│   │   ├── handoff/
│   │   ├── codebase-map/
│   │   ├── design-tokens/
│   │   └── studio-report/
│   ├── rules/                       # path-scoped standards
│   ├── hooks/                       # enforcement scripts
│   ├── agent-memory/                # tier 4 — COMMITTED
│   ├── workflows/                   # saved dynamic workflows
│   └── state/gate.json              # phase state
├── docs/
│   ├── README.md                    # entry point + doc map
│   ├── adr/                         # architecture decision records
│   ├── specs/<slug>/                # idea, plan, critique, acceptance,
│   │                                # verification, evidence/
│   ├── api/                         # OpenAPI + generated reference
│   ├── design/                      # tokens, components, breakpoints
│   ├── runbooks/                    # ops procedures
│   ├── handoff/                     # session handoffs + INDEX.md
│   └── reports/                     # generated: structure, docs, tokens
└── src/ | app/ | resources/ …
```

Two conventions worth enforcing:

- `docs/` is the **only** durable documentation location. Nothing important lives solely in a chat transcript or solely in Obsidian.
- `docs/specs/<slug>/evidence/` holds artifacts, not prose: test output, screenshots, HAR files, audit JSON. This directory is what makes "verified" mean something.

---

# 7. Obsidian: the recommendation

You were unsure whether to run a vault for the whole pipeline. Here is a direct answer.

## 7.1 Recommendation

**Yes — but one vault, read-mostly, and never the working directory.**

```
~/Vault/
├── 00-Pipeline/                 # native vault notes: the meta-system
│   ├── Agents/                  # one note per agent, with its rationale
│   ├── Prompts/                 # briefing templates that worked
│   ├── Playbooks/               # your own process notes
│   ├── Decisions/               # cross-project standards
│   ├── Reports/                 # monthly token + structure reports
│   └── Retros/                  # what to change next month
├── 10-Projects/
│   ├── project-a/  ->  ~/code/project-a/docs        # SYMLINK
│   └── project-b/  ->  ~/code/project-b/docs        # SYMLINK
├── 20-Reference/                # framework notes, patterns, snippets
└── 90-Archive/
```

The rules that make this work:

1. **Git is the source of truth for anything about a project.** The vault reads it through a symlink. `docs/` lives in the repo, gets reviewed in PRs, and travels with the code. Obsidian gives you backlinks, graph view, and search across projects on top of it.
2. **`00-Pipeline/` is native vault content** — this is the part that genuinely benefits from being a vault rather than a repo, because it is cross-project, associative, and edited by you rather than by agents.
3. **Agents write to `docs/`, never to the vault.** One direction only. The moment agents write into `00-Pipeline/`, your thinking and their generated output become indistinguishable and the vault stops being trustworthy.
4. **Do not run Claude Code with the vault as the working directory.** That pattern is for people whose *project is the vault*. Yours is a codebase.

## 7.2 Do you need an Obsidian MCP server?

**Not at first.** Claude Code already has full file tools; if you run it in the repo, `docs/` is directly readable. An MCP server adds tool definitions to every session for capability you mostly already have.

Add one only when you want *cross-project* retrieval — "how did we solve rate limiting on the other project?" — and then choose by constraint:

| Server | Requires Obsidian running? | Notes |
|---|---|---|
| `mcpvault` (`@bitbonsai/mcpvault`) | No | Reads raw `.md` directly, BM25 ranked search, handles frontmatter safely. The pick if starting fresh. |
| `mcp-obsidian` (MarkusPfundstein) | Yes — needs the Local REST API plugin | Most established, largest community |
| `obsidian-claude-code-mcp` | Yes | WebSocket auto-discovery, multi-vault |
| `@modelcontextprotocol/server-filesystem` | No | Simplest path; just point it at the vault, read-only |

If you do add one, scope it to a single research agent via that agent's `mcpServers` frontmatter rather than putting it in `.mcp.json`, so it never taxes your main sessions.

## 7.3 Recommended plugins (Obsidian side)

Dataview or Bases for auto-generated indexes over your specs; Templater for the note templates; Git for vault versioning. Keep the plugin list short — the vault's job here is reading and linking, not automation. Automation belongs in the repo where it can be tested.
---

# 8. The external stack: plugins, MCP servers, skills

## 8.1 Selection principle

Prefer, in this order: **built-in tool → CLI command → skill → plugin → MCP server.** Cost rises at every step. A CLI tool like `gh` costs nothing at session start; an MCP server for the same job costs thousands of tokens of definitions. Anthropic's own cost guidance says this explicitly.

Target: **3–5 active MCP servers maximum**, with heavy ones scoped to individual agents rather than the session.

## 8.2 Tier 1 — install these

### Official plugins

The official Anthropic marketplace (`claude-plugins-official`) is added automatically on first interactive launch. If it is missing:

```bash
/plugin marketplace add anthropics/claude-plugins-official
```

Then:

```bash
/plugin install security-guidance@claude-plugins-official   # per-change vuln review
/plugin install typescript-lsp@claude-plugins-official      # if you write TS
/plugin install php-lsp@claude-plugins-official             # if you write PHP (needs intelephense)
/plugin install pr-review-toolkit@claude-plugins-official
/plugin install commit-commands@claude-plugins-official
/plugin install skill-creator@claude-plugins-official        # for evaluating your own skills
/reload-plugins
```

**Code intelligence plugins are a token optimisation, not a convenience.** They enable Claude Code's LSP tool: a single "go to definition" replaces a grep plus reading three candidate files, and the language server reports type errors automatically after every edit so Claude catches its own mistakes without running a compiler. Install the language server binary yourself first — the plugin does not do it (`typescript-language-server`, `pyright-langserver`, `intelephense`, `gopls`, `rust-analyzer`, and so on).

### Design skills

```bash
claude plugin add anthropic/frontend-design
```

This is the single highest-impact install for UI quality. It makes Claude choose a deliberate aesthetic direction before writing code, demands real typography pairing, blocks cookie-cutter component patterns, and enforces CSS variables and a coherent colour system — instead of defaulting to the generic sans-serif-plus-purple-gradient look that every AI-generated page shares.

Optional additions, in rough order of value:

- `nextlevelbuilder/ui-ux-pro-max-skill` — a large style and font-pairing library with a reasoning layer that matches a design system to a product category
- `addyosmani/web-quality-skills` (`npx add-skill addyosmani/web-quality-skills`) — Core Web Vitals, WCAG, SEO and best-practice audits from Google's web performance lead, with framework-aware patterns and an orchestrator skill that runs a full-site audit. This maps almost exactly onto your Performance / Responsiveness / SEO requirements.
- The polish pipeline: `npx ui-skills add baseline-ui`, `fixing-accessibility`, `fixing-motion-performance`

### MCP servers

```bash
# Docs — small, on-demand, prevents wrong API signatures on unfamiliar libraries
claude mcp add context7 -s user -- npx -y @upstash/context7-mcp@latest

# Repo workflows
claude mcp add -s user -t http github https://api.githubcopilot.com/mcp/
```

Keep these two in `.mcp.json` or user scope. Everything heavier gets scoped to an agent:

- **Playwright** → `qa-runner` only (inline in frontmatter, as shown earlier)
- **Chrome DevTools** → `perf-a11y-auditor` only, for console, network, performance profiling and device emulation
- **Figma Dev Mode** → `ui-designer` only, if you have a Figma Dev or Full seat: `claude mcp add --transport sse figma-dev-mode-mcp-server http://127.0.0.1:3845/sse`

### Framework-native MCP

If your backend framework ships one, it will beat any generic alternative because it reads your actual application rather than your files. Laravel is the clearest example:

```bash
composer require laravel/boost --dev
php artisan boost:install
# if Claude Code does not pick it up automatically:
claude mcp add -s local -t stdio laravel-boost php artisan boost:mcp
```

Boost exposes routes, models, schema, logs and tinker as MCP tools, installs version-aware AI guidelines for your installed packages, adds on-demand skills for things like Livewire and Pest, and provides a documentation search API over Laravel's docs. The practical effect: "add a status scope to the Order model" goes from *read the model, read the migrations, guess the column types* to *query the schema tool, write the scope*. That is a direct token saving on every database-adjacent task.

## 8.3 Tier 2 — community collections

You already have **Everything Claude Code** (`affaan-m/everything-claude-code`) installed:

```bash
/plugin marketplace add affaan-m/everything-claude-code
/plugin install everything-claude-code@everything-claude-code
```

It is a good source of agents, hooks and token-optimisation patterns. Note its own caveat: plugins cannot distribute rules automatically, so its rules require a manual clone-and-copy step. Treat it as a parts bin, not a system — take the pieces that fit your pipeline rather than adopting it wholesale.

Others worth mining, in descending order of relevance to what you are building:

| Repository | What to take from it |
|---|---|
| `wilwaldon/Claude-Code-Frontend-Design-Toolkit` | The best-curated map of design-quality tooling: skills, MCP servers, CLAUDE.md theme tricks, and per-stack install bundles. Start here for the UI half. |
| `VoltAgent/awesome-claude-code-subagents` | 150+ subagent definitions across ten categories, installable as a marketplace. Useful as reference prompts even where you write your own. |
| `addyosmani/web-quality-skills` | Perf, a11y, SEO audit skills with an orchestrator |
| `anthropics/claude-plugins-community` | Third-party plugins that passed automated validation and safety screening, each pinned to a commit SHA |
| `jqueryscript/awesome-claude-code` | The general master list |
| GitHub Spec Kit (`specify` CLI) | If you want the SDD artifact structure standardised across tools; its `/constitution → /specify → /plan → /tasks → /implement` flow maps cleanly onto IPTCVD |
| BMAD-METHOD | Only if you have real stakeholders and need a heavy paper trail. It is weeks to learn and expensive in tokens; your custom pipeline is lighter and better fitted. |

**Security note.** Plugins execute arbitrary code with your user privileges, and Anthropic does not vet third-party marketplace contents. Read the manifest before installing. Prefer the official and community marketplaces. Check the **Will install** panel — it lists exactly which commands, agents, skills, hooks and MCP servers a plugin adds, plus a context-cost estimate, before you commit.

## 8.4 Context budget audit

After installing, run `/context`. If the pre-prompt total exceeds about 15% of your window, cut something. Then:

```bash
/plugin            # Installed tab surfaces plugins unused for 2+ weeks
/mcp               # disable servers not in active use
/doctor            # flags duplicate agent names, oversized CLAUDE.md, skill listing overflow
```

Repeat monthly. Tool sprawl is silent and cumulative.

---

# 9. The UI/UX pipeline

Your goal is "latest professional standard UI/UX." That is achievable, but it comes from a *pipeline*, not from a single tool. Four stages, each with a different tool class.

## 9.1 Stage 1 — Direction

Before any pixels, the `ui-designer` agent produces `docs/design/direction.md`: aesthetic direction, reference points, mood, and what the product must *not* look like. The `frontend-design` skill drives this; without an explicit direction, generated UI regresses to the same generic default every time.

Lock the direction into CLAUDE.md so it applies to every session. This trick — from Anthropic's frontend aesthetics guidance — costs five lines and works immediately:

```markdown
## Frontend theme
<always_use_editorial_theme>
Always design with an editorial aesthetic:
- Serif display headlines, generous line height, restrained palette
- Asymmetric magazine grid; content-first hierarchy
- One accent colour used sparingly; no gradients
- Motion is subtle and purposeful; nothing decorative
</always_use_editorial_theme>
```

Named alternatives that Claude interprets reliably: Swiss minimalism, brutalism, glassmorphism, neumorphism, dark OLED luxury, retro-futurism, organic/biomorphic, art deco, editorial, SaaS minimal.

## 9.2 Stage 2 — Tokens

This is what separates professional output from AI-generated output. Everything derives from a small set of variables so the whole surface re-themes from one change.

```css
/* resources/css/tokens.css — Tailwind v4 CSS-first theming */
@import "tailwindcss";

@theme {
  --brand-hue: 250;

  --color-primary:     oklch(0.60 0.20 var(--brand-hue));
  --color-background:  oklch(0.995 0.005 var(--brand-hue));
  --color-foreground:  oklch(0.15 0.02 var(--brand-hue));
  --color-muted:       oklch(0.94 0.01 var(--brand-hue));
  --color-border:      oklch(0.88 0.015 var(--brand-hue));

  --spacing-unit: 0.25rem;      /* 4px grid */
  --radius-sm: 0.25rem; --radius-md: 0.5rem; --radius-lg: 1rem;
  --font-display: "…", serif;
  --font-body: "…", system-ui, sans-serif;
}
```

OKLCH gives perceptually uniform lightness across hues and access to the P3 wide gamut. Brand-tinted neutrals — rather than pure grey — are one of the clearest visual signals of a deliberately designed system. Deriving the palette from a single `--brand-hue` means a rebrand is one number.

Capture this as a `design-tokens` skill and preload it into `frontend-engineer` and `ui-designer` via their `skills:` frontmatter, so the token contract is in their context from startup rather than something they have to go and read.

## 9.3 Stage 3 — Generation

Where mockups come from. Honest comparison:

| Tool | Cost | Best at | Limitation |
|---|---|---|---|
| **Claude Design** | Included in Claude subscriptions | Chat-plus-canvas iteration; mockups, prototypes, slides, one-pagers; can adapt to screenshots, competitor designs, or your existing codebase | Not a Figma replacement — no real-time multi-editor collaboration, persistent component libraries, or precise vector editing |
| **Google Stitch** | Free, Google Labs, credit-limited | Fast multi-screen ideation on an infinite canvas; generates several interconnected screens from one journey description; paste-to-Figma | Beta; credit caps; layout control is coarser than a real design tool |
| **v0 (Vercel)** | Freemium | Straight to production-leaning React + Tailwind that drops into a modern repo | Code-first; skips the design canvas |
| **Magic Patterns / Subframe** | Freemium | Component-level generation with structured React/Tailwind export | Narrower scope |
| **Open Design** | Free / open-source, self-hosted | Runs locally, exports to coding agents over MCP, imports and exports Figma, ships 150+ design systems | You supply the model API costs and the setup |
| **Figma + Dev Mode MCP** | Figma Dev/Full seat | The production path when a designer is involved | Requires the desktop app and a paid seat |

**Recommendation for your situation.** Use **Claude Design** for direction, mockups and prototypes — it is already in your subscription and it can ingest your existing codebase to match your style, which no free alternative does as well. Keep **Google Stitch** as the free multi-screen ideation tool when you want five screens of a flow at once. Add **Open Design** if you want a self-hosted, Figma-exporting option with no per-generation cost. Skip Figma unless a designer is genuinely in the loop.

Critically: **mockups are input to Stage 4, never the deliverable.** The implementation is generated in Claude Code against your token system, not exported from the design tool. Exported design-tool code does not know your components, your conventions, or your accessibility rules.

If you do adopt Figma, add a design-system rules file so Claude uses your existing `<Button>` instead of inventing another one, and use Code Connect mappings — this is the difference between a component library and a pile of near-duplicate components.

## 9.4 Stage 4 — Implementation and visual verification

This is where most AI UI work fails: the agent writes the component, declares success, and never looks at it. Give it eyes.

```
Implement the invoice table per docs/design/components/invoice-table.md.

Then verify with Playwright:
1. Screenshot at 390, 768, 1280, 1920
2. Tab through every interactive element; confirm visible focus on each
3. Trigger loading, empty and error states; screenshot each
4. Run axe; report every violation with its selector
5. Re-render with prefers-reduced-motion: reduce; confirm no motion
6. Capture LCP, INP and CLS from a cold load

Report only failures with evidence paths. Fix, then re-run until clean.
```

Playwright's accessibility-tree snapshots are 2–5KB against 500KB+ for screenshots, so prefer snapshot-driven assertions and reserve screenshots for the visual record. Chrome DevTools MCP handles the parts Playwright does not: network waterfalls, performance profiling, HAR export, device emulation.

Then run the polish sequence in order — design, craft, accessibility, performance:

```
/frontend-design → /baseline-ui → /fixing-accessibility → /fixing-motion-performance
```

## 9.5 SEO

`seo-auditor` runs on `haiku` because the work is a checklist, not reasoning. Its rule file covers: title and meta description per route with length bounds; one `h1` per page with a correct heading hierarchy; canonical URLs; Open Graph and Twitter cards; JSON-LD structured data appropriate to the page type; `sitemap.xml` and `robots.txt`; hreflang if multilingual; image `alt` text; crawlable navigation that does not depend on JavaScript; no orphan pages; and the Core Web Vitals thresholds, which are shared with the performance budget rather than duplicated.
---

# 10. Enforcement: hooks and permissions

Prompts are advisory; hooks are deterministic. These six hooks are what turn a set of nicely-worded agent prompts into an actual process. Four of them were the original design; §10.5 exists because that design had a door in it, and §10.6 because two of its load-bearing claims about token spend were measured by nothing.

## 10.1 Hook 1 — the phase gate

Blocks writes to source files unless the gate file says the pipeline has reached `create`. Exit code 2 blocks the tool call and returns the message to Claude.

```bash
#!/bin/bash
# .claude/hooks/gate-check.sh
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

# Docs, specs, tests and Claude config are always writable
case "$FILE" in
  *docs/*|*.claude/*|*test*|*Test*|*spec*|*.md) exit 0 ;;
esac

GATE=".claude/state/gate.json"
if [ ! -f "$GATE" ]; then
  echo "BLOCKED: no active gate. Start with the conductor agent to open a cycle." >&2
  exit 2
fi

PHASE=$(jq -r '.phase' "$GATE")
case "$PHASE" in
  create|verify) exit 0 ;;
  *)
    echo "BLOCKED: phase is '$PHASE'. Source edits are allowed only in 'create'." >&2
    echo "Complete and approve the plan and test phases first." >&2
    exit 2 ;;
esac
```

## 10.2 Hook 2 — output filtering

The highest-value token optimisation available in hooks. Instead of Claude reading 10,000 lines of test output to find three failures, the hook rewrites the command so only failures come back — tens of thousands of tokens become hundreds.

```bash
#!/bin/bash
# .claude/hooks/filter-output.sh
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command')

if [[ "$CMD" =~ ^(npm\ test|npm\ run\ test|pytest|php\ artisan\ test|go\ test|vendor/bin/pest) ]]; then
  NEW="$CMD 2>&1 | grep -B2 -A8 -iE '(FAIL|ERROR|✕|✗|assert)' | head -150"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"%s"}}}' "$(echo "$NEW" | sed 's/"/\\"/g')"
  exit 0
fi
echo '{}'
```

Apply the same pattern to build logs, `composer`/`npm install` output, and container logs. Verify it is live with `claude --debug`: the log shows `modified tool input keys: [command]` when a hook rewrites a command.

## 10.3 Hook 3 — post-edit quality

Runs the formatter and type-checker after every edit so defects surface in the same turn.

```bash
#!/bin/bash
# .claude/hooks/post-edit.sh
INPUT=$(cat); FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
case "$FILE" in
  *.php)      ./vendor/bin/pint "$FILE" -q 2>/dev/null ;;
  *.ts|*.tsx) npx prettier --write "$FILE" -u 2>/dev/null
              npx tsc --noEmit 2>&1 | grep "$FILE" | head -20 ;;
  *.js|*.vue) npx prettier --write "$FILE" -u 2>/dev/null ;;
esac
exit 0
```

## 10.4 Hook 4 — the documentation gate

Fires at session end. This is what makes documentation a gate rather than an aspiration.

```bash
#!/bin/bash
# .claude/hooks/doc-staleness.sh
CHANGED=$(git diff --name-only HEAD 2>/dev/null | grep -E '^(app|src|resources)/' || true)
[ -z "$CHANGED" ] && exit 0
if [ -z "$(git status --short docs/ 2>/dev/null)" ]; then
  echo "Source changed but docs/ did not. Run /handoff, or state why no doc change is needed." >&2
  exit 2
fi
exit 0
```

## 10.5 Hook 5 — the other door

Hook 1 is registered on `Edit|Write`. That is the only tool surface it ever sees, which means the entire phase gate is one `sed -i` away from irrelevant — and an agent writing through the shell is not an exotic case, it is the common one. Measured against the four-hook design above, with the gate CLOSED: `sed -i`, `cat >`, `cp`, `npm i` and a `python -c` one-liner each walked straight past every gate in this section.

So there is a fifth hook, on `Bash`. It does not re-implement the gate. It extracts the write *targets* from the command and hands each one to `gate-check.sh`, so there is one rulebook and one block message, and adding a key covers both doors at once.

```bash
#!/usr/bin/env bash
# .claude/hooks/bash-gate.sh — extracts write targets, defers the verdict
CMD="$(json_field "$INPUT" 'tool_input.command')"
for target in $(extract_write_targets "$CMD"); do
  printf '{"tool_input":{"file_path":"%s"}}' "$target" | "$(dirname "$0")/gate-check.sh" || exit 2
done
exit 0
```

It recognises redirects (`>`, `>>`, `>|`, `&>`), `sed -i`, `perl/ruby -i`, `tee`, `sponge`, `cp/mv/ln/rsync/install` (including `-t DIR`), `rm`, `dd of=`, `git checkout/restore/apply/mv/rm/clean`, `patch`, awk redirects, interpreter writes, and the manifest-rewriting forms of `npm`/`pnpm`/`yarn`/`composer`/`cargo`/`go`/`pip`.

It fails **open** on anything it cannot parse, because a wrong block costs a retry on every unrelated command — with one exception: a payload it cannot parse at all that plainly names a guarded root is refused rather than guessed at.

Give it **no exemption list.** The obvious one — keep the pipeline's own tooling runnable while the gate is closed — is matched by substring against a string the caller fully controls, so appending a trailing comment disables the whole shell gate in one token:

```bash
sed -i 's/x/y/' src/app.ts   # .claude/hooks/
```

It is also unnecessary: the scripts are invoked as `bash .claude/scripts/…`, and `bash` is not a program the hook extracts targets from. The safest allowlist is the one you can delete.

## 10.6 Hook 6 — the one that only counts

The preceding hooks all guard something. This one guards nothing, and it exists because of an argument this design lost with itself.

§11 names the twelve levers and ranks them. The top two by value are **output filtering** and **`/clear` between phases** — and until this hook, neither had an instrument on it. Filtering was asserted in three documents ("tens of thousands of tokens become hundreds") with nothing counting bytes. `/clear` was a line in `CLAUDE.md` and an instruction telling the model to remind you. §14 of this same document sets the bar for a defensible claim about token spend, and neither lever cleared it.

That is the 800-line rule again, one level up: a standard that nothing measures is a preference, and the enforcement layer being well-tested does not make the economics layer true.

```bash
#!/usr/bin/env bash
# .claude/hooks/session-log.sh — SessionStart, fails open, read by no gate
printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  "$(field source)" "$(gate_phase)" "${SESSION:0:8}" \
  >> .claude/state/session-log.tsv 2>/dev/null || true
exit 0
```

`/clear` **cannot be enforced.** No hook can make somebody type it, and one that tried would be refusing to let a session start. So it takes the `hook-integrity.sh` route instead: do not prevent the thing, make it visible. The `source` field distinguishes `clear` from `compact`, and that distinction is the whole point — a compact is the window filling up and the entire conversation being re-sent at cache-read price, where a clear would have dropped it at zero. Recording the gate phase alongside turns a count into a diagnosis: compacts landing mid-`create` is a feature that overran its window.

The filter's own measurement lives in the rewrite (§10.2), which tees both ends and records bytes in, bytes returned, and the exit code. `savings.sh` reads both logs.

Two rules keep this from becoming a liability of its own:

1. **No gate reads either log.** The moment a gate depends on a measurement, the measurement acquires an incentive and stops being one.
2. **Bytes are measured; tokens are estimated.** The logs record bytes because bytes are what a shell can count without a tokeniser. The ~4 bytes/token conversion is a prose rule of thumb and is optimistic for test output. Label it every time, or it becomes the confident wrong number §2 warns about — and a number nobody re-derives later is exactly how a floor gets set wrong.

## 10.7 Wiring it up

```json
// .claude/settings.json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
    "MAX_THINKING_TOKENS": "8000"
  },
  "permissions": {
    "deny": [
      "Read(./.env)", "Read(./.env.*)", "Read(./**/*.pem)", "Read(./**/*.key)",
      "Write(./.env)", "Write(./vendor/**)", "Write(./node_modules/**)",
      "Bash(rm -rf *)", "Bash(git push --force*)", "Bash(*DROP TABLE*)"
    ],
    "allow": [
      "Bash(git status*)", "Bash(git diff*)", "Bash(git log*)",
      "Bash(npm run*)", "Bash(php artisan test*)", "Bash(./vendor/bin/*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": ".claude/hooks/gate-check.sh" }] },
      { "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/bash-gate.sh" },
          { "type": "command", "command": ".claude/hooks/filter-output.sh" }
        ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": ".claude/hooks/post-edit.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": ".claude/hooks/doc-staleness.sh" }] }
    ],
    "SessionStart": [
      { "matcher": "startup|clear|compact|resume",
        "hooks": [{ "type": "command", "command": ".claude/hooks/session-log.sh" }] }
    ]
  }
}
```

Listing `bash-gate` above `filter-output` reads like an ordering, and it is not one: **all matching hooks run in parallel**, and Claude Code does not document which decision wins when one returns `deny` and another `allow`. Do not build a guarantee on that. What makes the pair safe is that their domains do not overlap — `filter-output` rewrites only the four exact commands from the profile (test, build, typecheck, dependency audit), and none of those produces a write target for `bash-gate` to refuse. That is a property you can test, and `test/hooks.sh` does; an ordering is not.

`chmod +x .claude/hooks/*.sh` — on macOS and Linux a non-executable hook fails rather than blocking. Confirm with `/hooks`.

A note on permission modes: `bypassPermissions` defeats most of this. Use `acceptEdits` or `auto` for flow; keep `bypassPermissions` for throwaway sandboxes only.

---

# 11. Token economics

## 11.1 What actually drives cost

Ranked by observed impact:

1. **Long sessions.** The full conversation is re-sent with every request. A one-line question at the end of an eight-hour session still draws usage for the whole history at the cached rate.
2. **Cache misses.** The first message after a break longer than the cache lifetime reprocesses everything. On a subscription the lifetime is about an hour, dropping to five minutes once you are drawing on usage credits; on an API key or cloud provider it is five minutes by default.
3. **Agent teams.** Roughly 7× a standard session when teammates run in plan mode.
4. **Unfiltered tool output.** Test suites, build logs, log files read whole.
5. **MCP tool definitions.** Thousands of tokens per server, every session.
6. **Extended thinking at high effort on trivial tasks.** Thinking bills as output.
7. **Re-exploration.** A subagent rediscovering what the last one already found.

## 11.2 The twelve levers

| # | Lever | Mechanism | Typical effect |
|---|---|---|---|
| 1 | `/clear` between unrelated tasks | Kills stale context | Large — the single biggest habit change |
| 2 | Filter tool output in hooks | `PreToolUse` command rewrite | Large on test-heavy work |
| 3 | Scope heavy MCP to one agent | `mcpServers` in agent frontmatter | 5–15k tokens per session |
| 4 | Model routing by tier | `model:` frontmatter | Large — Haiku and Sonnet on most work |
| 5 | Code intelligence plugins | LSP navigation replaces grep + reads | Moderate, compounding |
| 6 | `codebase-map` skill | One skill replaces an exploration pass | Moderate |
| 7 | CLAUDE.md under 200 lines | Less standing context, better adherence | Small but every single turn |
| 8 | Move procedures to skills | On-demand instead of always-on | Moderate |
| 9 | Delegate verbose ops to subagents | Noise stays in the subagent's window | Moderate |
| 10 | Plan mode before big changes | Prevents expensive wrong-direction rework | Large, irregular |
| 11 | Effort levels matched to task | `effort: low` on scan agents; `MAX_THINKING_TOKENS` | Moderate |
| 12 | Custom compaction instructions | Preserves paths and decisions, drops transcripts | Moderate |

Two counter-intuitive points worth stating plainly:

- **Rich briefings save tokens.** Spending 400 tokens listing file paths in a delegation message routinely saves several thousand tokens of searching. Under-briefing is a false economy.
- **Verification saves tokens.** A caught defect costs one review pass. An escaped defect costs a bug report, a re-investigation with no context, a fix, and a regression test — many multiples more.

## 11.3 Measuring it honestly

The unit that matters is not tokens per day; it is **tokens per accepted change**. Tokens per day rewards doing less work. Tokens per merged PR rewards doing the same work more cheaply.

```
TPAC = total tokens in period ÷ merged PRs in period
```

**Establish a baseline before you build the system.** Run two weeks of normal work with telemetry on and no pipeline. Record TPAC, plus median time-to-merge and defects escaping to review. Without this number, any savings claim you make later is invented.

Then compute monthly:

```
Savings/month = (TPAC_baseline − TPAC_current) × merged_PRs_this_month
Cost/month    = tokens × published per-token rate for each model
```

Track alongside it, because the token number alone can mislead: escaped-defect rate, rework rate (phases re-entered), and time-to-merge. A pipeline that halves tokens while doubling escaped defects is a loss.

## 11.4 Telemetry

Claude Code exports OpenTelemetry metrics, events and (in beta) traces. This is what makes the monthly report real rather than anecdotal.

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

A local Prometheus plus Grafana, or an OTel collector into whatever you already run, is enough. Verify the pipeline by checking your backend for `claude_code.session.count` after starting a session.

The metrics you will build the report on:

| Metric | Unit | Key attributes |
|---|---|---|
| `claude_code.token.usage` | tokens | `type` (input/output/cacheRead/cacheCreation), `model`, `query_source` (main/subagent/auxiliary), `agent.name`, `skill.name`, `plugin.name`, `mcp_server.name`, `effort` |
| `claude_code.cost.usage` | USD | same attribute set |
| `claude_code.session.count` | count | `start_type` |
| `claude_code.lines_of_code.count` | count | `type` (added/removed), `model` |
| `claude_code.commit.count` / `.pull_request.count` | count | standard |
| `claude_code.active_time.total` | seconds | `type` (user/cli) |

The `agent.name` and `skill.name` attributes are the important ones for you: they let the monthly report attribute spend to individual agents in your roster and show which ones are earning their keep. Note the redaction behaviour — user-defined agent names collapse to `custom`, and third-party plugin skill names to `third-party`, unless the relevant detail flags are set. For internal attribution, set `OTEL_LOG_TOOL_DETAILS=1` and understand that it also logs Bash commands and tool inputs.

Add team dimensions with `OTEL_RESOURCE_ATTRIBUTES="project=pbk,team=platform"` (no spaces; percent-encode anything unusual).

Without a collector, the fallback is `/usage`, which on paid plans attributes recent usage to skills, subagents, plugins and individual MCP servers as a percentage of the total, and flags behaviours like long context or cache misses when they account for 10% or more. Press `d` or `w` to toggle 24-hour and 7-day windows. It is computed from local session history on that machine only.

---

# 12. The reporting system

You asked for three reports. Build them as one skill that runs three scripts. **Do the mechanical work in scripts, not in the model** — a Python script that walks the tree costs zero tokens; asking Claude to read every file costs a fortune. The model's job is interpretation, not counting.

## 12.1 `/studio-report`

```markdown
<!-- .claude/skills/studio-report/SKILL.md -->
---
description: Generates the monthly codebase structure, documentation inventory, and token consumption reports. Use at month end or when asked for a project health report.
disable-model-invocation: true
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/*) Bash(git *) Read Write
argument-hint: [YYYY-MM]
---

Generate the monthly report set for period $ARGUMENTS (default: last month).

1. `python3 ${CLAUDE_SKILL_DIR}/scripts/structure.py . docs/reports/$ARGUMENTS/`
2. `python3 ${CLAUDE_SKILL_DIR}/scripts/docs_audit.py . docs/reports/$ARGUMENTS/`
3. `python3 ${CLAUDE_SKILL_DIR}/scripts/tokens.py $ARGUMENTS docs/reports/$ARGUMENTS/`

Then read the three JSON outputs and write
`docs/reports/$ARGUMENTS/SUMMARY.md`:

- **Codebase** — size, module map, largest and most-churned files, test
  coverage by area, and any module that grew more than 20% this month.
- **Documentation** — coverage percentage, the stale list ranked by risk,
  ADRs added, and specs closed without a verification file.
- **Tokens** — total by model and by agent, cost, TPAC against baseline,
  the three largest consumers, and the estimated saving from each active
  optimisation with the evidence for it.
- **Recommendations** — at most five, each with the number behind it.

Do not restate the raw numbers as prose. Interpret them. Every claim of a
saving must cite the metric it came from; if the data does not support a
claim, say the data does not support it.
```

## 12.2 Structure report

```python
#!/usr/bin/env python3
# .claude/skills/studio-report/scripts/structure.py
import json, subprocess, sys
from pathlib import Path
from collections import Counter, defaultdict

IGNORE = {'.git','node_modules','vendor','dist','build','__pycache__',
          '.venv','storage','public/build','.next'}
CODE = {'.php','.js','.ts','.tsx','.jsx','.vue','.py','.go','.rs','.css','.blade.php'}

def walk(root: Path):
    files, by_ext, by_dir = [], Counter(), defaultdict(lambda: {'files':0,'lines':0})
    for p in root.rglob('*'):
        if any(part in IGNORE for part in p.parts) or not p.is_file():
            continue
        ext = p.suffix.lower()
        if ext not in CODE:
            continue
        try:
            lines = sum(1 for _ in p.open('r', errors='ignore'))
        except OSError:
            continue
        rel = p.relative_to(root)
        top = rel.parts[0] if len(rel.parts) > 1 else '(root)'
        files.append({'path': str(rel), 'lines': lines, 'ext': ext})
        by_ext[ext] += lines
        by_dir[top]['files'] += 1
        by_dir[top]['lines'] += lines
    return files, by_ext, by_dir

def churn(root: Path, since='1 month ago'):
    try:
        out = subprocess.run(
            ['git','-C',str(root),'log',f'--since={since}','--name-only','--pretty=format:'],
            capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return {}
    return dict(Counter(l for l in out.splitlines() if l.strip()).most_common(30))

if __name__ == '__main__':
    root = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
    files, by_ext, by_dir = walk(root)
    report = {
        'generated': subprocess.run(['date','-Iseconds'],capture_output=True,text=True).stdout.strip(),
        'totals': {'files': len(files), 'lines': sum(f['lines'] for f in files)},
        'by_extension': dict(by_ext.most_common()),
        'by_module': {k: v for k, v in sorted(by_dir.items(), key=lambda x: -x[1]['lines'])},
        'largest_files': sorted(files, key=lambda f: -f['lines'])[:25],
        'most_churned': churn(root),
    }
    (out/'structure.json').write_text(json.dumps(report, indent=2))
    print(f"wrote {out/'structure.json'}: {report['totals']['files']} files, "
          f"{report['totals']['lines']:,} lines")
```

The interesting output is not the line count — it is the intersection of *largest* and *most-churned*. Those files are where your defects and your token spend both concentrate.

## 12.3 Documentation inventory

```python
#!/usr/bin/env python3
# .claude/skills/studio-report/scripts/docs_audit.py
import json, subprocess, sys
from pathlib import Path

def git_epoch(root: Path, rel: str) -> int:
    r = subprocess.run(['git','-C',str(root),'log','-1','--format=%ct','--',rel],
                       capture_output=True, text=True)
    try: return int(r.stdout.strip())
    except ValueError: return 0

# Map a source area to the doc that is supposed to describe it.
DOC_MAP = {
    'app/Services':          'docs/architecture/services.md',
    'app/Http/Controllers':  'docs/api/README.md',
    'database/migrations':   'docs/architecture/data-model.md',
    'resources/js':          'docs/design/components.md',
    '.github/workflows':     'docs/runbooks/ci.md',
}

if __name__ == '__main__':
    root = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
    docs = sorted(str(p.relative_to(root)) for p in (root/'docs').rglob('*.md')) \
           if (root/'docs').exists() else []

    stale, missing = [], []
    for area, doc in DOC_MAP.items():
        if not (root/area).exists():
            continue
        if not (root/doc).exists():
            missing.append({'area': area, 'expected_doc': doc}); continue
        code_t, doc_t = git_epoch(root, area), git_epoch(root, doc)
        if code_t > doc_t:
            stale.append({'area': area, 'doc': doc,
                          'days_behind': round((code_t-doc_t)/86400, 1)})

    specs = sorted((root/'docs'/'specs').glob('*')) if (root/'docs'/'specs').exists() else []
    unverified = [s.name for s in specs if s.is_dir() and not (s/'verification.md').exists()]

    report = {
        'doc_count': len(docs),
        'adr_count': len(list((root/'docs'/'adr').glob('*.md'))) if (root/'docs'/'adr').exists() else 0,
        'spec_count': len([s for s in specs if s.is_dir()]),
        'specs_without_verification': unverified,
        'missing_docs': missing,
        'stale_docs': sorted(stale, key=lambda d: -d['days_behind']),
        'coverage_pct': round(100*(len(DOC_MAP)-len(missing)-len(stale))/max(len(DOC_MAP),1), 1),
        'all_docs': docs,
    }
    (out/'docs_audit.json').write_text(json.dumps(report, indent=2))
    print(f"docs coverage {report['coverage_pct']}% · {len(stale)} stale · "
          f"{len(missing)} missing · {len(unverified)} specs unverified")
```

Extend `DOC_MAP` as the project grows. The `specs_without_verification` list is the one that catches process drift fastest — a spec directory with no verification file is a feature that shipped without passing Phase 5.

## 12.4 Token report

Two sources depending on your setup. With a Prometheus-compatible backend, these are the queries behind the report:

```promql
# Monthly tokens by model
sum by (model) (increase(claude_code_token_usage_total[30d]))

# Attribution to your agents
sum by (agent_name) (increase(claude_code_token_usage_total[30d]))

# Main session vs subagent vs auxiliary
sum by (query_source) (increase(claude_code_token_usage_total[30d]))

# Cache efficiency — the ratio that tells you if /clear discipline is working
sum(increase(claude_code_token_usage_total{type="cacheRead"}[30d]))
  /
sum(increase(claude_code_token_usage_total{type="input"}[30d]))

# Monthly cost
sum(increase(claude_code_cost_usage_total[30d]))

# Tokens per accepted change
sum(increase(claude_code_token_usage_total[30d]))
  /
sum(increase(claude_code_pull_request_count_total[30d]))
```

Without a collector, parse the local session transcripts under `~/.claude/projects/*/`. Treat that as version-specific: the transcript format is internal to Claude Code and changes between releases, so a parser built on it will need maintenance. The OTel route is the durable one.

## 12.5 What the savings section should and should not say

Be disciplined here, because this is where these reports usually become fiction.

**Defensible:** "Output filtering hooks fired on 214 test runs this month. Sampled unfiltered output averaged 11,400 tokens; filtered averaged 890. Estimated saving: 2.25M tokens." That has a mechanism, a count, and a measurement.

**Not defensible:** "The multi-agent architecture saved 40% of tokens." There is no counterfactual. You cannot measure what a different architecture would have cost on the same work.

So structure the savings section as: **measured** (things with a before-and-after on the same operation), **attributed** (spend by agent, model and skill, straight from the metrics), and **estimated** (levers with a stated mechanism and an explicit assumption). Label each. A report that distinguishes these three stays useful in month six; one that blends them stops being read.
---

# 13. Step-by-step build

Roughly 12–16 hours of setup spread over two weeks, with a working pipeline after Day 3. Do not compress it — Phase 0 in particular is worthless if done retroactively.

## Phase 0 — Baseline (Day 1, 1 hour, then two weeks of passive collection)

**Do this before you build anything.** Without a baseline every savings number later is invented.

```bash
claude --version
claude doctor                     # or /doctor in-session

# telemetry on, in ~/.claude/settings.json under "env"
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

Stand up an OTel collector plus Prometheus and Grafana (a three-service Docker Compose file is enough). Confirm `claude_code.session.count` appears after you start a session.

Then work normally for two weeks and record: total tokens, merged PRs, TPAC, median time-to-merge, defects found in review, defects escaped to production. Write it to `docs/reports/baseline.md`. This file is the reference point for every report you generate afterwards.

## Phase 1 — Foundation (Day 1, 2 hours)

```bash
mkdir -p .claude/{agents,skills,rules,hooks,state,workflows}
mkdir -p docs/{adr,specs,api,design,runbooks,handoff,reports}
echo '{"phase":"idle","approved_phases":[]}' > .claude/state/gate.json

# generate, then trim, the constitution
CLAUDE_CODE_NEW_INIT=1 claude
# in session: /init  → review the proposal → accept → then trim hard
```

Write `.claude/rules/{frontend,backend,database,security,testing,seo}.md` with `paths:` frontmatter. Add `CLAUDE.local.md` and `.claude/settings.local.json` to `.gitignore`; commit everything else including `.claude/agent-memory/`.

**Checkpoint:** run `/context`. CLAUDE.md plus rules should be a small fraction of the window. If not, cut now — it only gets harder later.

## Phase 2 — External stack (Day 2, 2 hours)

Install language servers first, then the plugins, then the two light MCP servers, exactly as in §8.2. Then framework-native MCP if you have one.

**Checkpoint:** `/context` again. Pre-prompt total under ~15% of the window. Then `/mcp` and disable anything not in daily use.

## Phase 3 — The nine agents (Day 2–3, 3 hours)

Write the nine starter agents. The fastest route is to have Claude write them from your specification and then edit the frontmatter yourself:

```
Create a subagent at .claude/agents/red-team-critic.md. Read-only tools
(Read, Grep, Glob, Write for its critique file only). Model opus. Project
memory. Its job: adversarially review a plan before implementation and file
severity-ranked findings to docs/specs/<slug>/critique.md. Include the
checklist from docs/process/critique-checklist.md verbatim.
```

Review each generated file by hand. The frontmatter is where the cost and safety live — check `tools`, `model`, `memory` and `disallowedTools` on every one.

**Checkpoint:** `/doctor`. It reports duplicate agent names, which silently break delegation.

## Phase 4 — Skills (Day 3–4, 3 hours)

Six phase playbooks plus `debate`, `handoff`, `codebase-map`, `design-tokens`, `studio-report`.

Keep each under 500 lines with reference material in sibling files. Set `disable-model-invocation: true` on anything with side effects — `handoff`, `studio-report`, `debate` — so Claude cannot decide on its own to run them.

Then teach `/verify` your project:

```
/run-skill-generator
```

Run this once. It gets your app running from a clean environment, captures the install commands, env vars and launch script that actually worked, and commits the recipe to `.claude/skills/run-<name>/`. Every later `/run` and `/verify` follows it instead of rediscovering the launch. Re-run it whenever the build process changes.

## Phase 5 — Enforcement (Day 4, 2 hours)

Write the six hooks from §10, `chmod +x .claude/hooks/*.sh`, wire `settings.json`, then **test each one deliberately**:

```
# Should be blocked (gate is not in 'create')
Edit app/Models/User.php to add a comment

# Should be allowed
Create docs/specs/test/idea.md with a one-line summary

# Should return only failures, not the full suite output
Run the test suite
```

A hook you have not seen fire is a hook you do not have. `/hooks` shows what registered; `claude --debug` shows what ran.

## Phase 6 — Memory seeding (Day 5, 2 hours)

Run the five read-only survey passes from §5.4 — one per specialist — then commit `.claude/agent-memory/`. Build the `codebase-map` skill from what those surveys found. Write `docs/reports/baseline.md` if you have not already.

## Phase 7 — Reporting (Day 5–6, 2 hours)

Drop the three scripts into `.claude/skills/studio-report/scripts/`, run each once directly to confirm they work standalone, then run `/studio-report 2026-08` end to end. Fix anything that only works when Claude is holding it.

## Phase 8 — Pilot (Week 2)

Take one real, medium-sized feature through the full cycle.

```
Use the conductor agent to start a new feature: <description>.
```

Then, one turn per gate:

```
Run the idea phase.                                  → approve idea.md
Run the plan phase, then dispatch red-team-critic.   → approve plan.md + resolve critique
Run the test phase.                                  → confirm tests are red
Run the create phase.                                → confirm tests go green
Run the verify phase with all five auditors in parallel.
Run the document phase, then /handoff.
```

Keep a friction log as you go. Where did you have to intervene? Which agent produced something you rewrote? Which gate felt like theatre? That log is the input to Phase 9.

## Phase 9 — Tune (Week 3 onward)

- Fix the two or three highest-friction items from the pilot. Usually: a vague agent description that causes wrong delegation, a briefing template missing a field, or a gate with no real artifact behind it.
- Only now add agents beyond the nine, and only where you can name the failure the new agent prevents.
- Use `skill-creator` to A/B a skill's before-and-after and confirm an edit is actually an improvement: it spawns a subagent per test case, records tokens and duration, grades assertions with evidence, and benchmarks with-skill against without-skill. This is the only rigorous way to know whether a skill is earning its context cost.
- Monthly: run `/studio-report`, run `memory-curator`, audit `/context` and `/plugin` for drift, and hold a short retro in `00-Pipeline/Retros/`.

---

# 14. Anti-patterns

Things that look like good ideas and are not.

| Anti-pattern | Why it fails | Do instead |
|---|---|---|
| 24 agents on day one | Coordination cost and token spend arrive immediately; the benefit does not | Nine, then add against named failures |
| Agent teams for sequential work | 7× tokens for work that cannot parallelise | Subagents, or a single session |
| Every MCP server you find | Tens of thousands of tokens before you type | 3–5 active; scope the heavy ones to one agent |
| CLAUDE.md as a knowledge base | Longer files reduce adherence and cost every turn | <200 lines; procedures to skills; scoped standards to rules |
| Rules in prompts instead of hooks | Advisory, probabilistically followed | Hooks for anything that must hold |
| Accepting "done" | The dominant failure mode of spec-driven setups | Every gate demands an artifact file |
| One reviewer for everything | Anchors on the first class of issue and stops | Parallel specialist auditors |
| Agents writing into the Obsidian vault | Your thinking and generated output become indistinguishable | Agents write to `docs/`; the vault reads it |
| One long session all day | Full history re-sent every request | `/rename`, `/clear`, `/resume` |
| Installing plugins unread | Arbitrary code with your privileges | Read the manifest and the **Will install** panel |
| `bypassPermissions` as the default | Defeats every guardrail you built | `acceptEdits` or `auto`; bypass only in sandboxes |
| Reports that assert savings | Unfalsifiable, and stop being read | Separate measured / attributed / estimated |

---

# 15. Quick reference

## 15.1 Daily commands

| Command | Use |
|---|---|
| `/context` | What is consuming the window right now |
| `/usage` | Token and cost breakdown by skill, subagent, plugin, MCP server |
| `/clear` · `/rename` · `/resume` | Session hygiene between unrelated tasks |
| `/compact <focus>` | Summarise with an explicit instruction on what to keep |
| `/rewind` | Restore conversation and code to a checkpoint |
| `/doctor` | Config checkup: duplicates, oversized memory, skill listing overflow |
| `/hooks` · `/mcp` · `/plugin` | Verify what actually loaded |
| `/memory` | Browse and edit memory files; toggle auto memory |
| `/code-review` · `/verify` · `/run` | Bundled verification skills |
| `/tasks` · `/workflows` | Watch background subagents and workflow runs |
| `/effort` | Match reasoning effort to the task |

## 15.2 Environment variables

| Variable | Effect |
|---|---|
| `CLAUDE_CODE_ENABLE_TELEMETRY=1` | Required for all OTel export |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` | Enables agent teams (off by default) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Forces every subagent onto one model |
| `MAX_THINKING_TOKENS` | Caps thinking budget on fixed-budget models |
| `CLAUDE_CODE_NEW_INIT=1` | Interactive multi-phase `/init` |
| `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` | Concurrency cap (default 20) |
| `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` | Nesting depth (default 3) |
| `OTEL_LOG_TOOL_DETAILS=1` | Un-redacts agent, skill and MCP names in telemetry |
| `OTEL_RESOURCE_ATTRIBUTES` | Team/project dimensions on every metric |

## 15.3 One-page install

```bash
# Plugins
/plugin marketplace add anthropics/claude-plugins-official
/plugin marketplace add anthropics/claude-plugins-community
/plugin marketplace add affaan-m/everything-claude-code
/plugin install security-guidance@claude-plugins-official
/plugin install skill-creator@claude-plugins-official
/plugin install pr-review-toolkit@claude-plugins-official
/plugin install commit-commands@claude-plugins-official
/plugin install typescript-lsp@claude-plugins-official
/reload-plugins

# Design
claude plugin add anthropic/frontend-design
npx add-skill addyosmani/web-quality-skills
npx ui-skills add baseline-ui
npx ui-skills add fixing-accessibility
npx ui-skills add fixing-motion-performance

# MCP — light, always on
claude mcp add context7 -s user -- npx -y @upstash/context7-mcp@latest
claude mcp add -s user -t http github https://api.githubcopilot.com/mcp/

# MCP — heavy, scope these to a single agent's frontmatter instead
#   playwright        → qa-runner
#   chrome-devtools   → perf-a11y-auditor
#   figma-dev-mode    → ui-designer

# Framework-native (example: Laravel)
composer require laravel/boost --dev && php artisan boost:install
```

## 15.4 Discipline coverage map

Every discipline you listed, and where it lives in the system.

| Discipline | Agent | Rule file | Gate |
|---|---|---|---|
| Database design | `data-architect`, `db-engineer` | `database.md` | Reversible migration + test |
| UI/UX | `ux-researcher`, `ui-designer` | `frontend.md` | Direction + token spec approved |
| Prototyping | `ui-designer` + Claude Design / Stitch | `frontend.md` | Mockup referenced in plan |
| Planning | `system-architect`, `conductor` | — | `plan.md` + resolved critique |
| Frontend | `frontend-engineer` | `frontend.md` | Green tests + visual evidence |
| Backend | `backend-engineer` | `backend.md` | Green tests + contract conformance |
| System structure | `system-architect` | — | ADR per irreversible decision |
| Cyber security | `security-architect`, `security-auditor` | `security.md` | Threat model + zero criticals |
| DevOps | `devops-planner`, `infra-engineer` | — | Pipeline green + rollback documented |
| DevSecOps | `security-guidance` plugin + `security-auditor` | `security.md` | Dependency and secret scan clean |
| SEO | `seo-auditor` | `seo.md` | Checklist pass |
| Performance | `a11y-perf-budgeter`, `perf-a11y-auditor` | `frontend.md` | CWV within budget |
| Testing | `test-designer`, `qa-runner` | `testing.md` | Red-then-green evidence |
| Optimisation | `perf-a11y-auditor`, `report-generator` | — | Monthly report |
| Responsiveness | `frontend-engineer`, `perf-a11y-auditor` | `frontend.md` | Screenshots at every breakpoint |
| Mobile view | `frontend-engineer`, `qa-runner` | `frontend.md` | 390px pass, no 320px overflow |

---

# 16. What this system will and will not do

**It will:** make the process visible and auditable; stop code from being written before someone has argued about the design; produce evidence rather than assertions; accumulate real knowledge of your codebase in version-controlled agent memory; keep documentation close to current; and give you numbers about your own spend that are good enough to act on.

**It will not:** replace your judgement at the gates. Every gate in this design ends with you approving something. That is deliberate — the gates are where a bad plan gets caught cheaply, and an approval you rubber-stamp is a gate that does not exist. The moment you approve without reading, the pipeline degrades into an expensive way to generate confident-looking output.

**Start small.** Nine agents, six hooks, six skills, two MCP servers, one pilot feature. Everything in this document beyond that is an optimisation you should only add once you can point at the specific problem it solves.

---

# 17. Sources

Official documentation (verified August 2026):

- Claude Code docs index — `code.claude.com/docs/llms.txt`
- Subagents — `code.claude.com/docs/en/sub-agents`
- Agent teams — `code.claude.com/docs/en/agent-teams`
- Dynamic workflows — `code.claude.com/docs/en/workflows`
- Skills — `code.claude.com/docs/en/skills`
- Memory and CLAUDE.md — `code.claude.com/docs/en/memory`
- Hooks — `code.claude.com/docs/en/hooks` and `hooks-guide`
- Managing costs — `code.claude.com/docs/en/costs`
- Monitoring / OpenTelemetry — `code.claude.com/docs/en/monitoring-usage`
- Plugin discovery — `code.claude.com/docs/en/discover-plugins`
- MCP — `code.claude.com/docs/en/mcp`
- Security guidance plugin — `code.claude.com/docs/en/security-guidance`
- Official plugin catalogue — `claude.com/plugins`
- Laravel Boost — `laravel.com/docs/13.x/boost`

Community resources referenced:

- `wilwaldon/Claude-Code-Frontend-Design-Toolkit` — frontend design tooling map
- `affaan-m/everything-claude-code` — agents, hooks, token-optimisation patterns
- `VoltAgent/awesome-claude-code-subagents` — subagent collection
- `addyosmani/web-quality-skills` — performance, accessibility and SEO audit skills
- `bitbonsai/mcpvault`, `MarkusPfundstein/mcp-obsidian` — Obsidian MCP servers
- GitHub Spec Kit (`specify`) and BMAD-METHOD — spec-driven development frameworks

Claude Code changes weekly. Re-check the official pages before turning any command in this guide into a permanent standard, and treat version-gated features (agent teams, workflows, `/verify`) as subject to change.
