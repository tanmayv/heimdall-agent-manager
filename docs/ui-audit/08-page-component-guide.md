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
