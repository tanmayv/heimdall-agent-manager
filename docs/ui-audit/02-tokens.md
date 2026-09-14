# Design Tokens — Heimdall Dashboard (`src/ui`)

Derived from what the code **actually does**: every literal value was collected, sorted by
frequency, and the common values became the scale. Outliers are snapped to the nearest token;
genuine exceptions are listed at the bottom of each section. Names are **semantic (role-based)**,
never appearance-based — `--fd-accent-blue` and `blue-500` are exactly the leak this replaces.

The dark, near-black `--fd-*` system already in `src/ui/styles.css` is the correct foundation;
these tokens formalise it and absorb the three competing vocabularies (dead `odin.*` theme,
`--fd-*` vars, and the de-facto raw Tailwind `zinc/sky/emerald/...` utilities) into one set.

> Replacement counts are approximate occurrence counts from `src/ui/**/*.{tsx,ts,css}`.

---

## 1. Color

Single dark theme (`color-scheme: dark`). Public names state **role**, not hue.

| Token | Value | Replaces (raw values seen) | ≈ Occurrences absorbed |
|---|---|---|---|
| `color-canvas` | `#090909` | `#090909`, `#0a0a0a`, `#0c0c0c`, `#0d0d0d`, `--fd-canvas`, `theme(black)` app-bg uses | ~40 |
| `color-surface` | `#141414` | `#141414`, `#121212`, `#111111`, `#101010`, `--fd-surface-1`, `zinc-900` panels | ~70 |
| `color-surface-raised` | `#1c1c1c` | `#1c1c1c`, `#181818`, `#161618`, `--fd-surface-2`, **`--fd-surface-3`(undefined)**, `zinc-800` | ~40 |
| `color-surface-overlay` | `#0d0f14` | `#0d0f14`, `#0b0d11`, `#0b0d12`, `#0f1115`, modal/backdrop panels | ~20 |
| `color-border-subtle` | `#262626` | `#262626`, `#2a2a2a`, `--fd-hairline`, `zinc-800/700` borders, `white/10` hairlines | ~120 |
| `color-border-strong` | `#3a3a3a` | `zinc-700/600` emphasized borders, `#525252` | ~30 |
| `color-text-primary` | `#ffffff` | `#ffffff`, `--fd-ink`, `white`, `zinc-100/200` | ~1500 |
| `color-text-muted` | `#999999` | `#999`, `#999999`, `#aaa`, `--fd-ink-muted`, `zinc-400/500` | ~600 |
| `color-text-faint` | `#6b6b6b` | `#666`, `#777`, `#52525b`, `zinc-600`, sub-11px caption greys | ~120 |
| `color-accent` | `#0099ff` *(decision — see note)* | `--fd-accent-blue #0099ff`, `sky-400/500` (×672), `ring-blue-500`, `odin.accent #60a5fa` | ~700 |
| `color-accent-fg` | `#000000` | `--fd-on-primary`, `text-black` on accent | ~40 |
| `color-success` | `#22c55e` | `#22c55e`, `#34d399`, `--fd-success`, `emerald-400/500` (×201), `green` | ~210 |
| `color-warning` | `#f59e0b` | `amber-400/500` (×183), `yellow`, `#d4d4d8` warn text | ~185 |
| `color-danger` | `#ef4444` | `red-400/500` (×275), `rose-*` (×75) | ~350 |
| `color-info` | = `color-accent` | `sky-*` info chips | (shared) |
| `color-focus-ring` | `color-mix(accent, transparent 65%)` | `ring-blue-500`, `ring-sky-400/*`, `ring-[var(--fd-accent-blue)]`, ad-hoc rings | ~20 |

**Collisions that must split (one raw value, two roles):**
- `white` is both `text-primary` (opaque) **and** every translucent hairline/fill (`white/8`,
  `/10`, `/14`, `/16`). Split: opaque → `text-primary`; translucent → `border-subtle` /
  `surface-raised`. Do **not** merge.
- `#101010` serves both a *sunken well* and a *panel*; it splits into `surface` vs a ring color
  (`ring-[#101010]`). Keep the well on `surface`, drop the ring literal.

