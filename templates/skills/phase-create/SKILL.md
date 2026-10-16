---
description: Runs the CREATE phase — implements the approved plan against the red tests until they pass, one owning agent per file set. Use only after the TEST gate is approved.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(cat .claude/state/gate.json) Bash(bash .claude/scripts/gate.sh *)
---

Gate: !`cat .claude/state/gate.json 2>/dev/null || echo '{"phase":"idle"}'`
Tree: !`git status --short 2>/dev/null | head -20`

## Owners

Read the module map in `docs/specs/<slug>/plan.md` and dispatch by file set:

| Agent | Owns |
|---|---|
| `backend-engineer` | services, handlers, jobs, commands |
| `frontend-engineer` | components, state, styles |
| `db-engineer` | migrations, seeders, query tuning |
| `infra-engineer` | workflows, containers, IaC, environment config |

**One owner per file. Never two agents in one file** — that is a merge conflict
you scheduled deliberately. If the module map assigns a file to two agents, the
plan is wrong; go back rather than improvising.

Brief **one execution slice per dispatch**, pasting that slice from `plan.md`
verbatim into the briefing. Handing a Sonnet engineer the whole plan and
"implement it" is how a long build drifts from the design; a slice with exact
files, contract, steps and a done-command is not open to interpretation.

The gate enforces the plan's `Scope:` line (`gate.sh show` prints it). An
engineer that reports a file "outside the plan's file map" has found a gap in
the PLAN: amend `plan.md`, then `gate.sh scope "<amended line>"`, then
re-dispatch. Never widen the scope just to let the edit through.

Agents whose file sets do not overlap can run in parallel. Agents on either side
of a contract cannot start together unless the contract in `api.md` is precise
enough to build against without asking.

## Required output

- The implementation
- `docs/specs/<slug>/evidence/tests-green.txt`
- `evidence/migration.txt` when `db-engineer` ran (up, down, up — executed)
- `evidence/infra.txt` when `infra-engineer` ran

## Gate

This phase closes when:

1. The previously-red tests are green, captured in `evidence/tests-green.txt`.
2. Lint and type checks pass.
3. **The diff touches only files the plan named.** The gate already refused
   anything outside the recorded scope; check `git diff HEAD --name-only`
   against it anyway, because a scope recorded too wide lets drift through.
4. **You approve it.**

Then advance. `advance` carries the slice's notes forward rather than
restating them — a phase change is not a new plan:

```bash
bash .claude/scripts/gate.sh advance verify
```

Source is **read-only** once verify starts — gate-check.sh refuses an Edit in
any phase but `create`. A review finding worth fixing re-opens source with
`gate.sh advance create`, not a direct edit made mid-verify.

Then append `create` to `approved` in `.claude/state/gate.json`.

Tell me to run `/clear` before starting the verify phase.
