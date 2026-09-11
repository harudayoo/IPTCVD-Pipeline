---
description: Generates the monthly codebase, documentation and pipeline-compliance health report. Use at month end or when asked for a project health report.
disable-model-invocation: true
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/audit.py *) Bash(git *) Bash(bash .claude/scripts/gate.sh log*) Bash(bash .claude/scripts/ratchet.sh --list)
argument-hint: [YYYY-MM]
---

1. Run `python3 ${CLAUDE_SKILL_DIR}/scripts/audit.py . docs/reports/$ARGUMENTS/`
2. Run `bash .claude/scripts/gate.sh log 500` for the gate decision history.
3. Run `bash .claude/scripts/ratchet.sh --list` for files over the size bar.
4. Read `audit.json` and write `docs/reports/$ARGUMENTS/SUMMARY.md`:

- **Codebase** — size, module breakdown, and the files that are both large
  and heavily churned. That intersection is where defects concentrate.
  Cross-reference the ratchet list: a file that is both over the bar and in
  the top churn decile is the highest-value refactor on the board.
- **Docs** — coverage, stale list ranked by risk, specs closed without a
  verification file.
- **Compliance** — read from `.claude/state/gate-log.tsv`. This is the section
  that says whether the pipeline is being *followed* rather than merely
  installed, and until it existed the only available answer was an impression.

  Report three things, and interpret each:

  | Signal | What it means |
  |---|---|
  | blocks per completed feature, trending | falling = the workflow is being internalised; flat and high = the gate is in the wrong place, not that people are careless |
  | the most common block `reason` | `missing-reuse` concentrated in one directory means that surface needs a shared component, not more discipline |
  | source edits with **zero** blocks and no `create` in the log | **the one that matters.** It means work reached source without passing the gate — a bypass nobody has found yet, or a hook that stopped firing |

  That last line is the only signal that separates "the pipeline is followed"
  from "the pipeline is inert", so lead with it when it is non-zero. A month
  with no blocks at all is not a good month; it is an unverified claim.
- **Tokens** — from `/usage`, which I will paste in. Report weekly
  consumption, the three largest consumers, features completed, and tokens
  per completed feature against `docs/reports/baseline.md`.
- **Recommendations** — at most five, each with the number behind it.

Interpret, do not restate. Separate what you **measured** from what you
**estimated**, and label each. Never assert a saving you cannot show the
mechanism for.

If `gate-log.tsv` is missing or empty, say so plainly and treat compliance as
**unmeasured** for the period. Do not infer it from commit messages — that is
exactly the substitution of an impression for a measurement this section
exists to stop.
