# Rebuild resource pages on @ui — actions / projects / agents / memory / shells

## Goal
Replace five divergent, snowflake resource UIs with one uniform page system built on the
existing `@ui` component library. Phase 1 (this chain) is PLANNING ONLY: one written plan
per resource, reviewed against the user's rules. Implementation follows for exactly ONE
resource, chosen by the user after the plans are approved.

## Scope
IN: actions, projects, agents, memory, shells — list page, add/edit page, view page.
OUT (this chain): writing any page code, backend changes, and the other four resources'
implementations.

## Ground truth established by the coordinator (do not re-derive; verify before contradicting)

- **G-1 `@ui` already exists and is populated.** `src/ui/components/ui/` behind the `@ui`
  alias. primitives: Avatar, Badge, Button, Checkbox, Combobox, Icon, IconButton, Input, Kbd,
  Link, Radio, Select, Spinner, StatusDot, StatusPill, Text, Textarea, Toggle.
  composites: Accordion, Alert, Drawer, EmptyState, FormField, Menu, Modal, PageShell,
  Pagination, Panel, Popover, ProgressBar, SectionHeader, Table, Tabs, Toast.
  patterns: CommandPalette, RuntimeChip, ScopeField.
  Rules of the road live in `src/ui/components/ui/README.md` (tokens only, shared prop
  vocabulary in `types.ts`, a11y built in, single `className` escape hatch, barrel exports).
  NOTE its "Status: Empty scaffold" line is STALE — the components exist. Build on `@ui`;
  do NOT author a second component library. Propose additions to `@ui` only when no existing
  component fits, and say so explicitly in the plan.

- **G-2 Search scopes.** `src/hub/domain/search.odin:11` —
  `SEARCH_TYPE_ORDER :: {"conversation","message","agent","agent_instance","task-chain",
  "task","comment","project","artifact","memory","skill"}`.
  So: memory / project / agent(+agent_instance) HAVE a server search scope.
  **actions and shells DO NOT.**

- **G-3 Search has no facets.** `Search_Input` (src/hub/service/search/search_service.odin:17)
  = q, types_csv, limit, cursor, task_ids, chain_ids, project_ids, conversation_ids, the four
  `not_in_*` variants, and `exclude` (substring). There is NO filter for memory scope/type/
  status, agent status, or action enabled. Limits: DEFAULT 20, MAX 50, scan cap 200.

- **G-4 Pagination is keyset, not offset.** List endpoints take `limit` + `cursor` and return
  `{limit, next_cursor, has_more}` with NO total count
  (src/hub/transport/http/agent_handlers.odin:24-35, project_handlers.odin:15-25).
  The cursor COLUMN IS PER RESOURCE — verify it, do not assume. agents/projects use
  `created_at`; **memories use `updated_at`** and are recently-updated-first, so a write
  reorders a row (content_repo_sqlite.odin:31, content_service.odin:148-152,
  content_handlers.odin:40). Actions may not paginate at all — the user has waived
  REQ-UI-6 for actions.

- **G-5 Mobile infrastructure exists.** `src/ui/components/shell/responsive.tsx` —
  `useViewport()`, `useIsMobile()`, `useKeyboardInset()`; breakpoints MOBILE_MAX=767,
  TABLET_MAX=1023. `@ui` Drawer handles off-canvas. URL state helper: `src/ui/useUrlParams.ts`
  (at `src/ui/components/useUrlParams.ts`). Markdown: `Markdown.tsx` / `MarkdownBody.tsx`.

- **G-6 Current (to-be-replaced) implementations.**
  actions: `src/ui/components/actions/` (ActionsPanel 575L, ActionEditorPage 611L,
  DeleteActionModal, ScheduleEditor, scheduleUtils)
  agents: `src/ui/components/agents/` (AgentsPanel 155L, AgentDetailPanel)
  memory: `src/ui/components/memory/` (MemoryPage 374L, MemoryDetailPage 224L, memoryScope)
  projects: `src/ui/components/projects/` (ProjectsSurface, ProjectLaunchModal)
  shells: `src/ui/components/shells/` (ShellsPanel, ShellTerminalPane, ShellLogViewer,
  NewShellDialog, SetShellPortDialog, PreviewSidebar, ShellsTabBadge, useShellStream)
  Related: `src/ui/components/projects/MemoryPanel.tsx`, `agents/ProjectChainTree.tsx`.
  Hub handlers: `src/hub/transport/http/{action,agent,agent_instance,project}_handlers.odin`.
  Terminology warning: in Heimdall an **Action = a scheduled/cron prompt** targeting an agent
  (domain/action.odin, table `actions`), NOT a UI action.

