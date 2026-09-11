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
3. **The diff touches only files the plan named.** Anything else is scope that
   grew silently — send it back or re-open the plan deliberately.
4. **You approve it.**

Then advance. `advance` carries the slice's notes forward rather than
restating them — a phase change is not a new plan:

```bash
bash .claude/scripts/gate.sh advance verify
```

Source stays writable through verify, so review findings can be fixed without
re-opening the gate.

Then append `create` to `approved` in `.claude/state/gate.json`.

Tell me to run `/clear` before starting the verify phase.