**Accent decision (needs sign-off):** four blues currently mean "accent". `sky-*` is used far more
(×672) than `--fd-accent-blue #0099ff`, but the CSS system declares `#0099ff` as canonical. Pick
**one**. Recommendation: keep `#0099ff` as `color-accent` (it is the declared brand blue and the
focus/selection color) and migrate `sky-*` call sites to it. Flagged for the user.

**Exception list (stay hardcoded):** syntax-highlight / editor colors (`--sv-*`, Shiki theme),
`mermaid` diagram palette, and the scrollbar gradient (`#737373→#4a4a4a`) — these are third-party
surfaces, not product UI.

---

## 2. Typography

Family: `--fd-font-body` = Inter → system-ui stack (already defined). Mono:
`ui-monospace, SFMono-Regular, Menlo, …`. Roles bind size + weight + line-height + tracking.

| Role | Size | Weight | Line-height | Tracking | Replaces | ≈ Occ |
|---|---|---|---|---|---|---|
| `text-display` | 22px | 700 | 1.2 | -0.8px | `framer-headline`, `text-2xl/3xl` | ~40 |
| `text-heading` | 18px | 700 | 1.25 | -0.02em | `text-xl`, page titles | ~30 |
| `text-title` | 15px | 600 | 1.3 | -0.01em | `text-[15px]`, `text-base` bold | ~30 |
| `text-body` | 14px | 400/500 | 1.5 | normal | `text-sm` (×570) | ~570 |
| `text-body-sm` | 13px | 400/500 | 1.45 | -0.13px | `text-[13px]`, `text-[13.5px]`, `framer-micro` | ~40 |
| `text-label` | 12px | 500 | 1.35 | normal | `text-xs` (×443), `text-[12px]`, `text-[12.5px]` | ~500 |
| `text-caption` | 11px | 500 | 1.3 | normal | `text-[11px]` (×318), `text-[11.5px]` | ~370 |
| `text-overline` | 11px | 600 | 1 | 0.14–0.22em UPPER | `tracking-[0.14em]`+uppercase clusters | ~50 |
| `text-code` | 13px | 400 | 1.6 | normal (mono) | `--sv-font-size`, code blocks | ~20 |

**Snap / discourage:** `text-[10.5px]`, `text-[9.5px]`, `text-[9px]`(×16), `text-[8px]`(×3),
`text-[10px]`(×84) → snap up to `text-caption` (11px). Sub-11px body text is a readability defect;
the only sanctioned <11px use is a dense numeric/overline, and even those should justify it.

---

## 3. Spacing

Base unit **4px**. Near-geometric; half-steps kept only where heavily used.

| Token | px | Tailwind | ≈ Occ (px/py/p/gap) |
|---|---|---|---|
| `space-0.5` | 2 | `-0.5` | ~150 (keep; flag `py-0.5` overuse) |
| `space-1` | 4 | `-1` | ~250 |
| `space-1.5` | 6 | `-1.5` | ~200 |
| `space-2` | 8 | `-2` | ~800 (workhorse) |
| `space-2.5` | 10 | `-2.5` | ~110 |
| `space-3` | 12 | `-3` | ~600 |
| `space-4` | 16 | `-4` | ~250 |
| `space-5` | 20 | `-5` | ~65 |
| `space-6` | 24 | `-6` | ~40 |
| `space-8` | 32 | `-8` | ~30 |

**Snap:** `px-3.5`(14), `p-3.5`, `px-0.5` → nearest step. Custom `spacing.84 = 21rem` (tailwind
config) is a one-off fixed sidebar width → move to `size-sidebar` container token, not spacing.

---

## 4. Radius

Two radius systems today (Tailwind `rounded-*` **and** `--fd-radius-*`). Collapse to four roles.

| Token | Value | Replaces | ≈ Occ |
|---|---|---|---|
| `radius-sm` | 6px | `rounded`(4)×207, `rounded-md`(6)×55, `--fd-radius-xs/sm` | ~270 |
| `radius-md` | 10px | `rounded-lg`(8)×192, `--fd-radius-md`(10) | ~200 |
| `radius-lg` | 16px | `rounded-xl`(12)×418, `rounded-2xl`(16)×171, `rounded-3xl`(24)×10, `--fd-radius-lg/xl/xxl` | ~600 |
| `radius-pill` | 9999px | `rounded-full`×207, `--fd-radius-pill` | ~207 |