## Requirements (user-stated; binding on every plan)

- **REQ-UI-1 Uniformity.** All five resources share one page system: list -> view -> edit.
  A deviation is allowed only where this doc grants an exception, and must be justified.
- **REQ-UI-2 List page.** Rows in a list (not cards) on desktop, with relevant columns and a
  per-row edit action.
- **REQ-UI-3 Filters + tabs.** Per-resource filters; tabs only where the resource needs them
  (memory: proposed vs active; agents: none).
- **REQ-UI-4 Search.** Resources WITH a server search scope (memory, projects, agents) use the
  search API scoped to that type. Resources WITHOUT one (actions, shells) get a **client-side
  fuzzy search over the already-loaded list**, UI-identical to the server-backed one.
- **REQ-UI-5 Search vs filters.** When a search query is active, **filters are disregarded**
  (and the UI must say so visibly). Settled by the user; do not redesign this.
- **REQ-UI-6 Infinite scroll.** Keyset/cursor-driven infinite scroll. No numbered pages, no
  "Load more" button, no total counts.
- **REQ-UI-7 Bulk select.** Checkbox multi-select with a bulk DESTRUCTIVE ACTION — read
  "delete" as whatever the resource's destructive verb actually is. Memory has NO delete
  endpoint: it is bulk ARCHIVE (Active) and bulk REJECT (Proposals). Shells is bulk KILL.
  Each plan states the verb, the confirm flow, and partial-failure behaviour.
- **REQ-UI-8 Single Add button**, top right, navigating to a full page (not a modal).
- **REQ-UI-9 Add/edit is one page.** The same form page serves create and edit. Every field
  declares its input type (input / textarea / select / combobox / toggle / radio / modal
  picker) and its validation rule + the exact user-facing error message.
- **REQ-UI-10 Save -> view.** Saving navigates to that resource's view page.
- **REQ-UI-11 View page is read-only**, renders markdown where the field is markdown, and all
  editing happens on the edit page.
- **REQ-UI-12 Linked resources.** The view page lists the other resources linked to this one.
- **REQ-UI-13 Mobile is mandatory.** Every page works at <=767px. Tables are OPTIONAL on
  mobile: where a table does not fit, propose a **space-efficient, easy-to-read card/row
  model** and specify exactly which fields survive the squeeze and in what priority order.
- **REQ-UI-14 Breadcrumbs.** Every resource page carries breadcrumb navigation. The plan
  states the exact breadcrumb trail for list, view, and add/edit.
- **REQ-UI-15 Shell exceptions.** Shells get NO create form and NO edit page (they are runtime,
  started by agents). Shells keep: list, filters, fuzzy search, view page, breadcrumbs, mobile.
- **REQ-UI-16 Three states.** Every list/view defines loading (skeleton), empty, and error
  states — with first-run-empty and no-results-for-query as DIFFERENT copy.
- **REQ-UI-17 URL is state.** Tab, filters, query, and scroll position live in the URL so back/
  forward and deep links work (critical for mobile drill-down).
- **REQ-UI-18 Destructive actions.** Confirm-vs-undo policy, and what happens when deleting a
  resource that other resources reference.
- **REQ-UI-19 Touch selection.** Multi-select must be reachable without hover (explicit select
  mode + bottom action bar on mobile).
- **REQ-UI-20 Live updates.** Agents and shells mutate via WS. Plans state the refresh policy
  (preferred: a "N new" badge, never silent reordering under the user).
- **REQ-UI-21 Create vs edit differ.** Immutable-on-edit fields, unsaved-changes guard, and
  server-side validation errors mapped back onto the offending field.

## Phase 1 deliverable — one plan per resource
Each planning task produces a written plan, posted as a task comment (and a file under
`docs/ui-rebuild/<resource>.md` in the project checkout), covering, in this order:
1. Tabs (or an explicit "none, because ...").
2. Filters — each filter's control type, its options, its default, and the API/query param
   that backs it (or "client-side, because no server facet" per G-3).
3. Search — server-scoped or client fuzzy (per G-2/REQ-UI-4), the fields matched, and the
   visible treatment of REQ-UI-5.
