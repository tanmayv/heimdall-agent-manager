# Per-Page Component Guide

*For each page, the component to use for each intent slot — so every page is assembled from the same
parts and looks like one app.* Components are from `04-component-catalogue.md`; props from
`05-shared-vocabulary.md`. The rule: **choose by intent, not by look.** Two pages needing "the main
action" both use `<Button variant="primary">` — never a hand-tuned pill.

## The intent → component defaults (memorize this once; it applies to every page)

| Intent | Component | Notes |
|---|---|---|
| The whole page frame | `PageShell` | `title` (the one `<h1>`), `eyebrow?`, `description?`, `actions`, `width`. Never hand-build a header. |
| A group/section inside a page | `Panel` + `SectionHeader` | One card radius, one section-title dialect. |
| The primary action (1 per region) | `Button variant="primary"` | The single most important action. Exactly one per toolbar/form. |
| A secondary action | `Button variant="secondary"` | Cancel, back, alternate action. |
| A low-emphasis / inline action | `Button variant="ghost"` | Row actions, "show more", filters. |
| A destructive action | `Button variant="danger"` | Delete, remove, revoke. |
| An icon-only action | `IconButton` (+ required `label`) | Close, edit, overflow, refresh. Never a bare glyph/emoji. |
| Navigate somewhere | `Link` | Not `Button`. |
| One value from a short list | `Select` | Native, labelled by `FormField`. |
| One/many from a long/searchable list | `Combobox` (`multiple` for many) | Agents, projects, scopes, providers. |
| A boolean setting (applied immediately) | `Toggle` | e.g. notifications, enable/disable. |
| A form field (label+control+error) | `FormField` wrapping the control | Wires `htmlFor`/`aria`. |
| A status/state label | `StatusPill` `tone=…` | running/queued/failed/etc. |
| Liveness indicator | `StatusDot` `tone=… pulse` | + hidden text label (not color-only). |
| A count / neutral tag | `Badge` | unread counts, tags, tiers, kinds. |
| A removable tag / filter chip | `Badge` in a `Combobox multiple` (or chip input) | |
| A record in a list | `Card` (interactive) or `Table` | `Card` for rich rows, `Table` for tabular data (real `<th>`). |
| A dialog | `Modal` | focus trap + Esc built in. |
| A menu of actions | `Menu` | roving keyboard. |
| Switch views within a page | `Tabs` | `variant='underline'|'segmented'|'pill'`. |
| Nothing to show | `EmptyState` | icon + title + optional CTA. |
| Loading | `Spinner` / `Skeleton` | `role=status`. |
| A message (error/success/info) | `Alert` `tone=…` | `role=alert` for errors. |

---

## Page-by-page prescriptions

### Chat — Conversations home (`ConversationsHomePage`)
| Slot | Use |
|---|---|
| Frame + header | `PageShell` eyebrow="Conversations" title="Inbox" actions=`<Button variant="primary" leading=plus>New</Button>` |
| Conversation rows | `Card` interactive (keeps the `<a>` semantics it already has) with `Avatar` + `Badge` (unread) |
| Empty / loading | `EmptyState` / `Spinner` |

### Chat — Thread (`ConversationThreadPage`)
| Slot | Use |
|---|---|
| Header | `PageShell` (title = conversation name as `<h1>`); rename via inline `Input` + `IconButton` save/cancel |
| Right inspector tabs | `Tabs variant="segmented"` (Memory/Workspace/Sessions) |
| Send / attach / overflow | `IconButton` (send, attach, overflow) — one merged `Composer` |
| Provider/tier pickers | `Select` (short) — retire the hand-rolled fake-select popover |
| Runtime status menu | `Menu` |
| Message actions (approve/reject/nudge) | `Button variant="primary"` (approve/confirm) / `variant="danger"` (reject) / `variant="ghost"` (nudge) |
| Status/priority labels | `StatusPill tone` |
| Errors / agent-working | `Alert tone="danger"` (role=alert) / `Spinner` with `aria-live` |

