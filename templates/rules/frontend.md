---
paths:
  - "{{FRONTEND_GLOB}}"
---

# Front-end standards

**Size.** 800 lines is the bar for a source file, and it is measured, not
suggested: `bash .claude/scripts/ratchet.sh` runs in CI. It is a ratchet, so a
tree already over the bar is recordable — a baselined file may shrink and may
never grow, and an unlisted file may not cross at all. `--list` shows every
file currently over it, largest first.

Lines are what the ratchet counts, and only lines. Function length, nesting
depth and parameter counts need a real parser per language to measure honestly,
so they stay below as stated standards that review checks by reading. Treating
the ratchet's silence as approval of a 300-line function is reading it
backwards.

Size is a proxy, and the reason it is worth measuring is that nobody refactors a
file they cannot hold in their head, so defects pool where the lines do: on the
codebase this pipeline came from, 28 of 30 react-hooks violations lived in one
1,476-line file.

**Tokens.** Colour, spacing, radius, shadow and type scale come from
`{{TOKEN_FILE}}`. A literal hex, px or rem in a component is a review blocker.

**Design tooling writes tokens, not components.** Any design skill, plugin or
generator in use produces the *system* — palette, scale, radii, easings — and
that output lands in `{{TOKEN_FILE}}`, or in `docs/specs/<slug>/design.md` as a
proposed token. It never lands as a literal in a component. A generated
component carrying raw values is the same review blocker as a hand-written one;
where the value came from is not a defence.

**Design exploration lives outside the protected source roots.** Scratch
routes, playgrounds and tool-generated drafts are not deliverables. Nothing in a
sandbox directory ships, and real source must not import from one.

**States.** Every interactive element implements default, hover, focus-visible,
active, disabled, loading and error. Every collection implements empty and
error states.

**Responsive.** Breakpoints 390 / 768 / 1024 / 1280 / 1536. Mobile is a
designed layout, not a narrowed desktop. No horizontal scroll at 320px.
Touch targets at least 44x44px. A data table that just overflows silently
below its breakpoint is a defect, not an acceptable tradeoff — it needs a
designed fallback (stacked cards, a reduced column set, or horizontal scroll
with a visible affordance).

**Accessibility.** WCAG 2.2 AA. Semantic HTML before ARIA. Visible focus
everywhere. Contrast 4.5:1 for body text, 3:1 for large text and UI
boundaries. All motion respects `prefers-reduced-motion`.

**Performance.** LCP <= 2.5s, INP <= 200ms, CLS <= 0.1 on a mid-tier mobile
profile. Images get explicit dimensions, modern formats, lazy below the fold.

**SEO.** One h1 per page with correct heading order. Title and meta
description per route. Canonical URL. Open Graph tags. JSON-LD where the page
type warrants it. Navigation crawlable without JavaScript.