4. List columns — ordered, each with its source field, and a **mobile priority order**.
5. Mobile model — the card/row design per REQ-UI-13, with the exact fields shown.
6. Row actions + bulk actions, incl. destructive confirm flow (REQ-UI-7, REQ-UI-18).
7. Add/edit form — every field: label, input type, required?, validation rule, exact error
   message, immutable-on-edit?, and which backing endpoint field it maps to (REQ-UI-9/21).
8. View page — sections, which fields render as markdown, and the linked-resources list with
   the endpoint each link set comes from (REQ-UI-11/12).
9. Breadcrumb trails for list / view / add / edit (REQ-UI-14).
10. Empty / loading / error copy (REQ-UI-16).
11. URL parameter scheme (REQ-UI-17).
12. `@ui` components used, and any component the resource needs that `@ui` lacks (G-1).
13. Open questions for the coordinator.

## Verification
Plans are reviewed by a dedicated reviewer against REQ-UI-1..21 and G-1..G-6. A plan is
approved only on an `lgtm` naming which requirement each section satisfies. A plan that
contradicts ground truth (e.g. proposes server search for actions, or numbered pagination)
is an automatic `ngtm`.

## Phase 2 (not yet scoped)
After all five plans are approved, the user picks exactly ONE resource to implement; it
becomes the frozen reference implementation the other four are later held against.


## User rulings (settled — no plan may redesign these)
- **Memory tabs** are Active / Proposals, backed by `status=active` / `status=pending`.
  The status values are pending|active|rejected|archived. "proposed" does not exist.
- **Memory has no DELETE endpoint.** Destructive verbs are archive and reject. The
  existing UI labels archive as "Delete" — do not inherit that; call it Archive.
- **Agents list shows DURABLE identities only.** Running instances appear on the durable
  agent's VIEW page ("if accessible" — degrade, do not error, when they cannot be
  fetched). Search uses the `agent` scope, not `agent_instance`.
- **Actions: no pagination is fine.** REQ-UI-6 waived for actions; load the full list.
- **Shells:** clicking an entry opens a view page showing stdout, plus a live-preview
  option when available (server_port / preview_enabled). restart / kill / SIGINT are
  available from the view page, with a confirm policy proportional to each. The list page
  supports bulk KILL.
- **No list may re-sort under the user while mounted.** A user's own mutation must not
  make its row jump; changes from elsewhere get a "N updated" affordance (REQ-UI-20).

## Review process (current)
The reviewer agent is stood down. The COORDINATOR reviews every plan and sends findings
to the worker as task comments; the USER gives the final lgtm off a brief summary the
coordinator writes. A task completes only on the user's approval.

## READ FIRST — a numbering collision, and how to resolve a citation
Two amendments were written twice under the same numbers, by two authors working in parallel.
They have been renumbered, but **citations written before this fix are ambiguous**, and there
are many of them (20 to "Amendment 6", 13 to "Amendment 5"). Resolve them by subject, not number:

- **"Amendment 5"** in older text means EITHER the breadcrumb rule (list pages carry no trail)
  OR the polish-pass conventions, now **Amendment 11**.
- **"Amendment 6"** in older text means EITHER the row/design rules inherited by all five
  resources OR the redesign conventions, now **Amendment 12**.

Nothing was deleted and no rule changed. If a citation is ambiguous, both sections it could mean
are in this file and neither contradicts the other — read both.

## STANDING GAPS — things this chain did NOT verify
Recorded so they are found without reading the task history. None is a known defect; each is an
untested behaviour that someone should either exercise or knowingly accept.

- **Memory: auto-advance is untested.** Approving the last pending proposal should advance the
  pane; it has never been exercised. It is Memory-specific, needs a pending queue constructed,
  and is not in the interaction harness.
- **Agents: NO interaction verification at all.** The harness run for Agents exited 2 with a
  300-second navigation timeout against a Vite dev server. Not partial — none. Every interaction
  on that page is READ SOURCE only.
- ~~**Shells: the list is unverified**~~ — **CLOSED 2026-09-22.** The owner-wide endpoint landed
  (`task_18d780b0dfd7fa6c`) and the seven blocked predicates were driven against a live preview
  with real rows. All 16 interaction predicates pass at 1440 and 390. What the gap was actually
  hiding is worth keeping: the page's central query could never have returned a row on ANY of the
  four routes, because the tabs sent `status=live|finished` and the column holds
  `starting|running|exited|killed|failed`. A blocked predicate is not a neutral absence — it was
  concealing a defect that no amount of reading the code had found.
- **Real touch hardware: never tested** on any resource. Every mobile result in this chain is a
  390x844 viewport driven through Marionette, which is not a finger.