### Projects (`ProjectsSurface`, `ProjectLaunchModal`)
| Slot | Use |
|---|---|
| Frame + header | `PageShell` eyebrow + title + `Button variant="primary"` (New/Launch) |
| Project rows | `Card` interactive + `Avatar` + `StatusDot`/`StatusPill` (live) + `Badge` (counts) |
| Row actions (edit/recheck) | `IconButton` (edit, refresh) |
| Launch dialog | `Modal` with `FormField`s; agents via `Combobox multiple`; tier via `Select` |
| Empty / loading | `EmptyState` / `Spinner` |

### Actions (`ActionsPanel`, `ActionEditorPage`, `ScheduleEditor`, `DeleteActionModal`)
| Slot | Use |
|---|---|
| List frame | `PageShell` title="Actions" + `Button variant="primary"` (New action) |
| Grouped actions | `Accordion` (project groups) → `Card` rows |
| State / schedule chips | `StatusPill tone` (state) + `Badge` (timezone/blackout, removable) |
| Row actions | `IconButton` (edit/run) + `IconButton variant="danger"` (delete) |
| Editor form | `PageShell` + `Panel`/`SectionHeader` sections; `FormField` + `Input`/`Textarea`/`Select`; mode switch = `Tabs variant="segmented"`; day pickers = chip toggles (`Toggle` group) |
| Delete confirm | `Modal` + `Button variant="danger"` |
| Feedback | `Alert` (dismissible) / `EmptyState` (rich) |

