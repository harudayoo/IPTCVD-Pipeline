---
description: Runs the PLAN phase — architecture, contracts, data design, threat model and the adversarial critique that must clear before any code is written. Use after the IDEA gate is approved.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *) Bash(cat .claude/state/gate.json) Bash(bash .claude/scripts/gate.sh *)
---

Gate: !`cat .claude/state/gate.json 2>/dev/null || echo '{"phase":"idle"}'`

## Owner

`system-architect`, drawing on the specialists the surface actually demands.
Do not run all six on a two-file change — each one is a fresh context window.

| Draw in | When |
|---|---|
| `data-architect` | the change touches schema, indexes or retention |
| `api-designer` | the change touches an API boundary |
| `ui-designer` | the change has a user-facing surface |
| `security-architect` | the change crosses an authorisation or trust boundary |
| `devops-planner` | the change alters how this deploys or runs |

Then `red-team-critic`, **once**. Being re-run signals a rushed plan.

Permission mode: **plan** — documents only, no source edits.

## Required output

- `docs/specs/<slug>/plan.md` — always
- `docs/specs/<slug>/critique.md` — always
- `data.md`, `api.md`, `design.md`, `threat-model.md`, `delivery.md` — from
  whichever specialists ran
- One ADR in `docs/adr/NNNN-<slug>.md` per irreversible decision

## Debate escalation

Run `/debate` **before** approving the plan if this change touches any of:
authentication or authorisation, payments or billing, a destructive migration, a
public API contract, PII handling, rate limiting or abuse controls, or anything
whose rollback is not a single revert.

Two agents disagreeing is also a trigger. Do not average their answers — run the
rubric and let the judge decide.

## Gate

This phase closes when:

1. `plan.md` exists with a module map naming one owning agent per file.
2. `critique.md` exists and **every** BLOCKER and MAJOR is either resolved in
   the plan or explicitly accepted with a written reason.
3. Every contract crossing a module boundary is stated precisely enough that
   the two sides could be built in parallel.
4. **You approve it.**

Two decisions belong to THIS phase, not to the moment code is written,
because both are cheap now and expensive later:

- **Reuse.** If the plan creates a file under a shared surface (components,
  pages, services), state what already exists and why it does not cover this.
  Ask the codebase before writing a fifth near-duplicate of something.
- **Dependencies.** If the plan adds a package, state what already-present
  capability you checked first. A dependency carries transitive packages, a CVE
  surface, a licence and an upgrade obligation — it is the most expensive kind
  of reuse.

Hold both; they become `--reuse` and `--deps` when the gate is opened.

```bash
bash .claude/scripts/gate.sh test
```

Then update `.claude/state/gate.json`: set `owner_files`
from the module map, and append `plan` to `approved`.

Tell me to run `/clear` before starting the test phase.