- **The desktop bulk-bar containing-block cause was never attributed.** Seventeen ancestors were
  checked for all six CSS properties that can capture a `position: fixed` element; none was
  found. The portal fix works regardless. Recorded as observed Firefox behaviour, not a spec rule.

## EVIDENCE THAT THE SHARED-COMPONENT APPROACH WORKED
`scripts/ui-interaction-harness.mjs` was written during Projects and extended during Actions.
It then drove **Shells — a fifth resource — with no edit to the harness file**: `--resource shell
--route /shells` worked because each row was written to the attribute contract
(`<resource>-row-menu-<id>`, `data-<resource>-row=<id>`) rather than to its author's taste.
Nothing broke, which is precisely why this result would otherwise go unrecorded.

**The honest footnote, added when Shells finished.** The harness has since taken its first edit
since Actions: a `--no-create-form` flag. It asserted that every resource has a create form at
`/<resource>/new`, and Shells deliberately has none (REQ-UI-15), so a correct page collected two
red rows per width for obeying a requirement — and a truth table that shows red for correct
behaviour teaches its reader to skim red. The two predicates are now recorded `N/A` with the
reason, as the hover and touch ones already were.

This does not weaken the claim above, but it does sharpen it. The **attribute contract** carried a
fifth resource with no change at all — rows, menus, tabs, search, filters and the bulk bar all
drove untouched. What needed teaching was not how to drive this page, but that a resource may
legitimately have nothing to drive. Those are different claims and only the first one was ever
being made.

## Amendment 2 — conventions established while building Memory (binding on the four parked plans)
- **Breadcrumbs are PAGE-owned, not shell-owned.** The shared `Breadcrumbs` composite now lives
  in `@ui/composites` and `PageShell` takes a `breadcrumbs` prop; the app shell renders a trail
  only on its not-found placeholder. Each page supplies its own crumbs — the only way a detail
  crumb can carry the record's title. Memory plan §9's "the shell emits them via
  `breadcrumbsFor(path)`" is superseded; the trails themselves stand.
- **The five shared `@ui` pieces now exist** and every resource page builds on them rather than
  re-deriving: `hooks/useInfiniteList` (keyset paging, de-dup, hold-position refresh +
  `pendingCount`/`applyPending`, `patchItem` act-in-place, capped `restoreToId`, `pagingError`
  separate from `error`), `composites/DataList` (columns on desktop, cards <=767px via per-column
  `mobileRole`, one selection model; wraps `Table`), `composites/BulkActionBar`, `composites/FilterBar`
  (wholesale disable as a real `<fieldset disabled>` for REQ-UI-5), `composites/Breadcrumbs`.
- **Viewport primitives live in `@ui/hooks/useViewport`** (`MOBILE_MAX`, `TABLET_MAX`, `useViewport`,
  `useIsMobile`, `useKeyboardInset`, `TOUCH_TARGET_CLASS`). `shell/responsive.tsx` re-exports them;
  never import `shell/` from inside `@ui`.
- **A dedicated tab per terminal state is memory-specific** (Amendment A1.5) — do not copy it to
  agents, actions or shells.

## Live bugs the rebuild has surfaced so far (evidence, not incidental cleanup)
1. Memory scope filters send multi-value CSVs but the hub honours only the FIRST token
   (`content_handlers.odin:690-698`) — the shipped page shows three chips and filters by one.
2. The client's `normalizeMemory` reads `updated_unix_ms`, which `write_memory_json` never emits
   (`content_handlers.odin:590`) — so every relative timestamp on the shipped memory page is
   rendered from a permanent 0.
3. Keyset paging uses a strict `<` seek on `updated_at`, so rows sharing a timestamp at a page
   boundary are silently dropped (hub-side; recorded in memory.md §13c).

## Amendment 3 — a trap every resource page can inherit
`FilterBar`'s `actions` slot renders **outside** its `<fieldset disabled>`, deliberately: that
slot is also where a one-click RESTORE belongs while the bar is disabled. Consequence — a
caller that puts a control there which would mutate the state REQ-UI-5 promises to restore
(a "Clear filters" button, say) **must gate that control itself**. Found on the Memory page:
while a query was active, Clear filters was still live, so one click would have destroyed the
exact filter state the Alert promised to bring back. Gate at the call site
(`filtersActive && !searching`) and leave a comment saying why.

