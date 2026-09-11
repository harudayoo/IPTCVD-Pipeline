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
