# Shared Vocabulary

*One prop name means one thing across the whole component set. This single table does more for
learnability than any amount of per-component docs. If a component needs a concept below, it uses
**this** name and type — never a synonym (`scale`/`kind`/`color`/`onUpdate` are banned).*

## Configuration props

| Prop | Type | Meaning | Used by |
|---|---|---|---|
| `variant` | closed enum | Semantic intent + visual weight. **Never** a raw color. `Button`: `primary\|secondary\|ghost\|danger`. `Badge`/`Alert`/`Banner`: `neutral\|info\|success\|warning\|danger`. | Button, Badge, StatusPill, Alert, Banner, Callout |
| `size` | `'sm'\|'md'\|'lg'` | Maps to spacing + type tokens. `md` is the default everywhere. | Button, Input, Select, Textarea, Badge, Avatar, Icon, IconButton |
| `tone` | closed enum | Status semantics where there is no "weight", only meaning: `neutral\|info\|success\|warning\|danger\|pending`. (StatusPill/StatusDot use `tone`, action buttons use `variant`.) | StatusPill, StatusDot |
| `emphasis` | `'solid'\|'soft'\|'outline'` | How strongly a tone is painted (solid fill vs tinted vs bordered). Replaces the ad-hoc `/10`,`/20`,`/900/50` opacity forks. | Badge, StatusPill, Alert |
| `width` | `'content'\|'full'` | Layout width intent. Not a pixel. | PageShell, Panel, Button (`full` = block) |
| `align` | `'start'\|'center'\|'end'` | Cross-axis alignment. | Stack, SectionHeader, EmptyState |
| `gap` | spacing token | Space between children (`Stack`/`Inline` only). Token, never px. | Stack, Inline |

## State props (boolean per state — never per style)

| Prop | Type | Meaning | Used by |
|---|---|---|---|
| `disabled` | boolean | Non-interactive + dimmed + removed from tab order. | Button, Input, Select, Textarea, Checkbox, Radio, Toggle, MenuItem |
| `loading` | boolean | In-flight; shows spinner, keeps size, sets `aria-busy`. | Button, PageShell, Panel |
| `invalid` | boolean | Validation failure; error styling + `aria-invalid`. | Input, Select, Textarea, FormField |
| `selected` | boolean | Chosen among siblings (`aria-selected`/`aria-pressed`). | Tab, MenuItem, ListRow, Card (interactive) |
| `expanded` | boolean | Disclosure open (`aria-expanded`). | Accordion, Menu trigger, collapsible SectionHeader |
| `readOnly` | boolean | Displayed, not editable. | Input, Textarea |
| `open` | boolean | Overlay visibility (controlled). | Modal, Menu, Drawer, Popover |

## Content / composition props

| Prop | Type | Meaning | Used by |
|---|---|---|---|
| `children` | node | The primary content / composed structure. Structure comes through children, not string props. | all containers |
| `leading` / `trailing` | node | Slot before / after the label (icon, badge, kbd). Replaces `iconLeft`/`showIcon`. | Button, Input, ListRow, MenuItem |
| `label` | string | **Required** accessible name where there is no visible text (icon-only). | IconButton, FormField, Toggle |
| `description` / `hint` | node | Secondary helper text. | FormField, SectionHeader, EmptyState |
| `title` | node | Visible heading of a section/panel/page. | PageShell, Panel, SectionHeader, Modal |
| `error` | string | Field-level error message (implies `invalid`). | FormField |

## Event props (consistent handler names)

| Prop | Type | Meaning | Used by |
|---|---|---|---|
| `onChange` | `(value) => void` | Value changed (controlled). **Never** `onUpdate`/`onInput`. | Input, Select, Textarea, Checkbox, Radio, Toggle, Tabs |
| `onSelect` | `(value) => void` | A discrete option was chosen. | Menu, Combobox, CommandPalette |
| `onOpenChange` | `(open: boolean) => void` | Overlay open state changed. | Modal, Menu, Drawer, Popover |
| `onClick` | `(e) => void` | Activation of a button-like control. | Button, IconButton, ListRow |

## Controlled vs uncontrolled (one rule for the whole set)

- **Form primitives** (`Input`, `Select`, `Textarea`, `Checkbox`, `Radio`, `Toggle`) are
  **controlled**: `value`/`checked` + `onChange`. No internal value state.
- **Overlays** (`Modal`, `Menu`, `Drawer`, `Popover`) are **controlled**: `open` + `onOpenChange`.
- **Disclosure/Tabs** default **uncontrolled** (`defaultValue`) with an optional controlled
  `value`/`onChange` override. Documented per component; the default is uncontrolled.

## The one escape hatch

- `className` passes through to the component **root only**, merged after internal classes. It is an
  escape hatch with a cost (it can break token guarantees), not a styling API. No `style` prop except
  where a dynamic value genuinely can't be a token (e.g. a computed progress width). No per-part
  class props (`headerClassName`, …) — use composition instead.
