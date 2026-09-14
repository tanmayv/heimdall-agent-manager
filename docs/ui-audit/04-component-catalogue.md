# Component Catalogue

Proposed component set for `src/ui`, grouped by layer. Bias: **few components, well-chosen
variants**. Every prop earns its place with an existing call site (`01-inventory.csv`). Prop names
follow `05-shared-vocabulary.md`. No spec contains a hardcoded visual value — everything resolves to
a token in `02-tokens.md`. Accessibility (focus, roles, keyboard) is built in, never a prop.

**Count:** 18 primitives · 13 composites · 5 named patterns · 6 declared one-offs = **31 components**,
replacing ~87 inventoried element clusters and thousands of call sites.

Recommended implementation: Tailwind + `class-variance-authority`-style variant maps bound to the
tokens, or `data-variant`/`data-size` attributes styled from the token layer. Stack-agnostic — the
API below is what matters.

---

# Layer 1 — Primitives

## Button

Purpose        The one clickable action with a text label. NOT for navigation-only (use `Link`), NOT icon-only (use `IconButton`).
Layer          Primitive
Replaces       EL-001, EL-002, EL-003, EL-004, EL-005, EL-006, EL-007, EL-008, EL-009, EL-010, EL-011, EL-012, EL-013, EL-016, EL-017, EL-018, EL-080 (600+ occurrences)

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `variant` | `'primary' \| 'secondary' \| 'ghost' \| 'danger'` | `'secondary'` | no | Intent + weight. `success`/`warning` are **not** button variants — they belong to status surfaces, not actions; the rare "confirm" success button uses `variant="primary"`. |
| `size` | `'sm' \| 'md' \| 'lg'` | `'md'` | no | Maps to spacing + type tokens. |
| `loading` | boolean | `false` | no | Shows spinner, keeps width, sets `aria-busy`, disables. |
| `disabled` | boolean | `false` | no | |
| `width` | `'content' \| 'full'` | `'content'` | no | `full` = block button. |
| `leading` / `trailing` | node | — | no | Icon or badge slot. |
| `onClick` | `(e)=>void` | — | no | |
| `type` | `'button'\|'submit'\|'reset'` | `'button'` | no | |

### Composition
Children = the label (text, optionally with `leading`/`trailing` icons). No structural children.

