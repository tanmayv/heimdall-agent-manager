# Design Language — Heimdall Dashboard

*The personality already implicit in `src/ui`, stated plainly so future contributors stay aligned
when the token table runs out of answers.*

## What this UI is

Heimdall is a **dense, dark, operator-grade control surface** for supervising many autonomous
agents in real time. Its natural mode is a near-black canvas (`#090909`) with low-chroma panels
floating on it as softly-outlined cards, information packed tightly, and a single electric blue
(`#0099ff`/`sky`) reserved for the one thing that matters on each screen — the primary action, the
selected item, the focus. It reads like a terminal that grew a design sense: monospace where data
is literal, Inter everywhere else, restrained color, lots of small pills and status dots carrying
live state.

## What it consistently does (keep these)

1. **Dark, layered surfaces.** Everything is built from a stack of translucent-white fills on a
   black ground (`bg-white/[0.03]` cards, `bg-black/30` inputs, `border-white/10` hairlines). This
   layering instinct is sound and should become the `canvas → surface → surface-raised` token ramp.
2. **Rounded, soft-edged cards.** Panels are generously rounded (12–20px) with a 1px hairline and
   occasional deep ambient shadow. This is the app's signature shape.
3. **Color as intent, expressed as tinted pills.** Status and actions use a consistent *grammar* —
   a `border-{tone}-400/30 bg-{tone}-400/10 text-{tone}-200` pill — for success (emerald), warning
   (amber), danger (rose/red), info (sky), neutral (white/zinc). The grammar is right; only the raw
   values drift. This becomes the `variant`/`tone` prop.
4. **Live, ambient motion.** Soft pulses, breathing halos, bubble pops, staggered "thinking" dots —
   subtle, low-contrast, and (for the agent bubbles) already `prefers-reduced-motion`-aware. Motion
   signals presence, never demands attention. Keep the restraint.
5. **Icons, never emoji.** A hand-rolled monochrome `<Icon>` set on a 24×24 grid, referenced by
   stable name. This is a real, enforced convention (AGENTS.md) and should stay.
6. **Uppercase micro-eyebrows.** Small tracked uppercase labels (`text-[11px] tracking-[0.18em]`)
   introduce sections. A genuine stylistic signature — formalize as `text-overline`.

## What it should stop doing

1. **Deciding style at the call site.** 469 hand-rolled `<button>`s, 12 arbitrary font sizes, 8
   corner radii, ~15 near-black greys, four "accent blues", and success expressed three ways. Every
   screen re-invents the same atoms with 2px-different padding, so **no two pages feel the same** —
   the single biggest problem, and the whole reason for this audit.
2. **Running three color systems at once.** A dead `odin.*` Tailwind theme, the intended `--fd-*`
   CSS-var system (used by exactly one legacy file), and the de-facto raw `zinc/sky/emerald` Tailwind
   utilities everyone actually types. Pick one — the token set — and delete the other two.
3. **Neglecting keyboard focus.** `focus-visible` appears once in the whole app; inputs strip their
   outline with `outline-none` and add nothing back. On a black UI this leaves keyboard users blind.
   This is the highest-severity class of defect and outranks every visual inconsistency.
4. **Shrinking text below legibility.** ~100 uses of 8–10px text for real content (counts, badges,
   status). Dense is fine; illegible is not. 11px is the floor.
5. **Rebuilding shells per page.** Every page hand-assembles its own header (four different header
   dialects counted), its own max-width (`3xl`/`4xl`/`5xl`/`1600px`/none), its own empty and loading
   states (two separate `Empty` helpers, one lone skeleton, otherwise bare "Loading…" text). A shared
   `PageShell`/`Panel`/`SectionHeader` is what will actually make pages feel like one app.
6. **Shipping modals and menus without a11y plumbing.** Overlays open without moving focus, without
   trapping it, without Escape or `aria-modal` (2 of ~14). This must be built into the component, not
   left to each caller.

## The one-sentence version

*A dark, dense, calm operator console with a strong native shape and a correct color-as-intent
grammar — undermined by having no shared components, so the same good ideas are re-typed slightly
differently on every page. Consolidate the atoms and the page shell, keep the personality.*