### Task chains (`TaskChainsPage`, `TaskChainOverview`, `TaskCommentsThread`)
| Slot | Use |
|---|---|
| List frame | `PageShell` title="Task chains" + count `Badge` |
| Overview header | `PageShell` — **give it a real `<h1>`** (today it's an `<h2>`) + `StatusPill` |
| Tasks table | `Table` (real `<th scope>`) — replaces the div/grid faux-table |
| Progress / priority | `StatusPill tone` (todo/doing/review/done, priority) |
| Reconcile / row actions | `Button variant="primary"` (reconcile) / `Menu` (quick actions, with roving keys) |
| Edit reviewers/deps | `IconButton` (pencil, with label) → `Modal` + `Combobox multiple` |
| Modals (create/edit) | `Modal` (adds the missing focus trap/Esc/aria) |
| Load more | `Pagination` |

### Memory (`MemoryPage`, `MemoryDetailPage`, `MemoryManagementPage`)
| Slot | Use |
|---|---|
| Frame + header | `PageShell` (drop the `rounded-3xl` outlier → standard `Panel`) |
| Scope picker | `ScopeField` (on `Combobox multiple` + `Badge`) — **delete the gray `MemoryScopeSelector` shim** |
| Tabs | `Tabs variant="underline"` |
| Memory rows | `Card` + `Badge` (count/tone) |
| Approve/reject | `Button variant="primary"` / `variant="danger"` |
| Modals | `Modal` (replace both duplicated `ModalShell`s) |
| Empty | `EmptyState` (merge the two `Empty` helpers) |

### Settings panels (`Bridges`, `Providers`, `Projects`, `Templates`, `UserTokens`, `Notifications`, `Memory`)
> These 7 diverge the most — one fix here is the biggest consistency win.
| Slot | Use |
|---|---|
| Panel frame | `PageShell width="content"` (one width — retire `max-w-3xl/4xl/5xl`) + one `SectionHeader` dialect (retire the `h2 bold`/`h3 no-size`/`border-b` mix) |
| Bridges: stop wrapping the whole panel in a card | use `PageShell` + inner `Panel`s |
| Forms | `FormField` + `Input`/`Select`/`Textarea` (fixes sibling-label gaps) |
| Toggles (Notifications) | `Toggle` (already the best pattern — promote it) |
| Provider/tier defaults | `Radio` group in `FormField` |
| Chip lists (provider models) | `Combobox multiple` / chip input |
| Save / danger | `Button variant="primary"` / `variant="danger"`; replace `window.confirm` with `Modal` |
| Status | `StatusPill` / `StatusDot` |

### Agents (`AgentsPanel`, `AgentDetailPanel`, `AgentListItem`, `AgentPicker*`)
| Slot | Use |
|---|---|
| Frame | `PageShell` |
| Agent list rows | `Card` interactive — **fix `AgentListItem` (`div onClick` → keyboard-reachable Card)** |
| Agent picker | `AgentPickerField` (consolidate `AgentPicker` + `AgentPickerV2`) on `Combobox`/`Modal` |
| Skeleton loading | `Skeleton` (this panel already does it — standardize) |
| Tier/status | `Badge` / `StatusPill` |

### Skills (`SkillViewerPage`)
| Slot | Use |
|---|---|
| Frame | `PageShell` (title as `<h1>`, not `text-lg`) + `Badge` (skill kind) |
| Body | `Markdown` (already shared) |

### App shell / global (`AppShell`, `responsive`, `CommandPalette`, `LibraryPage`)
| Slot | Use |
|---|---|
| Sidebar nav / mobile tabs | keep in the shell layer (NavItem) — already the most consistent part |
| Command palette | `CommandPalette` pattern on `Modal` + `Combobox` (add dialog role + listbox semantics) |
| Library grid | `Card` grid; filters via `Select`; row actions `IconButton` |
| Any dialog/drawer | `Modal` / `Drawer` |

---

## The one habit that keeps pages similar

On every new page: reach for `PageShell` first, put content in `Panel`s with `SectionHeader`s, and
pick each control by the **intent table at the top** — never copy a className from another file. If an
intent isn't in the table, it's either a one-off (document it) or a missing component (propose it) —
not a new inline style.

## Definition of Done for UI tasks

*A UI/visual task is not `in_validation`-ready until every box below is true. Workers self-check; the reviewer enforces and will `ngtm` on any miss. "UI task" = anything that changes rendered markup, styling, tokens, or a page/component's structure.*

**Proof (attach to the handoff comment):**
- [ ] **Screenshot(s) attached** — an *after* shot of each changed surface; *before/after* when altering existing UI. Interactive states (menus, modals, palettes, drawers, empty/loading/error) shown in the state that changed. Sent as file cards, not described in prose. (Capture path for the Heimdall dashboard: vite `:5173` → dev-proxy `:8110`, headless Firefox over WebDriver-BiDi so the SPA renders past auth.)
- [ ] **`npm run typecheck` + `npm run build` green** at the committed HEAD (paste the result).

**Conformance to the system (04 catalogue / 05 vocabulary / this guide):**
- [ ] **One `PageShell` frame per route** — the single `<h1>` comes from `title`; no hand-built page headers, no second `<h1>`, no ad-hoc `max-w-*` page roots (width via the ramp). Deliberate divergences are documented in 07 §0.1.
- [ ] **@ui primitives only** — no bespoke twin of an existing `@ui` component (Button/IconButton/Select/Modal/Menu/Popover/Drawer/StatusDot/Badge/Kbd/…). If a primitive is missing a capability, extend the primitive (data-driven, backward-compatible) rather than hand-rolling at the call site.
- [ ] **Intent → component defaults respected** — primary action = `Button variant="primary"` (one per region); count/tag = `Badge` (`tone="info"` for counts); status = `StatusPill`; liveness = `StatusDot` + non-color label; icon-only = `IconButton` with a `label`; dialog = `Modal`; menu = `Menu`; anchored panel = `Popover`; edge/bottom sheet = `Drawer`.
- [ ] **Tokens, not literals** — color/space/radius/shadow/z from tokens (`text-*`/`bg-*`/`border-subtle`/`z-modal`/`shadow-overlay`); no raw hex, no arbitrary `z-[..]`. The app's white-opacity hover idiom is allowed.
- [ ] **A11y intact** — labelled controls, focus-visible, roles/keyboard for interactive widgets; dialogs/overlays use `useDialogA11y` (or a primitive that does).
- [ ] **Guardrails green** — native-`<select>` allowlist stays **empty** (and any future guardrail test passes); `data-debug-id`s preserved on migrated controls.

**Scope discipline:**
- [ ] **No behavior/logic change** unless it's the task's stated goal — header/shell/style refactors keep handlers, data flow, and routes identical.
- [ ] **Twins deleted** — when a call site moves to `@ui`, the old local component/shim is removed once it has no other consumers (grep to confirm zero importers).