### States
default/hover/active/disabled styled from tokens automatically. **focus-visible** = built-in
`shadow-focus` ring (fixes finding #1). `loading` via prop. No `selected` (that's `Toggle`/`Tab`).

### Accessibility contract
Renders `<button>`. Full keyboard (Enter/Space) native. `disabled`/`loading` set proper attrs.
Guarantees a visible focus ring. Caller supplies the label text (or `aria-label` if `leading` icon
is the only content — but then prefer `IconButton`).

### Tokens consumed
`color-accent`/`accent-fg`, `color-surface-raised`, `color-border-subtle`, `color-danger`,
`color-text-primary/muted`, `radius-md`, `space-*` (per size), `text-label/body`, `shadow-focus`, `duration-fast`.

### Escape hatches
`className` on root only. Beyond four variants → you want a different component, not a fifth variant.

### Usage
```tsx
<Button variant="primary" onClick={save}>Save</Button>
<Button variant="danger" leading={<Icon name="trash"/>} loading={deleting}>Delete</Button>
// MISUSE: <Button variant="ghost" aria-label="Close"><Icon name="close"/></Button>
//   → icon-only: use <IconButton icon="close" label="Close" />
```

---

## IconButton

Purpose        A single-icon action (close, edit, overflow, refresh). NOT for text actions (use `Button`).
Layer          Primitive
Replaces       EL-014, EL-015, EL-018 (icon sends) (30+ occurrences)

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `icon` | `IconName` | — | **yes** | From the `Icon` set. Never emoji/glyph. |
| `label` | string | — | **yes** | Accessible name (visually hidden). Fixes the many unlabeled icon buttons. |
| `variant` | `'ghost' \| 'solid' \| 'danger'` | `'ghost'` | no | |
| `size` | `'sm' \| 'md' \| 'lg'` | `'md'` | no | Enforces ≥44px hit target at `md`. |
| `disabled` / `loading` | boolean | `false` | no | |
| `onClick` | `(e)=>void` | — | no | |

### States
Same as Button; hit-area guaranteed ≥44px (fixes tiny-target defect). focus-visible built in.

### Accessibility contract
Renders `<button>` with the visually-hidden `label` as accessible name + `title`. `label` is
**required** — the component cannot be built without one.

### Tokens consumed
`icon-*`, `color-text-muted/primary`, `color-surface-raised`, `radius-md`, `shadow-focus`, `space-*`.

### Usage
```tsx
<IconButton icon="close" label="Close dialog" onClick={close} />
<IconButton icon="trash" label="Delete action" variant="danger" />
```

---

## Input · Textarea

Purpose        Single-line / multi-line free text entry. NOT for choosing from options (use `Select`/`Combobox`).
Layer          Primitive
Replaces       EL-020, EL-021, EL-022, EL-023(delete), EL-024, EL-032, EL-033 (140+ occurrences)

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `value` | string | — | **yes** | Controlled. |
| `onChange` | `(value)=>void` | — | **yes** | |
| `size` | `'sm' \| 'md' \| 'lg'` | `'md'` | no | |
| `invalid` | boolean | `false` | no | Error styling + `aria-invalid`. Usually set by `FormField`. |
| `disabled` / `readOnly` | boolean | `false` | no | |
| `leading` / `trailing` | node | — | no | Icon/adornment (search, clear). |
| `type` | text/password/email/number/date/time… | `'text'` | no | Textarea adds `rows`, `autoResize`. |
| `placeholder` | string | — | no | Never a substitute for a label. |

### States
default/focus/**focus-visible** (real ring, replaces bare `outline-none`)/disabled/readOnly/invalid,
all token-driven. No theme-aware light variant (deletes the gray outlier EL-023).

### Accessibility contract
Renders `<input>`/`<textarea>`. Requires an associated label — supplied by `FormField` (`htmlFor`)
or an explicit `aria-label`. Never ships bare `outline-none`; focus ring is guaranteed.

### Tokens consumed
`color-surface`(`bg-black/30`→token), `color-border-subtle`, `color-accent`(focus), `radius-md`,
`text-body`, `space-*`, `shadow-focus`, `color-danger`(invalid).

### Escape hatches
`className` on root. A rich editor (Vimee) is out of scope — not this component.

### Usage
```tsx
<FormField label="Title" error={errors.title}>
  <Input value={title} onChange={setTitle} />
</FormField>
```

---

## Select · Combobox

Purpose        Choose one (or many) from a known option set. `Select` = short lists (native), `Combobox` = searchable/long lists.
Layer          Primitive
Replaces       EL-025 (Select), EL-026, EL-027, EL-031 (Combobox/multi) (60+ occurrences)

### API (shared)
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `value` | `string \| string[]` | — | **yes** | Controlled; array when `multiple`. |
| `onChange` | `(value)=>void` | — | **yes** | |
| `options` | `{value,label,leading?,disabled?}[]` | — | **yes** | |
| `multiple` | boolean | `false` | no | Combobox only; renders removable chips. |
| `size` | `'sm'\|'md'\|'lg'` | `'md'` | no | |
| `invalid` / `disabled` / `loading` | boolean | `false` | no | |
| `placeholder` | string | — | no | |

### Composition
Options via the `options` prop (data), not children — keeps the listbox semantics correct.

### States
open/selected/active-option/disabled/loading/empty. **Keyboard**: type-ahead, ↑/↓ move active
option, Enter selects, Esc closes, chip Backspace removes (multi). focus-visible on trigger + ring.

### Accessibility contract
`Select` renders a styled native `<select>` (keeps native a11y + mobile pickers) OR the `Combobox`
renders trigger `role="combobox" aria-expanded aria-controls`, popup `role="listbox"`, options
`role="option" aria-selected`, and wires **`aria-activedescendant`** (the gap in today's
`SearchableSelect`). Multi adds `aria-multiselectable`; chip remove buttons carry `aria-label`.

### Tokens consumed
Same surface/border/accent/radius/text/shadow tokens as `Input`; `z-dropdown` for the popup.

### Usage
```tsx
<Select value={tier} onChange={setTier} options={TIERS} />
<Combobox multiple value={agents} onChange={setAgents} options={agentOpts} placeholder="Add agents…" />
```

> **Open decision (flagged):** whether `Select` stays native-styled or becomes a full custom
> `Listbox`. Native wins on built-in a11y + mobile; custom wins on visual control. Recommend native
> for short lists, `Combobox` for the rest. Team to confirm.

---

## Checkbox · Radio · Toggle

Purpose        Boolean / one-of / on-off controls. `Toggle` = an immediate on/off setting; `Checkbox` = form selection.
Layer          Primitive
Replaces       EL-028, EL-029, EL-030 (Toggle), EL-019 (toggle buttons) (many)

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `checked` | boolean | — | **yes** | Controlled. |
| `onChange` | `(checked)=>void` | — | **yes** | |
| `label` | node | — | **yes** (Toggle/standalone) | Radio/Checkbox may be labelled by `FormField`. |
| `disabled` | boolean | `false` | no | |
| `name`/`value` | string | — | Radio yes | Radio grouping. |

### Accessibility contract
Checkbox/Radio render native inputs (never `focus:ring-0`). Toggle renders
`<button role="switch" aria-checked>` (the `NotificationsPanel` model, promoted). All keep a visible
focus ring. Labels associated via `htmlFor`/wrapping.

### Tokens consumed
`color-accent`, `color-border-subtle`, `color-surface`, `radius-sm/pill`, `shadow-focus`.

### Usage
```tsx
<Toggle checked={notify} onChange={setNotify} label="Desktop notifications" />
<Checkbox checked={sel} onChange={setSel} label="Coordinator" />
```

---

## Text

Purpose        All non-heading and heading typography via a role prop. NOT layout.
Layer          Primitive
Replaces       every raw `text-sm/xs/[11px]…` + heading class (2000+ occurrences)

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `as` | element | inferred | no | `h1`…`h6`,`p`,`span`,`label`. |
| `role` | `'display'\|'heading'\|'title'\|'body'\|'body-sm'\|'label'\|'caption'\|'overline'\|'code'` | `'body'` | no | Binds size+weight+line-height+tracking (`02-tokens.md §2`). |
| `tone` | `'primary'\|'muted'\|'faint'\|'accent'\|'danger'\|'success'\|'warning'` | `'primary'` | no | Semantic color only. |
| `truncate` | boolean | `false` | no | |

### Accessibility contract
Caller picks the semantic element via `as` (so `h1` hierarchy is correct — fixes the TaskChainOverview
`h2`-as-title defect). Enforces the 11px floor: sub-11px roles don't exist.

### Usage
```tsx
<Text as="h1" role="display">Projects</Text>
<Text role="caption" tone="muted">3 running</Text>
```

---

## Icon

Purpose        A named monochrome glyph. The ONLY sanctioned icon mechanism — no emoji, no text glyphs.
Layer          Primitive (already exists — keep & extend)
Replaces       EL (Icon usage), the emoji/glyph strategies in OnboardingWizard/ArtifactViewer/LibraryPage

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `name` | `IconName` | — | **yes** | Stable name; add missing glyphs (🔍→`search`, ✎→`pencil`, 🗑→`trash`, 🎉→`sparkle`, ←→`arrow-left`, ×→`close`, ⌘→`command`) to the set. |
| `size` | `'sm'\|'md'\|'lg'\|'xl'` | `'md'` | no | 14/16/20/24. |
| `title` | string | — | no | When set, `role="img"`+`<title>`; else `aria-hidden`. |

### Accessibility contract
`aria-hidden` by default (decorative), labelled only via `title`. Already correct in `Icon.tsx`.
**Guardrail:** lint-ban emoji and raw glyphs in JSX text (finding #… ; AGENTS.md rule).

---

## Badge · StatusPill · StatusDot

Purpose        Compact status/metadata. `Badge`=neutral metadata/count; `StatusPill`=semantic state w/ label; `StatusDot`=liveness indicator.
Layer          Primitive
Replaces       EL-047, EL-049, EL-054 (Badge); EL-048, EL-051, EL-087 (StatusPill); EL-050 (StatusDot) (many)

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `tone` | `'neutral'\|'info'\|'success'\|'warning'\|'danger'\|'pending'` | `'neutral'` | no | Collapses the ~10 dot colors + 5 opacity scales into one tone set. |
| `emphasis` | `'solid'\|'soft'\|'outline'` | `'soft'` | no | Replaces `/10`,`/15`,`/20`,`/900/50` forks. |
| `children` | node | — | Badge/Pill | Label/count. |
| `pulse` | boolean | `false` | StatusDot | Live/working animation (reduced-motion aware). |

### Accessibility contract
StatusDot is **not** color-only: it renders a visually-hidden text state (`aria-label`/adjacent
`<Text>`) so colorblind/SR users get the state (fixes finding on status color). Decorative Badge is
inert.

### Tokens consumed
`color-{success,warning,danger,accent,text-muted}`, `radius-pill`, `text-caption/overline`, `space-*`.

### Usage
```tsx
<StatusPill tone="success">Running</StatusPill>
<StatusDot tone="success" pulse aria-label="Agent online" />
<Badge>{count}</Badge>
```

---

## Link · Spinner · Kbd · Avatar (compact primitives)

- **Link** (EL-016 nav links): renders `<a>`; `variant='inline'|'standalone'`; visible focus ring;
  underline on hover/focus. Use for navigation; `Button` for actions.
- **Spinner** (EL-068): `size`; `role="status"` + `aria-label`. The one loading glyph.
- **Kbd** (EL-053): renders `<kbd>`; shortcut display. Already fine — formalize.
- **Avatar** (EL-052): `size`, `name`(initials), `src?`, `shape='circle'|'rounded'`. Collapses the
  two avatar shapes into one with a prop.

---

# Layer 2 — Composites

## PageShell

Purpose        The single page frame every route renders into: constrained width, standard header, body, and loading/empty/error handling. This is the component that makes pages feel like one app.
Layer          Composite
Replaces       EL-035, EL-036, EL-037, EL-038, EL-039, EL-040 (6 header dialects) + the 10+ page max-width variants

### API
| Prop | Type | Default | Required | Notes |
|------|------|---------|----------|-------|
| `title` | node | — | **yes** | Rendered as the page `<h1>`. One heading dialect for all pages. |
| `eyebrow` | string | — | no | Uppercase overline. |
| `description` | node | — | no | Subtitle. |
| `actions` | node | — | no | Toolbar slot (right of title). |
| `width` | `'content'\|'wide'\|'full'` | `'content'` | no | One content-width token ramp; kills `max-w-3xl/4xl/5xl/1600px/none` sprawl. |
| `loading` / `error` | boolean/node | — | no | Renders standard `Spinner`/`Alert` in the body. |

### Composition
`children` = the page body. Header is built from props (title/eyebrow/description/actions) — **not**
freeform — so every page's header is structurally identical.

### Accessibility contract
Renders `<main>` with the title as the one `<h1>` (fixes heading-hierarchy defects). Skip-link target.

### Tokens consumed
`size-content-*` widths, `space-*`, `text-display/overline/body`, `color-*`.

### Usage
```tsx
<PageShell eyebrow="Automation" title="Actions" description="Scheduled routines"
           actions={<Button variant="primary" leading={<Icon name="plus"/>}>New action</Button>}>
  {rows}
</PageShell>
```

---

## SectionHeader · Panel · Card

- **SectionHeader** (EL-041, EL-042): `title`, `description?`, `actions?`, `collapsible?`(→`aria-expanded`).
  One section-title dialect (replaces the uppercase-eyebrow + h2/h3 mix).
- **Panel** (EL-043, EL-046): the standard content container — `title?`, `padding`, `tone='raised'|'sunken'`.
  Fixes `BridgesPanel`-wraps-itself and the surface-opacity drift; one card radius (`radius-lg`).
- **Card** (EL-043/044 interactive rows): interactive variant renders `<button>`/`<a>` (never `div
  onClick`), `selected` via `aria-pressed`/`aria-current`. Fixes `AgentListItem` keyboard defect.

## FormField

Purpose        Label + control + hint + error, correctly wired. Every form control lives in one.
Layer          Composite
Replaces       the ad-hoc label/hint/error patterns (EL-073 inline errors, unassociated labels)

### API
`label`(required) · `hint?` · `error?`(implies `invalid`) · `required?` · `children`(the control).
Generates the `id`, sets `htmlFor`, `aria-describedby`(hint), `aria-invalid`+`aria-describedby`(error)
on the child. Fixes the pervasive sibling-label/no-`htmlFor` gap.

## Modal · Drawer

Purpose        Focus-managed overlay dialogs. Modal = centered; Drawer = edge sheet.
Layer          Composite
Replaces       EL-055, EL-058, EL-059 (wizard shell), and standardizes EL-060 (9 overlay families)

### API
`open`(req) · `onOpenChange`(req) · `title`(req, → `aria-labelledby`) · `size` · `children`
(compose `Modal.Body`/`Modal.Footer`; **no** `headerText`/`showCloseButton`/`footerButtonLabel`).

### Accessibility contract (the whole point)
Portal; `role="dialog"` + `aria-modal`; **focus trap**; focus-on-open to first control; **Esc closes**;
focus **restored** to the trigger on close; background scroll locked; backdrop click closes. This is
built in once and fixes findings #2 across all overlays.

### Tokens consumed
`z-modal`, `color-surface-overlay`, `radius-lg`, `shadow-overlay`, `space-*`.

### Usage
```tsx
<Modal open={open} onOpenChange={setOpen} title="Delete action?">
  <Modal.Body><Text>This cannot be undone.</Text></Modal.Body>
  <Modal.Footer>
    <Button onClick={()=>setOpen(false)}>Cancel</Button>
    <Button variant="danger" onClick={confirm}>Delete</Button>
  </Modal.Footer>
</Modal>
```

## Menu

Purpose        A popover list of actions/options from a trigger. NOT a select (use `Combobox`).
Layer          Composite
Replaces       EL-057 (dropdowns/popovers)

`open`/`onOpenChange` (or uncontrolled from a `trigger` slot) · items via `Menu.Item`. Renders
`role="menu"`/`menuitem`; **roving `tabindex`, ↑/↓ arrow keys, Home/End, Esc, focus trap+restore**;
`aria-haspopup`/`aria-expanded` on trigger. Fixes the "menu without menu keyboarding" defect.

## Tabs · Accordion

- **Tabs** (EL-061, EL-063, EL-079): `value`/`onChange` (uncontrolled default), `Tabs.List`/`Tab`/
  `Tabs.Panel`. Renders `role="tablist"/tab/tabpanel` with arrow-key roving + `aria-selected`.
  Collapses the 4 tab styles into `variant='underline'|'segmented'|'pill'`.
- **Accordion** (EL-062): `role`-correct disclosure; `aria-expanded`/`aria-controls` built in
  (fixes the toggles missing `aria-expanded`).

## Alert · EmptyState · Toast

- **Alert** (EL-070, EL-071, EL-072, EL-073): `tone` + `emphasis`; `role="alert"`(danger) /
  `role="status"`(else) — fixes the "errors not announced" defect. One banner, replaces red/rose/amber forks.
- **EmptyState** (EL-065, EL-066): `icon`, `title`, `description`, `action?`. One dashed-card dialect
  (merges the two `Empty` helpers + bare-text variant).
- **Toast** (EL-075): portal + `role="status"`/`aria-live="polite"`; `tone`; auto-dismiss. Provider +
  `useToast()`.

## Table · Pagination · ProgressBar

- **Table** (EL-084): renders real `<table>/<thead>/<th scope>/<tbody>/<tr>/<td>` (fixes "no table
  semantics anywhere"); `columns`+`rows` data API; `sortable?`. Replaces the faux grid/flex tables.
- **Pagination** (EL-080): `Load more` / page controls; `loading`.
- **ProgressBar** (EL-074): `value?`(indeterminate if absent); `role="progressbar"`+`aria-valuenow`.

---

# Layer 3 — Named patterns (product-specific, keep but standardize on primitives)

- **AgentPickerField** (AgentPicker/V2, EL-034 picker-as-button): agent selection; built on
  `Combobox`/`Modal` + `Card` rows. Consolidate the two picker implementations.
- **RuntimeChip / RuntimeRestartControls**: runtime status + restart; built on `StatusPill`/`Menu`/`Button`.
- **ScopeField** (memoryScope `ScopeEditor` + delete `MemoryScopeSelector`): memory-scope multi-dim
  picker; built on `Combobox`(multi) + `Badge`. Delete the gray-palette shim.
- **ConnectionBadge** (EL-087): built on `StatusPill`+`StatusDot`; drop the separate framer vocabulary.
- **Composer** (Composer + ChatComposer, EL-018): the message composer; merge the two into one built
  on `Textarea`/`IconButton`/`Menu`.

# Declared one-offs (leave local — promoting them would be dishonest)

| One-off | ID | Why it stays local |
|---|---|---|
| ArtifactViewer | EL-060 | Singular, complex, recursively-nested content viewer. Wrap its overlay in `Modal` for a11y, keep body local. |
| ChainEditor graph/canvas | EL-083 | Bespoke pan/drag DAG editor. Its draggable node is already the best interactive-div; just add keyboard to canvas/edges. |
| MessageBubble | EL-081 | Chat-specific; one place. |
| AgentActivityBubbles | EL-082 | Bespoke animated presence row; already reduced-motion aware. |
| MarkdownBody / Markdown | EL-085 | HTML-string renderer; tokenize its injected classes but don't componentize. |
| Custom scrollbar | EL-086 | Global CSS; fine as a token-driven one-off. |

---

# Rejected promotions (stated reasons — so the argument doesn't recur)

| Candidate | Occurrences | Verdict | Reason |
|---|---|---|---|
| **Tooltip** (EL-064) | 0 custom | Reject (for now) | The app uses native `title=` only. Building a Tooltip primitive has real a11y cost and there's no call site demanding it. Add only when a hover-card need appears. |
| **Kbd** | many | Keep as tiny primitive, don't over-spec | It's a styled `<kbd>`; a full component would be over-abstraction. |
| **Card as separate from Panel** | — | Merge into `Panel` (+interactive variant) | Two names for one box; a `Card` primitive + `Panel` composite would duplicate. |
| **Separate SuccessButton/DangerButton/WarningButton** | — | Reject | These are `Button variant=` / status surfaces, not new components (API rule: variant, not component). |
| **Breadcrumb** (EL-078) | 1 | Keep local, don't promote yet | Single call site; already `nav aria-label` correct. Promote if a second appears. |
| **Graph node** (EL-083) | 1 | Reject (one-off) | Product-specific to ChainEditor; no reuse. |
| **PageHeader as separate from PageShell** | — | Fold into `PageShell` | A standalone header lets pages skip the shell and re-diverge; coupling them is the point. |
