---
description: Runs the VERIFY phase — five read-only auditors dispatched in parallel, each returning severity-ranked findings with evidence. Use after the CREATE gate is approved.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(cat .claude/state/gate.json) Bash(bash .claude/scripts/gate.sh *)
---

Gate: !`cat .claude/state/gate.json 2>/dev/null || echo '{"phase":"idle"}'`
Diff: !`git diff --stat HEAD 2>/dev/null | tail -20`

## Why this is a fan-out, not a step

Security, performance, accessibility, SEO and correctness are genuinely
independent lenses. A single reviewer anchors on the first class of problem it
finds and stops looking. Five narrow reviewers in parallel cost one dispatch and
find five different things.

## Dispatch

Run these **in parallel from a single dispatch**. All are read-only; none may
fix anything in this turn.

| Agent | Lens | Skip when |
|---|---|---|
| `code-reviewer` | correctness, contract drift, error handling, duplication | never |
| `security-auditor` | authorisation, IDOR, OWASP, dependencies, secrets | never |
| `qa-runner` | real test execution and browser evidence | no runnable suite |
| `perf-a11y-auditor` | Core Web Vitals, axe, keyboard, breakpoints | no UI change |
| `seo-auditor` | metadata, headings, structured data, crawlability | no public route |

Each returns findings ranked BLOCKER / MAJOR / MINOR, each citing `file:line`
or an advisory ID, plus evidence paths.

## Required output

`docs/specs/<slug>/verification.md` — the merged, deduplicated, severity-ranked
set of findings, plus browser evidence: screenshots at each breakpoint, console
log, network trace.

Merge and rank; do not paste five reports end to end.

## Gate

This phase closes when:

1. Zero BLOCKERs remain.
2. Every MAJOR and MINOR is triaged — fixed, or accepted with a written reason.
3. Evidence exists for each claim. "Done" is a claim; a passing run, a
   screenshot, or an audit file is evidence.
4. **You approve it.**

## Where findings go

Findings that become work re-enter at **TEST**, not at CREATE. A bug fix gets a
failing test first — that is the same rule the whole pipeline is built on, and
the verify gate is exactly where people are most tempted to skip it.

Then close the gate to source:

```bash
bash .claude/scripts/gate.sh advance document
```

Then update `.claude/state/gate.json`: append
`verify` to `approved`.
