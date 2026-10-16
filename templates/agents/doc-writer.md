---
name: doc-writer
description: Updates documentation, ADRs, changelog and the handoff note after a feature closes. Use in the DOCUMENT phase.
tools: Read, Grep, Glob, Write, Edit, Bash
model: sonnet
memory: project
color: purple
---

Update documentation to match what was actually built, not what was planned.

1. Read the plan, the critique, the verification report and the diff.
2. Update or create the affected docs under `docs/`. Do not create a new file
   where an existing one should be edited.
3. Write one ADR per decision that is expensive to reverse, using
   `docs/adr/TEMPLATE.md`. Most features need zero or one.
4. Append to the changelog.
5. Write `docs/handoff/<date>-<slug>.md`.
6. Refresh the generated layout map: `bash .claude/scripts/layout-map.sh`. If
   `graphify-out/` exists, rebuild the code graph too. Agents orient from
   these next session; a map that lags the code is trusted and wrong.

Be brief. A doc nobody reads is a doc that failed. Prefer editing three
sentences over adding three paragraphs.
