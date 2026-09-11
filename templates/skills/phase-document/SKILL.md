---
description: Runs the DOCUMENT phase — updates docs, ADRs and changelog to match what was built, writes the handoff note, and prunes agent memory. Use as the final phase of a change.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *) Bash(cat .claude/state/gate.json) Bash(bash .claude/scripts/gate.sh *)
---

Gate: !`cat .claude/state/gate.json 2>/dev/null || echo '{"phase":"idle"}'`
Changed: !`git diff --name-only HEAD 2>/dev/null | head -40`

## Owners

`doc-writer`, then `memory-curator`.

## Required output

- Updated `docs/` — API reference, runbooks, changelog, ADR index
- `docs/handoff/<date>-<slug>.md`
- Pruned `.claude/agent-memory/`

## What doc-writer does

Document what was **actually built**, not what was planned. Read the plan, the
critique, the verification report and the diff — the diff is the authority.

Edit the existing doc where one exists. A new file where an edit belonged is how
documentation becomes three contradictory descriptions of the same thing.

Be brief. Prefer editing three sentences over adding three paragraphs. A doc
nobody reads is a doc that failed.

## What memory-curator does

Delete entries about code that no longer exists. Merge duplicates. Promote
anything rediscovered three times into a `.claude/rules/` entry — a lesson
relearned three times is not a memory, it is a missing rule.

## Gate

This phase closes when the **docs-staleness check passes**: no source file
changed in this diff has a doc that is now older than it, without an explicit
written exemption.

The `Stop` hook enforces this at the end of every session, which is what makes
documentation a gate rather than the phase that gets skipped when you are tired.

Then reset the gate. This is the step that re-arms it for the next change,
and skipping it is invisible: a gate left open stops guarding anything, and the
next slice — possibly next session — silently skips the plan requirement
entirely.

```bash
bash .claude/scripts/gate.sh idle
```

The Stop hook nudges if you leave it open with no source in flight, and CI
fails if it is ever COMMITTED open.

Then clear `slug`, `spec_dir` and
`owner_files`. The cycle is closed.

Run `/handoff` before ending the session.