Roles: **control** (button/input/chip) = `radius-md`; **card/panel/modal** = `radius-lg`;
**pill/avatar/badge** = `radius-pill`; **inline code / tiny** = `radius-sm`.

---

## 5. Borders

| Token | Value | Replaces |
|---|---|---|
| `border-width` | 1px | nearly all `border` |
| `border-width-strong` | 2px | scrollbar/selected `border-2`, `ring-2` |
| (colors) | see §1 | `border-subtle` / `border-strong` |

---

## 6. Shadow / Elevation

| Token | Value (spec) | Replaces | ≈ Occ |
|---|---|---|---|
| `shadow-sm` | `0 1px 2px rgba(0,0,0,.4)` | `shadow-sm`, `shadow` | ~12 |
| `shadow-panel` | `0 8px 24px rgba(0,0,0,.5)` | `shadow-lg`, `shadow-black/50-60` | ~15 |
| `shadow-overlay` | `0 24px 64px rgba(0,0,0,.7)` | `shadow-2xl`×28, `shadow-black/70` | ~35 |
| `shadow-focus` | `0 0 0 1px color-mix(accent,transparent 65%)` | ad-hoc focus box-shadows | ~5 |
| `glow-*` (accent/success/warn/danger) | `0 0 0 1px <color>/20` | `shadow-sky/amber/emerald/violet/red-400/40` | ~10 |

**Exception:** decorative colored glows on status cards may keep a `glow-*` token; raw
`shadow-[inset 0 …]` one-offs (×6) should snap to `shadow-sm`/none.

---

## 7. Z-index layers

Named scale replaces ad-hoc `z-10..z-[90]`.

| Token | Value | Replaces |
|---|---|---|
| `z-base` | 0 | — |
| `z-sticky` | 10 | `z-10` |
| `z-dropdown` | 20 | `z-20`, `z-30` |
| `z-overlay` | 40 | `z-40` |
| `z-modal` | 50 | `z-50`×16 |
| `z-toast` | 60 | `z-[60]` |
| `z-tooltip` | 80 | `z-[80]`, `z-[90]` |

---

## 8. Motion

| Token | Value | Replaces |
|---|---|---|
| `duration-fast` | 120ms | `duration-150`, `120ms`, `160ms` |
| `duration-base` | 200ms | `duration-200`, `200ms`, `220ms`, `240ms` |
| `duration-slow` | 300ms | `duration-300`, `360ms` |
| `duration-slower` | 500ms | `duration-500` |
| `ease-standard` | `cubic-bezier(0.2,0.8,0.2,1)` | existing bubble easings |
| `ease-linear` | linear | reduced-motion fallbacks |

`prefers-reduced-motion` is already respected for agent-bubble animations — extend that contract
to every token consumer. Ambient loops (`soft-pulse`, `halo-breathe`, `7s`) stay as-is.

---

## 9. Breakpoints & containers

| Token | Value | Source |
|---|---|---|
| `bp-md` | 767px | `@media (max-width:767px)` in styles.css (the one real breakpoint: drops desktop min-width, bumps input font to 16px) |
| `size-app-min-w` | 920px | `body { min-width: 920px }` desktop floor |
| `size-app-min-h` | 620px | `body { min-height: 620px }` |
| `size-sidebar` | 21rem | tailwind `spacing.84` |
| safe-area | `env(safe-area-inset-*)` | `.ui-safe-*` utilities (iOS/notch) |

---

## 10. Icon sizes

Icons are hand-rolled inline SVG via `<Icon>` on a `0 0 24 24` viewBox (lucide-react 1.21.0 is
broken in this repo — documented in `Icon.tsx`).

| Token | Value | Use |
|---|---|---|
| `icon-sm` | 14px | inline w/ `text-label`/`text-caption` |
| `icon-md` | 16px | default, w/ `text-body` |
| `icon-lg` | 20px | buttons, headers |
| `icon-xl` | 24px | empty-state / feature glyphs |

---

### Token count summary
~15 color roles, 9 type roles, 10 spacing steps, 4 radii, 2 border widths, 5 shadows + glows,
7 z-layers, 4 durations + 2 easings, 1 breakpoint, 4 container sizes, 4 icon sizes.
This replaces **46 unique hex literals, ~24 rgba literals, 12 arbitrary font-sizes, 8 radii,
~8 ad-hoc z-indexes, and ~10 motion durations** with a single legible scale.