## Amendment 4 — overflow belongs to the content, not the page
The page body must NEVER scroll horizontally. Wide content — tables, code blocks, long unbroken
strings — scrolls inside its OWN `overflow-x: auto` container, with the page pinned to 100%
width. For lists this lives in `DataList`, so the header, tabs, filter bar and breadcrumbs stay
put while columns move under them. Decide the sticky treatment for the select and actions
columns (and give a sticky column an opaque token background). The scroll region needs a
keyboard path (`tabindex="0"` + `role="region"` + `aria-label`). Never introduce a nested
VERTICAL scroller — infinite scroll's IntersectionObserver sentinel depends on the page scroller.
Applies at every width; the case that bites is a narrow desktop or tablet, not mobile (where
DataList renders cards instead).

## Amendment 5 — breadcrumbs are the page title, so list pages carry no trail
`PageShell` renders the trail's ANCESTORS only and makes the terminal crumb the `<h1>`. A list
page is the root of its own section, so it shows one heading and no trail; detail and edit pages
show "Memory /" above the record title, which is where a trail was always earning its place.
This supersedes the literal reading of REQ-UI-14 ("breadcrumbs on every resource page") — the
rule was producing a crumb reading "Memory" stacked directly above a heading reading "Memory".
User-informed. Applies to all five resources; do not re-derive a trail that duplicates the title.

## Amendment 11 (was a duplicate "Amendment 5") — conventions from the Memory polish pass
Established while acting on the user's "the ui is messy … spacing is all wrong and not
aesthetics and we shouldn't use icon buttons … prefer icon buttons in mobile view".

- **The breadcrumb IS the title.** `PageShell` renders only the trail's ANCESTORS and makes the
  terminal crumb the page's `<h1>`. A list page therefore shows one heading and no trail; a
  detail page shows "Memory /" above the record's title. Pages keep passing their FULL trail —
  the deduplication is the shell's job. Supersedes any plan that renders a trail and an H1 that
  say the same word.
- **No icon-only buttons on desktop; icon buttons preferred on touch.** One action, two
  renderings, ONE component: `@ui/composites/ActionButton` (labelled `Button` on desktop, an
  `IconButton` carrying the SAME string as its accessible name at ≤767px). Row actions and bulk
  verbs go through it. An icon-only control that survives on desktop must justify itself.
- **Filters are collapsed behind a `Filters` button on EVERY viewport** (`FilterBar`'s default
  `layout="collapsed"`; `layout="inline"` remains for a list where filtering is the primary
  act). What stays on the page is the `summary` slot — chips for the NON-DEFAULT filters only,
  and each chip clears its own filter. An explanation of what the filters mean goes in the
  `note` slot, which rides inside the drawer instead of costing the page a permanent band.
- **Search sits inline with the tab row**, never as a full-width band above it: as its own band
  it outweighs the tabs, which are the page's primary navigation.
- **One vertical rhythm, applied at the frame.** `PageShell rhythm="banded"` gives the body the
  page's own inline padding and ONE gap between bands. Pages do not tune gaps element by
  element. (Opt-in while the un-migrated pages keep their hand-rolled spacing; it is the
  convention for every page the rebuild touches.)
- **Prose is capped to a measure** (`.ui-measure`, 68ch): page descriptions, empty-state copy,
  explanatory notes. Headings and data are not capped.
- **One hierarchy per row.** The row title is the scanning target — `text-title`, full contrast;
  every other column recedes in colour AND weight (`DataList` does this, so no page repeats it).
- **A truncated one-line prose summary next to a title does not earn its column.** Memory's
  Summary column is gone; do not add its equivalent to actions, projects, agents or shells.
- **Scope-style chip runs collapse in a list row.** All-empty → a single **Global** chip;
  narrowed → the narrowing chips plus one muted "all other scopes". The record page keeps the
  full per-dimension rendering (`ScopeChips variant="full"`). Four "All …" chips per row cost
  three lines of row height to say nothing distinguishing.
- **Persistent bottom chrome is a CSS variable, not a prop.** The shell publishes
  `--ui-bottom-chrome` from the measured height of `MobileTabBar`; `BulkActionBar` docks above
  it. Anything else pinned to the bottom edge must read the same variable. Without it the bulk
  verbs render *behind* the tab bar and bulk select is unusable on mobile (REQ-UI-19).
