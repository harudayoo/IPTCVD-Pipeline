---
description: Runs a change through the Idea, Plan, Test, Create, Verify, Document pipeline one gate at a time. Use to start any feature, bug fix, or non-trivial change.
disable-model-invocation: true
argument-hint: [description of the change]
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *) Bash(cat .claude/state/gate.json) Bash(bash .claude/scripts/gate.sh *)
---

Feature: $ARGUMENTS

Gate: !`cat .claude/state/gate.json 2>/dev/null || echo '{"phase":"idle"}'`
Tree: !`git status --short 2>/dev/null | head -20`

Hand this to the `conductor` agent. It owns phase order and the gate file; it
never writes application code.

## Protocol

Run **exactly one phase per turn**, then stop and report which gate needs my
approval. Never skip forward. Never combine phases.

| Phase | Owner | Artifact required before the gate closes |
|---|---|---|
| 1 · idea | `product-analyst` | `docs/specs/<slug>/idea.md` — problem, scope, EARS acceptance criteria, no open questions |
| 2 · plan | `system-architect`, then `red-team-critic` | `plan.md` with a module map + `critique.md` with every BLOCKER and MAJOR resolved or explicitly accepted |
| 3 · test | `test-designer` | `acceptance.md` + `evidence/tests-red.txt` showing the new tests failing **for the right reason** |
| 4 · create | `backend-engineer`, `frontend-engineer` — one owner per file set | `evidence/tests-green.txt`, diff touching only files the plan named |
| 5 · verify | `code-reviewer`, `security-auditor`, `qa-runner` — dispatched **in parallel**, all read-only | `verification.md`, zero BLOCKERs, browser evidence |
| 6 · document | `doc-writer` | updated `docs/` + `docs/handoff/<date>-<slug>.md` |

## Advancing the gate

Phase transitions go through `gate.sh`, never by writing `gate.json` by hand.
Writing `{"phase":"create"}` directly sets the phase and **erases** the slice's
`problem` and `red` notes, so the gate slams shut on a change that had answered
everything correctly — and the error appears one phase later than the mistake.

```bash
bash .claude/scripts/gate.sh plan            # phases that keep source blocked
bash .claude/scripts/gate.sh test

bash .claude/scripts/gate.sh create \
  --problem "<what breaks, and what is out of scope>" \
  --red     "<the test that fails NOW, with its failure line, or n/a: why>" \
  [--reuse "<reuse X / extend X / new because X cannot Y>"] \
  [--deps  "<what you checked first, and why it does not cover this>"]

bash .claude/scripts/gate.sh advance verify  # carries the notes forward
bash .claude/scripts/gate.sh advance document
bash .claude/scripts/gate.sh idle            # re-arms the gate for the next change
```

Opening the gate is the TEST phase's job, because the TEST phase is what
produces the evidence `--red` wants. `--reuse` is demanded only when the change
creates a file under a declared shared surface, `--deps` only when it edits a
dependency manifest; the hook names the file that triggered it.

The final `idle` matters more than it looks: a gate left open stops guarding
anything, and the next change — possibly next session — silently skips the plan
requirement. The Stop hook nudges, and CI fails if it is ever committed open.

The slug and approved list are still recorded in `.claude/state/gate.json`
alongside these; only the `phase` field and the notes belong to `gate.sh`.


## Debate escalation

Run `/debate` before approving the plan when the change touches authentication
or authorisation, payments, a destructive migration, a public API contract, PII
handling, or rate limiting — or when two agents disagree. Do not average two
answers; run the rubric and let the judge decide.

## Delegation briefing template

Subagents start with an empty context and cannot see this conversation. Every
delegation must include:

    TASK: <one imperative sentence>
    SPEC: docs/specs/<slug>/plan.md — read this first
    SCOPE: you may modify only <explicit glob list>
    CONTRACT: <the interface or acceptance criterion being satisfied>
    CONTEXT YOU NEED: <3-6 bullets, including file paths already discovered>
    DONE MEANS: <the artifact path that must exist>
    DO NOT: <2-3 things that would make this a rejected result>

The CONTEXT line is the money line. Every file path handed over is a search the
subagent does not run.

## Gate discipline

- A summary in chat is not an artifact. Verify the file exists and is non-empty
  before advancing.
- Run `red-team-critic` **once** per feature. Re-running it signals a rushed plan.
- Findings that become work re-enter at phase 3, not phase 4. A bug fix gets a
  failing test first.
- If an agent reports completion without its artifact, reject and re-dispatch
  naming the missing file.
- After phase 2 and after phase 4, tell me to run `/clear` before continuing.
