# Heimdall UI Audit & Component API Proposal

An audit of every visible UI element in `src/ui` (the React/TS/Tailwind/Electron dashboard), the
design language already implicit in the code, and a consolidated component set with a migration path.

**Goal (from the brief + user):** the app's pages *feel different per page*. Find the one design
language already there, resolve its contradictions, and express it as a small, teachable component
set so pages become consistent — without a redesign or a big-bang rewrite.

## Read in this order

| # | File | What it is |
|---|---|---|
| 0 | [`00-findings-memo.md`](00-findings-memo.md) | **Start here.** Top-10 problems, severity-ordered (a11y + broken states first), each with impact and fix. |
| 1 | [`01-inventory.csv`](01-inventory.csv) | Machine-readable inventory — 87 element clusters (`EL-001…EL-087`) with locations, hardcoded values, states, a11y, verdict. |
| 2 | [`02-tokens.md`](02-tokens.md) | The token set (color/type/space/radius/shadow/z/motion/breakpoints/icons), each with the raw values it replaces + counts + exceptions. |
| 3 | [`03-design-language.md`](03-design-language.md) | The design-language statement: what the UI is, what to keep, what to stop. |
| 4 | [`04-component-catalogue.md`](04-component-catalogue.md) | The proposed 31-component set, full specs per layer + rejected-promotion list. |
| 5 | [`05-shared-vocabulary.md`](05-shared-vocabulary.md) | The shared prop vocabulary — one name, one meaning, across the whole set. |
| 6 | [`06-mapping.csv`](06-mapping.csv) | Every `EL-id` → destination component + example replacement call + automation class. |
| 7 | [`07-migration.md`](07-migration.md) | Per-page divergence matrix, sequencing, automation split, coexistence, guardrails, rollback. |
| 8 | [`08-page-component-guide.md`](08-page-component-guide.md) | The day-to-day reference: for each page, which component to use for each intent slot (button/form/card/list/selector/chip/icon-button) so pages match. |

## The numbers that make the argument

- **3 competing color systems**: a dead `odin.*` Tailwind theme (0 uses), the intended `--fd-*`
  CSS-vars (1 file), and the de-facto raw Tailwind palette (`zinc ×1650, white ×1559, sky ×672,
  emerald ×201, amber ×183, red ×275`). Plus **46 unique hex literals** and **4 "accent blues"**.
- **12 arbitrary font sizes** (`text-[11px]` alone ×318; ~100 uses of illegible 8–10px text).
- **8 heavily-used corner radii**; **~12 shadows**; **~8 ad-hoc z-indexes**; **~10 motion durations**.
- **469 hand-rolled `<button>`, 113 `<input>`, 95 `<select>`, 33 `<textarea>`** — no shared primitives.
- **focus-visible used exactly once** in the whole app; **9 overlay families, 1 with `aria-modal`, 0
  with a focus trap**; **no `<table>` semantics anywhere**.
- **6 page-header dialects** and **10+ page content-widths** — the concrete cause of "feels different
  per page".

## Scope & honesty

- **In scope:** `src/ui` only (dashboard). Electron main/preload and the marketing `index.html` are out.
- **This is not a redesign.** Values are consolidated to what already exists.
- **What it does not solve:** visual restyle; the native-`<select>`-vs-custom-`Listbox` trade-off
  (flagged for a team decision); third-party surfaces (Vimee/Shiki editor, Mermaid, the Markdown
  HTML-string renderer); runtime/data/routing.

*Audit only — no application code was changed. Deliverables are these documents.*
