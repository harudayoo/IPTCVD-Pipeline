---
description: Describes this codebase's architecture, key directories, naming conventions and where things live. Loaded when orienting in unfamiliar parts of the project.
user-invocable: true
---

<!--
  GENERATED IN SETUP PHASE 6.
  Replace this body with the output of the three memory-seeding passes.
  Keep it under 120 lines: this replaces an exploration pass, so it must be
  cheaper than the exploration it replaces.
-->

# Codebase map

## Read this first, instead of exploring

1. **Layout** — [layout.md](layout.md) is GENERATED from `git ls-files` and the
   profile's roots: every directory each source root matches, the test roots,
   the shared surfaces, and the code no root guards. It knows this repo's real
   shape (a monorepo's packages, a `src/main` tree, your own layout) without
   anyone re-reading the tree. Before trusting it, run
   `bash .claude/scripts/layout-map.sh --check`; if it says stale, re-run
   `bash .claude/scripts/layout-map.sh` and read the new one.
2. **Meaning** — the sections below are written by a person or the
   memory-seeding pass: what the layers are FOR, and what bites. The layout
   tells you where; this tells you why.
3. **Relationships (optional)** — if `graphify-out/GRAPH_REPORT.md` exists, read
   it before grepping for "what calls X" or "what connects A to B", and use
   the graphify CLI's query/path/explain commands to traverse the graph instead
   of opening files speculatively. Edges tagged INFERRED or AMBIGUOUS are
   hints, not facts: open the file before citing one in a plan or a finding.
   The graph is as stale as its last rebuild — layout.md reports how far
   behind HEAD it is.

None of these replace reading the code you are about to change. They replace
reading the code you were only going to read to find it.

## Architecture
<one paragraph: the layering actually in use, not the one aspired to>

## Where things live
| Concern | Path | Notes |
|---|---|---|

## Naming conventions
<observed, not prescribed>

## Existing utilities worth reusing
<the modules people keep reinventing>

## Landmines
<the three things that surprise newcomers>