- **An option catalog has THREE states, not one.** loading / empty / failed must read
  differently — "No bridges available" is not the same fact as "Couldn't load bridges", and
  neither is an empty list. `scopeCatalogState` + `ScopeCatalogNote` (`@ui/patterns/ScopeField`)
  carry the wording; every consumer of a catalog (the form AND the list's filters) renders it.
  Same argument as REQ-UI-16's four empty states.

### Pre-existing constraint found while verifying Amendment 4
`src/ui/styles.css` sets a global `body { min-width: 920px }` (dropped only below 768px). So a
desktop window narrower than 920px scrolls the WHOLE app horizontally, no matter what any page
does — including the 768–1023px tablet band the arch doc claims to support. This is app-level
chrome, predates the rebuild and was left alone here; Amendment 4 was verified at 1000px
instead (page 1000/1000, table region 768/600 — the table scrolls, the page does not). Someone
should decide whether that floor still earns its place.

## Amendment 6 — the Memory design is the design for all five resources
User-stated: *"We follow the same design for the rest where applicable."* So the shape settled on
Memory is now BINDING on Projects, Agents, Actions and Shells. The four parked planning tasks
were written assuming a column table; that assumption is dead. Inherit, do not re-derive.

**The row is a four-line anatomy, not a table row:**
```
Title ..........................................  [icon] [icon] [icon]
body line 1
body line 2
[pill] [pill] [pill] ..................................... 12m ago
```
- Row 1: title (one line, truncated) + a SINGLE right-aligned "…" menu trigger. No action icons,
  no inline Approve/Reject, no hover cluster — user-ruled. The title truncates against the
  trigger rather than pushing it off; the trigger needs a >=44px touch target and must not
  navigate when the row itself does.
- Rows 2-3: the resource's descriptive text, clamped at exactly two lines — reserved even when
  empty, so the pills never jump up a line.
- Row 4: pills left-aligned; relative time bottom-right, absolute date in `title`.
- 72px is a FLOOR, not a target. Measure the result; never assert it.

**Row actions live in exactly three places: the row's "…" popup, the bulk bar in select mode,
and the view page header.** Inside the popup the verbs carry TEXT LABELS (an icon beside a label
is fine; an icon instead of one is not) — which is what removes the ambiguous-destructive-glyph
risk rather than merely mitigating it. Only the verbs that mean something in that state appear.

**Icon buttons elsewhere (toolbar: Filters, Select, New), every viewport.** This supersedes the
earlier labelled-on-desktop rule.
Every icon button carries a real accessible name AND a visible tooltip on hover/focus — with no
on-screen label, that is the only way the control is identifiable. Destructive verbs get distinct
icons and tones; never one ambiguous glyph away from a constructive one. One line-icon set, no emoji.

**Also inherited:** page-owned breadcrumbs deduplicated against the H1 (Amendment 5); filters
collapsed behind a Filters button with an active-VALUE count badge and removable chips; search
inline with the tab row; REQ-UI-5's disabled-not-hidden treatment; the loading/empty/failed
catalog states; `useInfiniteList` + `DataList` + `BulkActionBar` + `FilterBar` + `Breadcrumbs`;
"offer only the verbs that mean something in this state"; and `--text-page-title` for the H1
(never raise `--text-display`).

**"Where applicable" is a real clause, not a hedge.** A resource that genuinely cannot take part
of this must say SO AND WHY in its plan, rather than silently diverging or silently complying.
Known candidates: Shells has no markdown body and a live output stream, so rows 2-3 mean something
different there; Actions has no pagination (REQ-UI-6 waived); Agents shows durable identities with
instances on the view page. Tables are not dead chain-wide — Amendment 4's scroll region still
applies wherever a resource genuinely needs columns — but the DEFAULT is now this row.

## Amendment 7 — direct user instructions to the worker (recorded here so the other four inherit them)
These came from the user straight to the implementing agent, not through the coordinator. They
are binding and they supersede earlier text where they conflict.

- **The REQ-UI-5 explanatory Alert is REMOVED.** The "Showing search results across all memory.
  Tabs and filters don't apply while you're searching." banner goes. REQ-UI-5's *behaviour* is
  unchanged — a query still disregards filters — but the requirement that the UI SAY SO in prose
  is dropped. The remaining signals are the disabled-not-hidden filter chrome and the tab strip
  showing no selected tab. **Coordinator note:** this is the one amendment that removes a
  safeguard rather than adding one; if users are later surprised that filters stopped applying,
  this is the change to look at first.
- **No Select toggle, settled twice.** Checkboxes are ALWAYS visible on every viewport, so there
  is no select mode to enter and no toggle to press; the bulk bar appears as soon as a row is
  ticked. The user's earlier "ensure we still replace the select toggle button" meant REPLACED BY
  persistent checkboxes, not re-styled — confirmed by their later, explicit "Remove select button
  since we are always showing checkboxes". This supersedes REQ-UI-19's *mechanism* ("explicit
  select mode + bottom action bar") while SATISFYING its requirement: nothing is hover-revealed.
  Do not record REQ-UI-19 as dropped; record it as met by a simpler route.
- **"More" is an icon button**, not a labelled one.
- **Relative time is the LAST item in the pill row**, after the pills.
- **No emojis anywhere.** One line-icon set only.
- **Filters is an icon button immediately right of the search input.** Selected-filter chips and
  Clear filters sit BELOW the search bar.
- When handing the user a preview, give the **Heimdall preview URL**, not the raw local one.

Everything else in Amendments 1-6 stands.

## Amendment 12 (was a duplicate "Amendment 6") — conventions from the Memory redesign
Everything here was ruled by the user while clicking the live preview, or is the shape the
redesign settled on. Where it contradicts Amendment 11, the later ruling wins and is marked.

- **Resource lists are ROW lists, not column tables, and a row is FOUR LINES:**

      row 1   Title ...........................................  [ … ]
      row 2   body line 1
      row 3   body line 2
      row 4   [pill] [pill] [pill] ......................  12m ago

  Title truncates against the `…` trigger (needs `min-w-0`, or it pushes the trigger off). The
  body is clamped at **two** lines, and those two lines are **reserved even when empty** — derive
  the reserve from the type tokens, not a magic px — so a body-less row does not collapse and
  leave its pills a line high. **72px is a FLOOR, not the height**: Memory measures 135px. Measure
  yours; do not assert it. Dividers, hover surface, the row a real link. `DataList`'s table path
  stays in `@ui` and stays generic — Agents and Actions still need it, and Amendment 4's scroll
  region with it.
- **Meta line order: chips first, time LAST.** A timestamp between chips breaks the run the eye
  scans down.
- **No select MODE.** Checkboxes are persistent on every viewport; the bulk bar appears on the
  first tick. (Supersedes Amendment 5's select-mode entry point. REQ-UI-19 is satisfied more
  directly: nothing hover-revealed, nothing behind a mode.)
- **Icon-only is allowed for an OVERFLOW trigger on every viewport** (`ActionButton iconOnly`) —
  `…` is the convention and a text "More" reads as a verb it is not. Amendment 5's rule stands
  for everything else: verbs carry text labels on desktop, glyphs on touch, same accessible name.
- **The Filters control is an icon button immediately right of the search field**, with a count
  badge when filters are applied. Active-filter chips and **Clear filters** go on their own row
  directly under the search bar. (Refines Amendment 5's Filters button.)
- **Two-pane master/detail at >=1024 reuses the DETAIL ROUTE.** `#/resource/:id` renders
  list + pane at that width and the page below it, so one record never has two URLs. **The
  detail href carries the list's state** (tab, filters, query) — without it, opening a row
  resets the list underneath the user. Verify this; it is invisible until someone has filters on.
- **A detail view is surface cards**, with the card's affordance inline with its label, never on
  a row of its own. A rail (320px) for secondary cards when the pane is >=900px, else stacked.
- **If a verb appears in a sticky mobile bar, gate it OUT of the header, and vice versa.** Memory
  shipped Approve/Reject in both, putting two Approve buttons on one phone screen. A type checker
  cannot see this; only rendering the view at 390px does. Count the *visible* controls per width
  when you verify.
- **Do not render a field the API does not send.** No Created row while `created_at` is
  unserialised; no provenance badge while a record has no author field. A lifecycle state
  (`pending`) is not an author.
- **No tab count badges while the list APIs return no totals.** A loaded-row count is a number
  that looks like a total and is not.
- **A ROW CARRIES ONE `…` MENU AND NOTHING ELSE.** No inline verb buttons, no hover-revealed
  cluster, and **no swipe gesture**. All three were built on Memory and all three were cut by the
  user (*"Lets remove the button all together from the entries"*, *"hide the hover to show
  button"*, *"remove the slide for actions feature it doesn't work well on mobile"*). Verbs live
  in the row menu, in the bulk bar during selection, and in the detail header — nowhere else.
  **Inside the menu they are words, never bare glyphs**, so a destructive verb is read rather than
  guessed. Do not re-propose any of the three; see memory.md A2.10 for why each failed.
- **Tapping the `…` must not also open the row.** Ignore clicks originating inside the row's
  controls, and keep the title a real `<a>` so keyboard, middle-click and copy-link still work.
  Do **not** use a stretched-link overlay — it swallows affordances inside the row, such as a
  scope chip's `+N`.
- **Single-letter keyboard shortcuts** are ignored while typing in a field or while a modal is
  open, and a verb only fires when the focused row offers it.
- **Bottom clearance is measured, not guessed.** `--ui-bottom-chrome` + `env(safe-area-inset-bottom)`;
  no hard-coded `pb-20`. Persistent bottom chrome is solid, never a translucent blur.
- **No emoji, anywhere, ever.** One line-icon set. `MarkdownBody` was rendering 📋 on its copy
  button and 📎 on attachment chips; both are inline SVGs now. If a glyph is needed where only
  an HTML string can go, inline the SVG — do not reach for a character.
- **An explanatory paragraph is the weakest way to say something.** REQ-UI-5's banner was removed
  at the user's instruction; the behaviour it described is now SHOWN (no tab selected, the
  Filters control inert with a hover explanation). Prefer state a user can see over prose.

## Amendment 8 — multi-select scope filters are permanently off the table
The user CANCELLED the hub CSV fix (`task_18d76304913cd093`). So `memory_filter_query`
(`content_handlers.odin:689-697`) keeps returning only the FIRST token of a dimension filter,
and that is now a permanent constraint rather than a pending fix.

**Every resource's scope filters are SINGLE-SELECT.** Do not design a multi-select scope filter
for Projects, Agents, Actions or Shells, and do not send a multi-value CSV to a dimension filter
— the hub will silently honour one value, which is the exact bug the shipped Memory page had
(three chips displayed, one value applied). Single-select is the honest match to the endpoint.

Scope EDITORS on the write side remain multi-value: PATCH/POST genuinely accept lists. Only the
read-side FILTERS are constrained. Keep that distinction visible in any plan.

## Amendment 9 — agents are NOT scoped to a project
User ruling, applied on the Projects view page: the "Agents" / "Agent instances that have run on
this project" card is REMOVED. A project's linked resources are **Chains** and **Memories** only.

Do not reintroduce a project->agents relationship on any page. The durable `agent` identity has
no project dimension; only a running `agent_instance` carries a `project_id`, and that is a
runtime fact about a session, not a property of the agent. Listing instances under a project
invited the reading that agents belong to projects, which they do not.

**The reciprocal relationship is NOT symmetric, and that asymmetry is correct:**
- Project view -> Memories: YES (memory targeting has a project dimension).
- Project view -> Agents: NO.
- Agent view -> Memories: YES (memory targeting has an agent dimension) — the paginated section
  the user asked for, inherited from the Projects implementation.
So when building the Agents page, do not mirror the removal: the Memories section stays there.

## Amendment 10 — the build claim is `tsc -b --force`, and nothing else counts
`npx tsc --noEmit` WITHOUT `--project` does not resolve the same configuration as `tsc -b`, and a
file can be reported green by the former while failing the latter. This actually happened:
`shared/PaginatedMemoriesSection.tsx` called `list.isLoading` / `list.loadError` against a hook
exposing `isLoadingInitial` / `error`, was reported as "tsc --noEmit: exit 0" in the Agents
handoff, was approved on that basis, and left BOTH the Agents and Projects pages shipping a build
that did not compile. It was found by the next task's worker, not by review.

State the exact command and its exit code in every handoff. A build claim without the command is
not a build claim.

## Found defects OUTSIDE this chain's scope, recorded with causes so they are not rediscovered
Neither was fixed here. Both block an agent from reading a user-uploaded binary artifact.

1. **`ham-ctl artifact download --dir <existing dir>` always fails.** `src/ctl/agent_mode.odin:645`
   treats any non-nil from `os.make_directory_all` as fatal, and that call returns non-nil when the
   directory already exists. Succeeds only into a path that does not exist yet. Workaround: name a
   fresh subdirectory. Fix: treat already-exists as success.
2. **Binary artifact content is JSON-escaped and never unescaped.** A downloaded PNG begins
   `211 P N G \r \n u 0 0 1 a` — the `0x1A` byte written as the literal characters `u001a`. Every
   non-printable byte becomes escape text, so binary artifacts are corrupt byte-for-byte. Bug 1
   hides bug 2: fixing the directory check alone yields files that download cleanly and are still
   unreadable.
