---
description: Generates the monthly codebase structure, documentation inventory and token consumption reports. Use at month end or when asked for a project health report.
disable-model-invocation: true
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/*) Bash(git *) Bash(bash .claude/scripts/gate.sh log*) Bash(bash .claude/scripts/ratchet.sh --list) Read Write
argument-hint: [YYYY-MM]
---

Generate the monthly report set for period $ARGUMENTS (default: last month).

Do the mechanical work in the scripts, not in the model. Walking the tree and
counting files costs zero tokens in Python and a fortune in a model. Your job is
interpretation, not counting.

1. `python3 ${CLAUDE_SKILL_DIR}/scripts/structure.py . docs/reports/$ARGUMENTS/`
2. `python3 ${CLAUDE_SKILL_DIR}/scripts/docs_audit.py . docs/reports/$ARGUMENTS/`
3. `python3 ${CLAUDE_SKILL_DIR}/scripts/tokens.py $ARGUMENTS docs/reports/$ARGUMENTS/`
4. `bash .claude/scripts/gate.sh log 500` — the gate decision history.
5. `bash .claude/scripts/ratchet.sh --list` — every file over the size bar.

Then read the three JSON outputs and write
`docs/reports/$ARGUMENTS/SUMMARY.md`:

- **Codebase** — size, module map, largest and most-churned files, test coverage
  by area, and any module that grew more than 20% this month. The intersection
  of *largest* and *most churned* is where defects and token spend both
  concentrate; that list matters more than the line count.
- **Documentation** — coverage percentage, the stale list ranked by risk, ADRs
  added, and every spec directory closed without a `verification.md`. That last
  list is the fastest signal of process drift.
- **Compliance** — read from `.claude/state/gate-log.tsv`, and cross-reference
  the ratchet list from step 5. This is the section that says whether the
  pipeline is being *followed* rather than merely installed. Without it the
  only available answer is an impression, and an impression of compliance is
  the thing this whole pipeline exists to replace.

  Report three things, and interpret each:

  | Signal | What it means |
  |---|---|
  | blocks per completed feature, trending | falling = the workflow is being internalised; flat and high = the gate is in the wrong place, not that people are careless |
  | the most common block `reason` | `missing-reuse` concentrated in one directory means that surface needs a shared component, not more discipline |
  | source edits with **zero** blocks and no `create` in the log | **the one that matters.** It means work reached source without passing the gate — a bypass nobody has found yet, or a hook that stopped firing |

  That last line is the only signal separating "the pipeline is followed" from
  "the pipeline is inert", so lead with it when it is non-zero. A month with no
  blocks at all is not a good month; it is an unverified claim.

  A file that is both over the size bar and in the top churn decile is the
  highest-value refactor on the board, and it is where token spend concentrates
  too: nobody can hold it in their head, so it gets re-read in full every
  session. That intersection belongs in **Recommendations** with both numbers
  attached.

  If `gate-log.tsv` is missing or empty, say so plainly and treat compliance as
  **unmeasured** for the period. Do not infer it from commit messages — that is
  exactly the substitution of an impression for a measurement this section
  exists to stop.
- **Tokens** — total by model and by agent, cost, and TPAC (tokens per accepted
  change) against `docs/reports/baseline.md`. Name the three largest consumers
  and the estimated saving from each active optimisation, with the evidence for
  it.
- **Recommendations** — at most five, each with the number behind it.

## Labelling discipline

Every claim in the savings section is one of exactly three kinds. Label each and
never blend them:

| Kind | Means | Example |
|---|---|---|
| **Measured** | a before-and-after on the same operation | "Filtered runs averaged 890 tokens; sampled unfiltered runs averaged 11,400." |
| **Attributed** | spend by agent, model or skill, straight from metrics | "`qa-runner` accounted for 22% of subagent tokens." |
| **Estimated** | a lever with a stated mechanism and explicit assumption | "Scoping Playwright to one agent avoids ~5k tokens/session, assuming 40 sessions." |

"The multi-agent architecture saved 40% of tokens" is not defensible — there is
no counterfactual, and you cannot measure what a different architecture would
have cost on the same work.

A report that keeps these three separate is still useful in month six. One that
blends them stops being read.

Do not restate raw numbers as prose. Interpret them. If the data does not
support a claim, say the data does not support it.

## If there is no telemetry collector

`tokens.py` falls back to parsing local session transcripts, which is coarser
and machine-local. Say so in the report rather than presenting the fallback
numbers as if they were metrics. The durable route is an OTLP collector — see
the telemetry keys in `.claude/settings.json`.
