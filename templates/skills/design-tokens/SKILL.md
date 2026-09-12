---
description: The design token contract — the single source of colour, spacing, radius, shadow and type scale for this project. Loaded by ui-designer and frontend-engineer before any visual work.
user-invocable: true
---

# Design tokens

Every visual value in this project derives from `{{TOKEN_FILE}}`. A literal hex,
px or rem in a component is a review blocker, not a preference.

This is what separates a designed system from generated output: the whole
surface re-themes from one change, and a rebrand is one number.

## The contract

- **Colour** — from the token layer only. Derive the palette from a single hue
  variable so changing it re-themes everything.
- **Spacing** — from a single unit on a consistent grid. No arbitrary margins.
- **Radius** — a small named set (sm / md / lg). No one-off values.
- **Type** — a display family and a body family, with a defined scale. Pair them
  deliberately; the default sans-on-sans is the look this skill exists to avoid.
- **Shadow and elevation** — a named set tied to a z-order model, not
  per-component values.
- **Motion** — named durations and easings. Everything respects
  `prefers-reduced-motion`.

## Why OKLCH is worth the migration

If you are choosing a colour space now, choose OKLCH. It gives perceptually
uniform lightness across hues — two colours at the same lightness actually look
equally light, which HSL does not deliver — and access to the P3 wide gamut.

Brand-tinted neutrals rather than pure grey are one of the clearest visual
signals of a deliberately designed system. Deriving them from the brand hue
costs nothing:

```css
/* the shape, not a prescription — adapt to your framework */
@theme {
  --brand-hue: 250;

  --color-primary:    oklch(0.60 0.20 var(--brand-hue));
  --color-background: oklch(0.995 0.005 var(--brand-hue));
  --color-foreground: oklch(0.15 0.02 var(--brand-hue));
  --color-muted:      oklch(0.94 0.01 var(--brand-hue));
  --color-border:     oklch(0.88 0.015 var(--brand-hue));

  --spacing-unit: 0.25rem;
  --radius-sm: 0.25rem;  --radius-md: 0.5rem;  --radius-lg: 1rem;
}
```

One `--brand-hue` change re-themes the product.

## Adding a token

A feature that needs a value the token layer does not have gets a **new token**,
never a literal. Propose it in `docs/specs/<slug>/design.md`, name it by role
(`--color-danger-subtle`) not by appearance (`--color-light-red`), and add it to
`{{TOKEN_FILE}}` before the component that uses it.

## Working with a third-party design skill

If this project has installed a design-taste skill — `frontend-design`,
Impeccable, UI-UX Pro Max, `taste-skill` — it reconciles with this file in
exactly one direction:

> **The design skill writes the token layer. Components consume tokens.**

When it proposes a palette, a type scale or a set of radii, that output goes
into `{{TOKEN_FILE}}` or into `docs/specs/<slug>/design.md` as a proposed token.
It does not go into a component as a literal. Done this way the two reinforce
each other — the OKLCH-and-one-hue model above is what most of them prescribe
anyway. Done the other way, `code-reviewer` flags the diff, correctly.

The aesthetic direction in `CLAUDE.md` outranks any skill's preference. If a
skill wants a typeface or palette the direction rules out, the direction wins;
change `CLAUDE.md` deliberately or not at all.

Design exploration that writes real component files belongs in the CREATE phase,
where the gate is already open, or in a scratch directory outside the protected
source roots. Never widen the gate to make a design tool comfortable.

See [the design-stack playbook](https://github.com/harudayoo/IPTCVD-Pipeline/blob/main/docs/DESIGN-STACK.md) for the adoption procedure.

## Checking conformance

Grep the diff for raw values before closing CREATE:

```
#[0-9a-fA-F]{3,8}\b        raw hex
[0-9]+px                    raw pixel value
rgba?\(                     raw colour function
```

Matches inside `{{TOKEN_FILE}}` itself are the point. Matches anywhere else are
findings.
