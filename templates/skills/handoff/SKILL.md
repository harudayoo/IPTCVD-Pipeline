---
description: Writes an end-of-session handoff note capturing state, decisions, rejected approaches and next actions. Use before ending a session with uncommitted work.
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *) Bash(bash .claude/scripts/gate.sh *)
---

- Branch: !`git branch --show-current 2>/dev/null`
- Uncommitted: !`git status --short 2>/dev/null`
- Recent: !`git log --oneline -10 2>/dev/null`
- Gate: !`cat .claude/state/gate.json 2>/dev/null`

Write `docs/handoff/<today>-<slug>.md`:

1. **State** — phase, what is done, what is in progress.
2. **Decisions this session** — each with its reason. Link any ADR.
3. **Rejected approaches** — and why. Highest-value section; without it the
   next session re-litigates settled questions.
4. **Open questions** — with who or what should answer each.
5. **Next actions** — ordered, each with the file path it touches.
6. **Landmines** — anything surprising found in the codebase.

Under 300 words per section. Then append durable lessons to the relevant
agent memories under `.claude/agent-memory/`, and update
`docs/handoff/INDEX.md`.

Finally, **close the gate**:

```bash
bash .claude/scripts/gate.sh idle
```

This is the step the skill is named for and the one most easily skipped, so it
is last and explicit rather than assumed. A gate left at `create` or `verify`
does not keep guarding the slice it was opened for — it stops guarding
**anything**, and the next change, possibly next session and possibly by
someone else, reaches source without ever stating a problem or a red test. The
Stop hook nudges about this, but a nudge is not a reset.

Reset it even when work is unfinished. The gate records that a plan was
approved for *this* slice; carrying it into the next one is not continuity, it
is a stale authorisation. Reopening costs one command and restates the plan
that the next session needs written down anyway.
