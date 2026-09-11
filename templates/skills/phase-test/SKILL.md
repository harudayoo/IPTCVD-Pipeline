---
description: Runs the TEST phase — turns approved acceptance criteria into a test matrix and actual failing tests committed to the repo. Use after the PLAN gate is approved, before any implementation.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(cat .claude/state/gate.json) Bash(bash .claude/scripts/gate.sh *)
---

Gate: !`cat .claude/state/gate.json 2>/dev/null || echo '{"phase":"idle"}'`

## Owner

`test-designer`, with `a11y-perf-budgeter` on any UI work.

## Why this phase comes before CREATE

A written test matrix is a promise. A red test run is a contract. Only the
second one is falsifiable, which is why this phase does not close on the
matrix — it closes on the failing run.

## Required output

- `docs/specs/<slug>/acceptance.md` — the test matrix, EARS form, mapping each
  numbered acceptance criterion to the test that proves it and the level it is
  tested at
- **The test files themselves, committed to the repo**
- `docs/specs/<slug>/evidence/tests-red.txt` — the captured failing run
- `docs/specs/<slug>/budget.md` — when `a11y-perf-budgeter` ran

## Level discipline

Unit for logic and branches. Integration for boundaries — database, HTTP,
queue. End-to-end only for the critical user path. Do not write an E2E test for
something a unit test can prove; you will pay for it on every run forever.

## Gate

This phase closes when:

1. Every numbered acceptance criterion maps to at least one test.
2. `evidence/tests-red.txt` shows the new tests failing.
3. Each new test fails **for the right reason** — because the feature is
   missing, not because of a typo, a missing import, or a bad fixture. The
   agent must state this explicitly per test. A test that fails for the wrong
   reason will pass for the wrong reason too.
4. **You approve it.**

Then open the gate. This is the transition that unblocks source, and it is
the only one that demands the slice's answers, because this is the phase that
produced them:

```bash
bash .claude/scripts/gate.sh create \
  --problem "<what breaks, and what is out of scope>" \
  --red     "<the test that fails NOW, with its actual failure line>" \
  [--reuse  "<reuse X / extend X / new because X cannot Y>"] \
  [--deps   "<what you checked first, and why it does not cover this>"]
```

`--red` takes the real failure — the assertion and the observed value, not
"tests written". If this change genuinely has no behaviour to pin (a design
token, a comment, a config rename), say so explicitly: `--red "n/a: <why>"`.
The gate refuses a bare `n/a`, because the entire value of this phase is that a
change with no failing test has to say why.

`--reuse` is required only when the plan CREATES a file under a declared shared
surface; `--deps` only when it edits a dependency manifest. The hook will tell
you which one it wants, and name the file that triggered it.

Then append `test` to `approved` in `.claude/state/gate.json`.

The gate hook opens source files for writing at this point. That is the whole
purpose of this phase.
