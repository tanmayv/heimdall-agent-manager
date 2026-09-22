# UI plan — Memory pages (REFERENCE IMPLEMENTATION)

Phase 1 planning artefact for `chain_18d7584e33d47518`, task `task_18d7597dcfade667`.
Companion to `docs/ui-rebuild/00-ground-truth.md` (G-1..G-6, REQ-UI-1..21). Memory is the
reference resource: it is the only one exercising tabs, markdown, scope filters and a real
server search scope at once. The other four plans copy the shape set here.

**No page code is written by this task.** Everything below is a specification.

**Revision 3** (this document) — folds in the user's answers (`cmt_18d75a27815f37e3`): a
user-created memory is born **`active`** (U-1); the landing-tab heuristic is **confirmed**
(U-2); and archived memories get **their own tab**, making the tab set **Proposals · Active ·
Archived**. The third tab let me **delete the per-tab Status filter entirely**, which removes
the F-6 problem at its root rather than labelling around it — see §1. §13a is now empty.

**Revision 2** — revised after the coordinator's review `cmt_18d75a08ff212ac7`:
F-1 the Title cap is now declared a client-only convention (the hub imposes none) · F-2 a
rejected memory's verb is **Approve**, not "Restore", so it cannot silently skip approval ·
F-3 §4 names `DataList` · F-4 scroll restoration is capped and its fallback defined · F-5 an
explicit `?tab=` beats the landing heuristic · F-6 a tab label states it when its filter
changes what it contains. Plus the coordinator's earlier rulings: mid-scroll cursor behaviour
(§11), the list/search page-size seam (§3), BACKEND-DEP-1/2 and the gap register (§13), and
**Appendix A**, the conventions the other four plans inherit.

## 0. Verified source facts (everything in this plan rests on these)

Every claim below was read out of the checkout, not inherited from the task hints. Where a
hint or ground-truth line disagreed, the source wins and the divergence is called out.

| # | Fact | Source |
|---|---|---|
| F1 | `Memory` = memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, created_at, updated_at | `src/hub/domain/content.odin:48-68` |
| F2 | Targeting is a **list per dimension**, **empty = applies to all**, dimensions **ANDed** | `content.odin:50-56` (doc comment) |
| F3 | `Memory_Type` = Unknown, Fact, Habit, Episode, Expertise, Skill → wire `fact\|habit\|episode\|expertise\|skill`; `unknown` is rejected on write | `content.odin:5-43` |
| F4 | Status values are **`pending`, `active`, `rejected`, `archived`** — there is no `"proposed"`. Create defaults to `pending` | `content_service.odin:119,191,193,215` |
| F5 | Routes: `GET/POST /api/v1/memories`, `GET/PATCH /api/v1/memories/*`, `POST /api/v1/memories/*/{approve,reject,archive}`. **No DELETE exists** | `src/hub/app/wiring.odin:265-269` |
| F6 | List query params: `limit` (default **50**, max **200**), `cursor`, `status`, `type`, `agent_ids\|agent_id`, `project_ids\|project_id`, `bridge_ids\|bridge_id`, `template_ids\|template_id` | `content_handlers.odin:17-43` |
| F7 | A dimension filter matches when the memory's list is **empty (global) OR contains the value** | `content_service.odin:139-144,165-166` |
| F8 | **Only the FIRST CSV token of a dimension filter is used.** `memory_filter_query` splits on the first comma and returns that token | `content_handlers.odin:690-698` |
| F9 | Ordering is `ORDER BY updated_at DESC`; the keyset seek is `m.updated_at < cursor`; `next_cursor = <last row>.updated_at`. **The cursor is `updated_at`, not `created_at`** | `content_repo_sqlite.odin:31`, `content_service.odin:148-152`, `content_handlers.odin:40` |
| F10 | `has_more = len(rows) >= limit`; no total count anywhere | `content_handlers.odin:42` |
| F11 | The list also returns `owner_user_id='system'` memories, which are **read-only** — every write 403s *"system memories are read-only"* | `content_repo_sqlite.odin:31`, `content_service.odin:170,190` |
| F12 | `write_memory_json` emits memory_id, the 4 id arrays, type, status, title, description, `body_preview`(list)/`body`(detail), evidence, updated_at. It **omits `created_at` and `owner_user_id`** | `content_handlers.odin:590` |
| F13 | PATCH is presence-flagged (`has_*`): an absent field is untouched, a present empty one is cleared. Only `pending` or `active` memories may be PATCHed | `content_service.odin:70-89,168-188` |
| F14 | `POST …/approve` with a body applies edits **and** sets `active` in one call; with `{}` it only sets `active` | `content_service.odin:192-214` |
| F15 | `memory` is a valid search scope; search has **no facet** for scope/type/status | `domain/search.odin:11`, `search_service.odin:17-32` |
| F16 | Memory FTS indexes **`title` and `body` only** | `migrations/030_search_fts_all.sql:155-175` |
| F17 | A search hit = `{id,label,sublabel,score,route,parent,preview,matched_field}`; for memory `label = title or type`, `sublabel = "<type> · <status>"`, `route = '/settings/memory?memory_id='\|\|id` (**stale route**) | `search_handlers.odin:108-118`, `search_fts.odin:115-122` |
| F18 | Search limits: default 20, max 50, scan cap 200 | `search_service.odin:9-11` |
| F19 | Agents may only **propose**; approve/reject/archive are user-token operations ⇒ **a human approves** | `wiring.odin:402-405`, `ctl/hub_mode.odin:396-402` |
| F20 | `@ui` `patterns/ScopeField.tsx` already ships `ScopeEditor`(=`ScopeField`), `ScopeChips`, `useMemoryScopeCatalog`, `SCOPE_DIMS`, `MEMORY_TYPES`, `Targeting`, `emptyTargeting`, `targetingFromRecord` | `src/ui/components/ui/patterns/ScopeField.tsx` |
| F21 | Breadcrumbs are produced by the **app shell**, not by `PageShell` — `breadcrumbsFor(path)` + a local `Breadcrumbs` component | `shell/AppShell.tsx:255-277` |
| F22 | Live pages today are `/memory` and `/memory/:id` | `AppShell.tsx:1060-1063` |

**Divergences from the hints** (posted as a task comment while writing this):
`pending` not `proposed` (F4) · `created_at` and `owner_user_id` are not serialised (F12) ·
FTS covers title+body only (F16) · multi-value scope filters are silently truncated to one
value (F8).

Two further divergences I reported were **folded into the ground truth by the coordinator**, and this plan matches the amended text: **G-4** now states the cursor column
is per-resource and that memories key on `updated_at` (F9), and **REQ-UI-7** now reads
"bulk destructive action" — naming bulk **archive** (Active) and bulk **reject** (Proposals)
as memory's verbs (F5), and requiring partial-failure behaviour, which §6 specifies.

F8 is a **live bug in the page being replaced**: `MemoryPage.tsx` sends multi-select scope
facets as CSV (`memory.ts:124-133`), and the hub honours only the first id — the UI shows
three chips and filters by one. This plan fixes it by making scope filters single-select.

---

## 1. Tabs

**Three tabs**, backed by the `status` query param (F6). Each tab is exactly one status
query — no tab ever merges two, because the endpoint filters on a single status value (F6)
and merging would break keyset paging (F9).

| Tab | URL `tab=` | Query | Meaning |
|---|---|---|---|
| **Proposals** | `proposals` | `status=pending` | An agent proposed it and a human has not decided yet |
| **Active** | `active` | `status=active` | In force — the memories agents actually receive |
| **Archived** | `archived` | `status=archived` | Out of force, kept and restorable |

**`pending` now means exactly one thing: an agent proposed it and a human has not decided.**
Since U-1 makes a user-created memory `active` on creation (§7), nothing a user writes ever
lands in Proposals. That is what makes an empty Proposals tab the *good* state (§10) rather
than an ambiguous one.

### Where `rejected` lives — and why the Status filter is gone

The fourth status, `rejected`, lives **inside the Archived tab** as a second-level segmented
control:

> **Archived** ‹ **Archived** | **Rejected** ›   ← sub-control, `Archived` selected by default

Both are terminal: a memory under this tab is **out of force**, whichever of the two it is.
So the top-level tab's claim is true of everything it can show, and the sub-control's
selected option always names the exact status on screen. **Neither level can misdescribe its
contents** — which is the point.

**This deletes the per-tab Status filter of revision 2, and with it the F-6 problem.**
Revision 2 let Proposals show rejected rows and Active show archived rows, then papered over
it with a `Proposals · Rejected` tab label. With a real Archived tab that is unnecessary:
Proposals and Active are now **pure** — one status each, no status control, nothing to
qualify — and the only place two statuses meet is the tab whose whole meaning is "not in
force". A fix you can delete is better than a fix you have to explain, and this one is
deleted.

**Cost to the common path: none.** The Archived tab issues **no request until it is
selected**, carries **no count badge** (there are no totals anyway — F10), and the Rejected
sub-view issues no request until *it* is selected. A user who never archives anything never
pays for the tab.

### Landing-tab precedence — in this order, first match wins

1. **An explicit `?tab=` in the URL always wins.** A shared or bookmarked link must resolve
   to the same tab for everyone, every time. Without this rule a deep link would land
   differently depending on the recipient's own proposal queue, breaking REQ-UI-17.
2. Otherwise, **Proposals when its first page has at least one row** — a pending proposal is
   an inbox item that needs a human.
3. Otherwise, **Active**.

**Archived is never a landing tab**, and the probe asks about Proposals only. The probe is
read **once per page load** and never re-applied, so the tab cannot move under the user
(REQ-UI-20). **If the probe fails** (error or timeout) the page lands on **Active, silently**
— a failed probe is not worth an error banner. It never blocks first paint: the page renders
Active's skeleton and switches before data arrives, or stays put if the probe is slow.

Tabs carry **no counts** — the API returns no total (F10) and a "50+" badge is noise.

### Is "a dedicated tab per terminal state" a convention the other four inherit?

**No — this one is memory-specific**, and I agree with the coordinator's read. Memory has a
genuine four-state lifecycle with *two* terminal states and a human approval gate in the
middle; that is what earns a third tab. Projects have an `archived` state and could adopt the
same shape if their plan argues for it, but agents, actions and shells have no comparable
lifecycle, and forcing a terminal-state tab on them would mean inventing one.

**What the other four DO inherit** is the rule underneath it, which is general:
*a tab must never read as selected while the list shows rows that are not that tab's
subject.* Satisfy it by splitting the tab (memory's answer) or by not offering the control
that breaks it — never by qualifying the label after the fact. Appendix A carries it.

Satisfies REQ-UI-3.

## 2. Filters

All filters are **server-backed** — memory is the one resource where the list endpoint has
real facets (F6). Filters live in a filter bar under the tab strip; on mobile they collapse
into a `Drawer` (§5).

**There is no Status filter.** Status is wholly owned by the tab strip (§1) — three tabs plus
the Archived tab's Archived/Rejected sub-control cover all four statuses, and a filter that
could also change the displayed status is exactly what revision 2 had to apologise for.

| Filter | Control | Options | Default | Backing param |
|---|---|---|---|---|
| **Type** | `Select` (single) | `All types`, Fact, Habit, Episode, Expertise, Skill | `All types` (param omitted) | `type=` (F3/F6) |
| **Project** | `Combobox` (single) | the user's projects, from `useMemoryScopeCatalog()` | `Any project` (omitted) | `project_ids=` |
| **Agent** | `Combobox` (single) | the user's agent identities | `Any agent` (omitted) | `agent_ids=` |
| **Bridge** | `Combobox` (single) | the user's bridges | `Any bridge` (omitted) | `bridge_ids=` |
| **Template** | `Combobox` (single) | available templates | `Any template` (omitted) | `template_ids=` |

**The four scope filters are single-select, deliberately.** The hub uses only the first CSV
token per dimension (F8), so a multi-select control would lie about what is being filtered.
Single-select is the honest match to the endpoint. (Making them true multi-select is a
backend change — out of scope for this chain; recorded as a backend gap in §13c.)

**Scope filters are "applies to" filters, not "tagged with" filters.** Per F7 a memory
matches when its dimension list is empty OR contains the value — so picking *Project X*
returns memories scoped to X **and** the global memories that apply to X anyway. The filter
bar states this once, inline, so the result set is never surprising:

> Scope filters show memories that **apply to** the selection — including global memories.

A `Clear filters` text button appears whenever any of the five filters is off its default.
Changing tabs does **not** clear them: the filters are orthogonal to status, and a user who
has narrowed to one project expects that to survive a hop to Archived.

Satisfies REQ-UI-3, G-3 (no filter is pushed into search).

## 3. Search

**Server-scoped**, per REQ-UI-4 and G-2: `GET /api/v1/search?q=<q>&types=memory&limit=&cursor=`
(F15). Not client fuzzy — memory has a real scope, and the body text that makes a memory
findable is often not on the loaded page.

**Fields matched: `title` and `body` only** (F16). `description` and `evidence` are *not*
indexed. The search input's placeholder says so rather than letting the user infer that
search is broken:

> Search memory titles and bodies…

**REQ-UI-5 — query active ⇒ filters disregarded.** The moment `q` is non-empty the list is
served by `/api/v1/search`, which accepts no status/type/scope facet (F15). So tab and
filters cannot apply, and the UI says so visibly, in three places at once:

1. The filter bar is **disabled** (`disabled` on every control) and dimmed — not hidden, so
   the user can see what is being set aside and what it will return to.
2. An `Alert` (`tone="info"`, `emphasis="soft"`) sits between the search field and the
   results, reading:
   > **Showing search results across all memory.** Tabs and filters don't apply while
   > you're searching. *Clear search* to go back to **Active · Fact · Project Heimdall**.
   The trailing clause names the exact filter state being held, and *Clear search* is a
   button that empties `q` and restores it verbatim.
3. The tab strip shows a "Search" state: neither tab reads as selected, so the tab bar
   cannot imply a scope it is not applying.

Filter state is **preserved, never cleared** — it stays in the URL (§11) and comes back
untouched when `q` empties.

**Rendering search results.** A memory hit carries no structured type/status/scope (F17):
only `label` (title, or the type when the title is empty), `sublabel` (`"<type> · <status>"`),
`preview` (the matched snippet) and `matched_field`. Two consequences, both settled here:

- The results list renders a **distinct, simpler row**: title, the type and status parsed
  from `sublabel` as `Badge` + `StatusPill`, and the `preview` snippet with the matched
  term highlighted. No scope chips, no per-row edit — the data is not in the response.
- **Bulk select is disabled in search results** (an archive/reject needs a status the hit
  does not reliably carry). The results row is a navigation target; the user opens the
  memory to act on it. The `Alert` above already explains that search is a different mode.

**Do not follow `hit.route`** — it points at `/settings/memory?memory_id=…`, a stale route
(F17/F22). The row navigates to `/memory/<hit.id>`, built from the id.

**The two data paths have different page sizes, and the user sees the seam.** The list
endpoint pages at `limit=50` (F6: default 50, max 200); the search endpoint's max is **50**
(F18: default 20, max 50), so search is requested at 50 to match. The sizes therefore agree,
but the *paths* do not: search re-ranks by bm25 rather than `updated_at`, so the moment a
query becomes non-empty **the list is replaced, not filtered** — different rows, a different
order, and a different row shape (the reduced row above).

What the user sees at that moment, specified so it does not read as a glitch: the search
input is **debounced 250ms**; on the first keystroke the list keeps the rows it has and dims
them to 60% with the skeleton's shimmer suppressed; when results arrive they **replace** the
list in one paint, with the REQ-UI-5 `Alert` already in place above them. The scroll position
resets to top — it must, since the rows are different — and clearing the query restores the
filter state and re-fetches the list from page one. No partial blend of search hits and list
rows is ever rendered.

Search pages with its own cursor on the same infinite scroll as §4.

Satisfies REQ-UI-4, REQ-UI-5, G-2, G-3.

## 4. List columns (desktop)

> **SUPERSEDED by Amendment 2 (A2.1).** The column table described below was never shipped —
> the redesign replaced it with a four-line row list on every viewport, and there are no
> columns on this page any more. This section is kept because §12's `DataList` reasoning and
> the column-by-column rationale still apply to **Agents and Actions**, which do carry columns.
> Read it as "how a column table should be built here", not as a description of Memory.

Desktop is a **row list with columns** (REQ-UI-2), rendered by **`DataList`** — the proposed
`@ui` composite of §12, which wraps `@ui` `Table` and adds the selection model, the row click
target, the per-row action slot and the ≤767px card fallback that `Table` does not have.
Implementers reach for `DataList`, **not** `Table` directly. Ordered left to right:

| # | Column | Source field | Notes | Mobile priority |
|---|---|---|---|---|
| 1 | *(select)* | — | `Checkbox`, 44px hit area; header checkbox selects the loaded page | **5** (select mode only) |
| 2 | **Title** | `title`, falling back to the first line of `body_preview` when empty | The link to `/memory/:id`. Bold, truncates at one line | **1** |
| 3 | **Type** | `type` | `Badge`, one of the five (F3) | **2** |
| 4 | **Status** | `status` | `StatusPill` — Pending (warning) / Active (success) / Rejected (danger) / Archived (neutral). Rendered in every tab, because the Status filter can put `rejected`/`archived` rows in view | **3** |
| 5 | **Scope** | `agent_ids` / `project_ids` / `bridge_ids` / `template_ids` | `ScopeChips` **compact** (F20): narrowed by nothing → a single **Global** chip; narrowed → only the chips that narrow it, plus one muted "all other scopes". One line, `max` 3 + "+N" | **4** |
| 6 | **Updated** | `updated_at` | Relative ("2h ago"), absolute on `title=`. This is the sort key (F9) | **7** |
| 7 | *(row actions)* | — | §6 | **8** (moves into the card's overflow menu) |

**No "Summary" column** (user decision, applied). It carried a truncated one-line prose
summary next to the title and earned less than the space it cost; the description is one tap
away on the view page. It was already dropped from the mobile card, so this removed it from
desktop too. Generalised in Appendix A.

**Scope is one line, not four chips.** Every row previously stacked "All projects" / "All
agents" / "All bridges" / "+1" — identical on every row, three lines of row height spent
saying nothing distinguishing. The compact variant keeps the empty=applies-to-all meaning
explicit ("Global" and "all other scopes" both read as deliberate statements, which a blank
cell would not) at one line. The **view page** keeps `variant="full"`, where every dimension
states itself, because there the question really is "what exactly does this apply to?".

**No "Created" column.** `created_at` is not serialised (F12), and no column here needs it —
**Updated** is the meaningful date for a memory and is also the sort key. Ruled on; not
requested as backend work (§13d).

Ordering is **`updated_at` DESC** (F9) — most recently touched first — and is **not
user-sortable**: the keyset cursor is `updated_at`, so any other sort would break paging.
The column header says "Updated ↓" as a static, non-interactive indicator.

**Infinite scroll only** (REQ-UI-6): `limit=50` (F6), `cursor = next_cursor`, stop when
`has_more` is false (F10). No page numbers, no *Load more*, no totals anywhere on the page —
including no count badge on the tabs (§1).

## 5. Mobile model (≤767px)

> **SUPERSEDED by Amendment 2 (A2.1).** There is no longer a separate mobile card model: the
> SAME four-line row renders at every width, so mobile and desktop cannot drift apart. The
> two-rows-of-text card below is the ancestor of that row, not a second layout.

Below `MOBILE_MAX` (767, `shell/responsive.tsx`) the table is replaced by a **card list**.
Two rows of text per card, ~72px tall, full-width tap target to `/memory/:id`.

```
┌──────────────────────────────────────────────┐
│ ▢  Prefer nix develop for odin builds        │  ← line 1: Title (2-line clamp)
│    [fact]  ● Active                     2h   │  ← line 2: Type · Status · Updated
│    All projects · worker #37 · +2            │  ← line 3: scope, one line, elided
└──────────────────────────────────────────────┘
```

Exact fields shown, in priority order (matching the table's mobile-priority column):

1. **Title** — the only thing that gets two lines. Falls back to the first line of `body_preview`.
2. **Type** — `Badge`, compact.
3. **Status** — `StatusDot` + short label. Kept on mobile because the Status filter can
   surface rejected/archived rows, and a card with no status is unreadable then.
4. **Scope** — a single elided line of compact `ScopeChips`: at most 2 chips, then `+N`.
   A memory narrowed by nothing reads **Global**; a narrowed one shows what narrows it plus
   "all other scopes". The empty≠none distinction survives the squeeze, because it is the one
   thing about memory a user can misread destructively.
5. **Select checkbox** — leading, **only in select mode** (§6, REQ-UI-19).
6. **Summary** — **dropped everywhere** (it was dropped on mobile first, then on desktop —
   §4). The title plus scope is what identifies the memory; the description is one tap away.
7. **Updated** — relative, right-aligned on line 2.
8. **Row actions** — a `⋯` icon button at the card's trailing edge opening a `Menu`
   (Edit / Approve / Reject / Archive as §6 allows), because hover-reveal is unreachable
   on touch. Icon-only is the MOBILE rendering of `ActionButton`; the same actions carry
   visible text labels on desktop (**Edit**, **More**) — user ruling, and the rule lives in
   `@ui/composites/ActionButton` so no page decides it twice.

**Filters move into a `Drawer`** opened by a `Filters` button with a dot when any filter is
off its default — now on **every** viewport, not only mobile (see Appendix A). Tabs stay a
visible segmented control — the proposals/active split is the primary navigation and must not
hide behind a drawer. The search field is **inline with the tab row**, not a full-width band
above it; as its own band it outweighed the tabs.

`useKeyboardInset()` lifts the bottom action bar above the software keyboard, and
`--ui-bottom-chrome` lifts it above the app's persistent `MobileTabBar` — without the second
one the bulk verbs render *behind* the tab bar and bulk select is unusable on mobile.

Satisfies REQ-UI-13, REQ-UI-19.

## 6. Row actions, bulk actions, destructive flow

> **PARTLY SUPERSEDED by Amendment 2 (A2.3).** The per-status verb table below is still the
> source of truth for **which** verbs a status offers — `verbsForStatus` in `memoryModel.ts`
> implements exactly it. What changed is **where** they appear: a row no longer renders verb
> buttons at all. Every verb lives in the row's `…` menu, in the bulk bar during selection, or
> in the detail header. Read the table for the verb set; read A2.3 for placement.

**The verbs that exist** (F5): PATCH (edit), `approve`, `reject`, `archive`. **There is no
delete.** "Archive" is the soft-delete the current UI already performs behind a button
labelled *Delete* (`MemoryPage.tsx:86`) — this plan stops mislabelling it.

### Row actions (per status)

| Status | Actions |
|---|---|
| `pending` | **Approve** · **Reject** · **Edit** (Edit opens the form; from a proposal, Save uses `POST …/approve` with the edited body so "approve with my corrections" is one call — F14) |
| `active` | **Edit** · **Archive** |
| `archived` | **Restore** (`POST …/approve`, which sets `active` without a status precondition — F14). "Restore" is the honest word: the memory *was* active, and this puts it back |
| `rejected` | **Approve** (the same `POST …/approve` call). **Not** labelled "Restore" — see below. No Edit: PATCH refuses a non-pending/active memory (F13) |

**Why a rejected memory's verb is "Approve", not "Restore".** `approve_memory` with no edits
is `update_memory_status(…, "active")` with **no status precondition**
(`content_service.odin:191`), so the call succeeds from `rejected` just as it does from
`archived`. But the two mean different things. An archived memory was in force before, so
restoring it returns it to a state a human already sanctioned. A **rejected proposal never
was**: a human looked at it and said no, and sending it to `active` puts it into force
**without ever passing through the approval that `pending` exists to enforce**. Calling that
"Restore" hides the consequence behind a word that sounds like an undo. **Approve** says what
actually happens — the human is approving something they previously rejected — and it is the
same single click either way.

**There is no route back to `pending`.** The only status routes are approve / reject /
archive (F5), and `update_memory_status` is not otherwise exposed, so a rejected proposal
cannot be returned to the queue for someone else to judge: it can only be approved outright
or left rejected. Recorded in §13c as a backend gap.

**An asymmetry an implementer will trip on:** `approve_memory` **with** edits also has no
status precondition (`content_service.odin:195-214`), so a "Save & approve" from a `rejected`
memory would succeed at the API level — even though the plain PATCH path refuses it (F13, §7).
The UI must therefore not lean on the API to enforce §7's gate: it offers no edit affordance
on a rejected row at all, which is why that row's only verb is Approve.

Desktop shows Edit as a persistent `IconButton` in the row (REQ-UI-2 requires a per-row edit
action); everything else lives in a `⋯` `Menu`. Mobile puts all of them in the `⋯` menu.

### System (read-only) memories

A **system memory** (F11) is returned by the list like any other but rejects every write with
403 *"system memories are read-only"*. The page is designed **as if the payload carries a
read-only signal**, with a defined degraded mode for shipping before it does
(**BACKEND-DEP-1**, §13):

| | Behaviour |
|---|---|
| **Designed** (signal present) | Row and view page render **read-only**: no Edit, no Archive, no bulk checkbox. A `Badge` reads **System**; the view page carries an `Alert` — *"This is a built-in memory. It applies to every agent and can't be edited or archived."* Select-all skips these rows, so a bulk archive can never partly fail on them |
| **Degraded** (signal absent — Phase 1) | The actions render, the write is attempted, and the 403 surfaces as a `Toast` in the server's own words: *"System memories are read-only."* In a bulk run these rows land in the partial-failure count (*"10 archived, 2 failed"*) and stay selected |

Read-only-ness is **never guessed client-side** from a heuristic such as an id prefix: the
degraded mode's honest 403 is better than a wrong guess that hides a real memory's actions.

### Bulk actions (REQ-UI-7)

Checkbox multi-select, with the bulk bar scoped to what the current tab can do:

| Tab / status | Bulk actions |
|---|---|
| Proposals (`pending`) | **Approve selected** · **Reject selected** |
| Proposals (`rejected`) | **Approve selected** (not "Restore" — see the row-action note above) |
| Active (`active`) | **Archive selected** |
| Active (`archived`) | **Restore selected** |

**Bulk reject of proposals is the headline case** the user called out, and it is the one
bulk action reachable in two taps: select-all on the Proposals tab → *Reject selected*.

The header checkbox selects **the rows currently loaded**, never "all matching" — there is
no total and no bulk endpoint (F5/F10), so "all" would be a promise the API cannot keep.
The bar therefore reads *"12 selected (of the 50 loaded)"*, never *"of 340"*.

**Touch (REQ-UI-19):** a **Select** button in the page header enters select mode; checkboxes
appear leading each card and a **bottom action bar** slides up with the verbs plus a count
and *Cancel*. No hover is involved on any viewport — desktop checkboxes are persistent, not
hover-revealed.

### Destructive confirm flow (REQ-UI-18)

| Action | Flow |
|---|---|
| **Approve** (single or bulk) | No confirm. It is constructive and reversible by Archive |
| **Restore** | No confirm. Constructive |
| **Reject** — single | No confirm. `Toast` with **Undo** (5s) that calls `POST …/approve`. Rejecting one proposal is cheap and frequent |
| **Reject** — bulk | **`Modal` confirm**, naming the count and the first three titles: *"Reject 12 proposals? They'll stay in the Rejected filter and can be restored."* Confirm button `tone="danger"`, labelled **Reject 12** |
| **Archive** — single | **`Modal` confirm**: *"Archive "Prefer nix develop for odin builds"? Agents will stop receiving it. You can restore it from the Archived filter."* Button **Archive** |
| **Archive** — bulk | Same modal, pluralised and count-labelled: **Archive 12** |

Archive always confirms because it **changes agent behaviour** — an archived memory stops
being injected into agent bootstrap (`content_repo_sqlite.odin:24-25` invalidates the
bootstrap cache on every memory write). Reject does not: a pending proposal was never in
force.

**Undo, not confirm,** is used only for single reject, where the blast radius is one row and
the reverse call exists. Bulk anything confirms — an N-row mistake is not undoable in one tap.

**Nothing is destroyed.** Because there is no DELETE (F5), no memory is ever permanently
removed from this UI, and no other resource loses a reference: a memory *points at* agents /
projects / bridges / templates, and nothing points back at a memory. So REQ-UI-18's
"what happens to referencing resources" is: **nothing references a memory**; archiving one
only removes it from the four dimensions' bootstrap injection. The confirm copy says exactly
that ("Agents will stop receiving it").

Failures are surfaced per-row: a bulk run reports *"10 archived, 2 failed"* in a `Toast`, and
the failed rows stay selected so the user can retry only those.

## 7. Add / edit form

**One page serves create and edit** (REQ-UI-8/9): `/memory/new` and `/memory/:id/edit`, a
full page reached from a single **New memory** `Button` (`variant="primary"`) at the top
right of the list. Not a modal — the current UI's create modal goes away.

Layout: one column, `FormField` per field, `max-width: content`.

| # | Label | Input | Required | Validation | Exact error message | Immutable on edit | Endpoint field |
|---|---|---|---|---|---|---|---|
| 1 | **Title** | `Input` | No | ≤200 chars, trimmed — **client-only, see below** | *"Title must be 200 characters or fewer."* | No | `title` |
| 2 | **Type** | `Select` | **Yes** | one of fact / habit / episode / expertise / skill; `unknown` is rejected by the hub (F3) | *"Choose a memory type."* | No | `type` |
| 3 | **Description** | `Textarea` (3 rows) | No | — | — | No | `description` |
| 4 | **Body** | `Textarea` (12 rows, monospace, markdown) | **Yes** | non-blank after trim — the hub's only hard rule (F13) | *"Body is required — this is the text your agents will read."* | No | `body` |
| 5 | **Evidence** | `Textarea` (4 rows) | No | — | — | No | `evidence` |
| 6 | **Scope → Projects** | `ScopeField` dimension, multi-select `Combobox` | No | each id must be a project the user owns | *"That project no longer exists. Remove it and try again."* (from the hub's `project not found`) | No | `project_ids` |
| 7 | **Scope → Agents** | same | No | id must be an owned agent | *"That agent no longer exists. Remove it and try again."* | No | `agent_ids` |
| 8 | **Scope → Bridges** | same | No | id must be an owned bridge | *"That bridge no longer exists. Remove it and try again."* | No | `bridge_ids` |
| 9 | **Scope → Templates** | same | No | id must be an available template | *"That template no longer exists. Remove it and try again."* | No | `template_ids` |

**Every rule in that table is a server rule except the Title cap.** The hub validates exactly
two things on write — `body` non-blank and `type != Unknown` (`content_service.odin:119`,
`:168-188`) — plus the status gate and the four target-id existence checks. There is **no
length limit on `title` anywhere** in the hub. (The only title cap in that file is
`update_conversation_title`'s 120 at `:220`, which is a different resource.)

The 200-char cap is therefore a **client-only convention**, declared as one so no implementer
reads it as an API contract. It exists because `title` is a display string in four places
that all truncate — the list row, the mobile card, the breadcrumb, and the search `label`
(F17) — and a 2,000-character "title" pasted from a body degrades every one of them while
being invisible to the author. The cap is a **soft guard at the input**, not a gate: it is
enforced on the form only, the server would accept more, and nothing in the view or list path
rejects an over-long title that got in by another route (the API, `ham-ctl`, an agent).

**Convention for the other four resources: 200 characters, client-side, on any single-line
display-name field** — `title`, `name`, `label`. It is one number, applied once, so the five
pages do not each invent their own. Any resource whose server *does* impose a cap uses the
server's number instead and says so.

`memory_id`, `status`, `owner_user_id`, `created_at`, `updated_at` are **never form fields**.
`status` is moved only by §6's verbs; the rest are server-owned.

**Immutability.** Nothing in the form is immutable on edit — the hub's PATCH accepts every
one of these nine fields (F13). What *is* gated is the record itself: **only `pending` and
`active` memories can be edited** (F13). The edit route for an `archived`/`rejected` memory
renders the form read-only with an `Alert`: *"Rejected memories can't be edited. Restore it
first."* plus a **Restore** button. This is REQ-UI-21's create-vs-edit difference for this
resource, and it is a *record-level* gate rather than a field-level one.

### Expressing "applies to all" vs "these three" — the central problem

The four dimensions are ANDed lists where **empty means "applies to all"** (F2). An empty
multi-select that silently means "everything" is the single most dangerous ambiguity on this
page: it reads as "nothing selected" and means "the whole fleet".

The form resolves it with **three reinforcing signals, no new control**:

1. **The empty-state placeholder is the meaning, not an instruction.** Each `Combobox`
   placeholder is `SCOPE_DIMS[].allLabel` — literally **"All projects"**, "All agents",
   "All bridges", "All templates" (F20). An empty dimension never reads as "Select
   projects…" or "None".
2. **A live, plain-English scope sentence** sits directly under the four controls and
   restates the current selection as one sentence, updating on every change:
   > This memory applies to **all projects**, agents **worker #37, reviewer #4**, **all
   > bridges**, and **all templates**.
   With nothing selected anywhere it reads, in `tone="warning"` `Alert`:
   > **This memory applies to every agent, on every project, bridge and template.**
   > Narrow it below if that's not what you want.
   The AND is carried by the sentence's grammar — one sentence, four clauses, all of which
   must hold — which is what the backend actually does (F2).
3. **A per-dimension `Clear` affordance** ("×" on the control) whose tooltip is
   *"Clear — applies to all projects"*, so removing the last chip announces its consequence
   at the moment it happens rather than after.

No "Apply to all / Apply to specific" radio pair is proposed. It would add a second source
of truth for a state the list already encodes (radio=all + a non-empty list is an
unrepresentable state the form would then have to police), and `ScopeField` — which already
renders "All projects" for empty in both edit and read (F20) — would have to be forked.
The warning `Alert` covers the only genuinely risky case: nothing selected anywhere.

### Save behaviour

| | Create | Edit |
|---|---|---|
| Call | `POST /api/v1/memories` | `PATCH /api/v1/memories/:id` (F13) — or, **from a `pending` memory, `POST /api/v1/memories/:id/approve` with the edited body** (F14), which saves the edits and approves in one call |
| Status | Server defaults to `pending` (F4) — a user-created memory **is a proposal** until approved | unchanged by PATCH |
| Buttons | **Create memory** | **Save changes**; on a proposal, a second `variant="primary"` **Save & approve** sits beside it |
| After save | Navigate to `/memory/<memory_id>` (REQ-UI-10) | Same |

Because create yields a **proposal** today, the create page carries a one-line note under the
header — *"New memories start as proposals and need approving before agents receive them."* —
and the post-save view page opens on the Proposals side of the world.

⚠ **This is the branch awaiting the user (U-1, §13a).** The coordinator recommends that a
memory the user writes in the UI be created **`active`** instead — `POST /memories` accepts a
`status` (F6), so it is one line, and making someone approve their own memory is ceremony.
§13a carries both branches with the exact copy each uses. Nothing else in the plan moves
either way.

**Unsaved-changes guard (REQ-UI-21):** any edit to any of the nine fields marks the form
dirty; leaving via breadcrumb, browser back, tab close or in-app navigation raises a `Modal`
— *"Discard your changes to this memory?"* / **Discard** (danger) · **Keep editing**.

**Server validation errors mapped onto the field (REQ-UI-21).** The hub returns a single
message; the client maps it to the offending control rather than dumping it in a banner:

| Server message | Field | Rendered as |
|---|---|---|
| `memory body is required` | Body | field error, verbatim rule in the row above |
| `memory type is invalid` | Type | *"Choose a memory type."* |
| `agent not found` / `project not found` / `template not found` / `bridge not found` | the matching Scope dimension | *"That {agent\|project\|template\|bridge} no longer exists. Remove it and try again."* + the control opens |
| `only pending or active memories can be updated` | form-level | `Alert` + Restore button (above) |
| `system memories are read-only` | form-level | `Alert`, form disabled |
| anything else | form-level | `Alert` with the server text, via `memoryErrorText()` (already exists, `memory.ts:78-101`) |

The first failing field is focused and scrolled into view.

## 8. View page — `/memory/:id`

**Read-only** (REQ-UI-11). Every mutation is either a §6 verb in the header or a trip to
`/memory/:id/edit`.

Header: title (or *"Untitled {type} memory"*), a `Badge` for type, a `StatusPill` for
status, and the §6 action set for that status — Edit · Approve · Reject · Archive · Restore.

| Section | Contents | Markdown? |
|---|---|---|
| **Summary** | `description` | **Yes** — `MarkdownBody` |
| **Body** | `body` — the text agents actually receive; the page's centre of gravity | **Yes** — `MarkdownBody` |
| **Evidence** | `evidence`, in a bordered `Panel` with a muted heading; the section is hidden when empty | **Yes** — `MarkdownBody` |
| **Scope** | `ScopeChips` (F20), one row per dimension, empty dimensions reading **"All projects"** etc. | No |
| **Details** | Type, Status, Memory ID (with copy), Updated (absolute + relative) | No |

**Markdown fields are `description`, `body` and `evidence`** — the three free-text fields.
`title` is plain text (it is a row label and a search `label`). This matches how agents author
them: `ham-ctl memory propose` takes `--body`/`--description`/`--evidence` as prose.

### Linked resources (REQ-UI-12)

A memory links **outward only** — to the four targeting dimensions. Nothing links back
(see §6). Each link set is rendered as a list of named, navigable chips, resolved id→name
through `useMemoryScopeCatalog()` (F20):

| Link set | Source field on the memory | Endpoint the names/links come from |
|---|---|---|
| **Projects** | `project_ids` | `GET /api/v1/projects` (`useListSidebarProjectsQuery`) → `/projects/:id` |
| **Agents** | `agent_ids` | `GET /api/v1/agents` (`useListAgentIdentitiesQuery`) → `/agents/:id` |
| **Bridges** | `bridge_ids` | `GET /api/v1/bridges` (`useListBridgesQuery`) → `/settings/bridges` |
| **Templates** | `template_ids` | `GET /api/v1/agent-templates` (`useListAgentTemplatesQuery`) → `/settings/templates` |

An **empty** dimension renders the explicit *"All projects"* chip — not an omitted section —
because "applies to everything" is the most important thing this page can tell the user.
An id that the catalog cannot resolve renders the raw id with a muted *(not found)* suffix
rather than disappearing.

## 9. Breadcrumbs (REQ-UI-14)

| Page | Trail |
|---|---|
| List | `Memory` |
| View | `Memory` › `<title or "Untitled memory">` |
| Add | `Memory` › `New memory` |
| Edit | `Memory` › `<title>` › `Edit` |

Every crumb but the last is a link; `Memory` returns to `/memory` **with the last-used tab
and filters restored from the URL** (§11), so drilling in and back out on mobile never loses
the list state.

Breadcrumbs are emitted by the **app shell**, not by the page: `breadcrumbsFor(path)` in
`AppShell.tsx:255-273` already handles `/memory` and `/memory/:id` — today it renders a
static `Detail` crumb. It needs two changes, both inside the existing function:
the detail crumb must carry the memory's **title** (the shell must read it from the memory
cache by id, as the chain routes already do for chain ids), and `/memory/new` and
`/memory/:id/edit` must be added. No new component; `Breadcrumbs` already exists
(`AppShell.tsx:276`).

## 10. Empty / loading / error copy (REQ-UI-16)

**Loading** — a skeleton, never a spinner, and never a layout shift: 8 skeleton rows at the
table's exact row height (8 skeleton cards on mobile), with the tab strip, search field and
filter bar already interactive. Paging in more rows shows a 3-row skeleton at the list foot;
the rows above never move.

**Empty** — four distinct states. First-run-empty and no-results are deliberately different
copy, as required:

| State | Condition | `EmptyState` icon / title / description / action |
|---|---|---|
| **First run** | Active tab, no filters, no query, zero rows | `spark` · **No memories yet** · "Memories are durable facts, habits and skills your agents carry between sessions. Create one, or let an agent propose it." · **New memory** |
| **No results for filters** | any filter off its default, zero rows | `filter` · **No memories match these filters** · "Try a broader type, or clear the scope filters — global memories show under every scope." · **Clear filters** |
| **No results for query** | `q` non-empty, zero hits | `search` · **No memories match "{q}"** · "Search covers memory titles and bodies. Try a shorter phrase." · **Clear search** |
| **No proposals** | Proposals tab, no filters, zero rows | `check` · **No proposals waiting** · "When an agent proposes a memory, it lands here for you to approve." · *(no action button — this is the good state)* |

The distinction that matters: *No memories yet* invites creation; *No memories match* blames
the filters, not the user's data, and hands back the control that caused it.

**Error** — an `Alert` (`tone="danger"`) in place of the list: **Couldn't load memories** ·
the server message via `memoryErrorText()` · a **Retry** button. A failure while paging does
**not** replace the loaded rows: it appends an inline error strip with **Retry** at the list
foot, so scrolling never destroys what the user already has.

Per-page: the **view** page 404s to `EmptyState` *"That memory doesn't exist"* + *Back to
Memory*; the **edit** page reuses the same, plus the status-gate `Alert` from §7.

## 11. URL parameter scheme (REQ-UI-17)

All list state lives in the URL, so back/forward and deep links work — critical for the
mobile drill-down (list → view → back).

```
/memory?tab=proposals&status=pending&type=fact&project=proj_1&agent=agt_2&bridge=brg_3&template=tpl_4&q=nix
/memory/:id
/memory/:id/edit
/memory/new
```

| Param | Values | Default (omitted when default) |
|---|---|---|
| `tab` | `proposals` \| `active` | resolved per §1 |
| `status` | `pending` \| `active` \| `rejected` \| `archived` | the tab's own status |
| `type` | the five type strings | omitted = all |
| `project`, `agent`, `bridge`, `template` | one id each | omitted = any |
| `q` | free text | omitted |

Short UI-facing names (`project`) map to the API's `project_ids` at fetch time; the URL is
for humans, and the single-value form is honest about F8.

**Cursors are never in the URL.** The cursor is an `updated_at` timestamp (F9) — it goes
stale the instant any memory is edited, and a shared link carrying one would land on a page
of rows that no longer exists.

**Scroll restoration is by remembered row id, and it is bounded.** On back-navigation the
list re-fetches from page one and re-pages looking for the remembered row id, stopping at
**whichever comes first: 5 pages (250 rows), or the end of the list.** The cap matters
because `updated_at` ordering (F9) means the remembered row may have moved, or may have left
the filter entirely (archived, approved out of the Proposals tab) — without a cap the
restore loop would page the whole table and still not find it.

| Outcome | Behaviour |
|---|---|
| Row found within the cap | Scroll to it, no message |
| Row not found within 5 pages | **Land at the top** of the restored list, with the 5 pages already loaded. A one-line `Text` note above the list reads *"Couldn't find where you were — showing the top of the list."*, dismissed by the next scroll |
| Row found but its status no longer matches the tab/filter | Treated as not-found: land at top with the same note |

The user **is** told, because silently landing somewhere other than where they left is more
disorienting than a line of text explaining it.

**A row's `updated_at` can change mid-scroll**, while a keyset window is open. Because the
cursor is the last row's `updated_at` and the seek is strictly `<` (F9), an edit that moves a
row above the cursor makes the next page **skip** whatever row took its place; an edit that
moves a row below the cursor can make it **repeat**. The chosen behaviour: **accepted, and
made harmless rather than prevented.** Repeats are de-duplicated client-side by `memory_id`
before append — so a repeat is never visible. A skipped row is **not** chased: it is a rare
consequence of someone editing memory during someone else's scroll, and the "N new or
updated" pill below is the recovery path, since applying it re-fetches from page one. This
is documented rather than engineered around: the alternative (an offset or a snapshot
cursor) does not exist in the API (F9).

*(Related: the same `<` comparison means **memories sharing an identical `updated_at` at a
page boundary are dropped** — the seek skips forward until a row is strictly older. Rare at
second-or-finer timestamps, but it is a hub-side keyset flaw, not a UI one. Recorded in §13c
as a backend gap.)*

Filter/tab/query changes `replace` the URL; opening a memory `push`es, so back returns to the
list rather than walking the filter history.

**Convention for the other four resources:** remembered-row-id restoration, capped at 5
pages, landing at top with a note when the row is gone; cursors stay out of the URL.

**Live updates (REQ-UI-20).** Memory has no WS stream (unlike agents/shells), so the list
refreshes on RTK Query tag invalidation after a mutation and on window refocus. Because the
sort key is `updated_at` (F9), **any approve/edit moves that row to the top** — a silent
reorder under the user's finger, and exactly what REQ-UI-20 forbids. So: rows already
rendered **hold their position** for the life of the view; new or moved rows surface as a
**"N new or updated — refresh"** pill at the top of the list, applied only on tap. A row the
user just acted on updates **in place** (its new status badge appears where it already sits)
and does not jump.

## 12. `@ui` components used, and what's missing

**Used — all existing (G-1), no second library:**

`PageShell` · `Tabs` (`Tabs.List` / `Tabs.Tab`) · `Table` · `Panel` · `SectionHeader` ·
`EmptyState` · `Alert` · `Modal` (+ `ModalBody` / `ModalFooter`) · `Drawer` (mobile filters) ·
`Menu` (row overflow) · `Toast` (undo, bulk results) · `FormField` · `Input` · `Textarea` ·
`Select` · `Combobox` (multi in the form, single in the filters) · `Checkbox` · `Button` ·
`IconButton` · `Badge` · `StatusPill` · `StatusDot` · `Text` · `Link` · `Icon` · `Spinner`.

**Patterns:** `ScopeField` — i.e. `ScopeEditor` for §7, `ScopeChips` for §4/§5/§8,
`useMemoryScopeCatalog` for §2's filter options and §8's id→name resolution, `SCOPE_DIMS`
and `MEMORY_TYPES` for labels (F20). **This resource needs no new scope component**; the
existing pattern already encodes "empty = All <dimension>" in both read and edit.

**Outside `@ui`:** `Markdown` / `MarkdownBody` (G-5) and `shell/responsive.tsx`
(`useIsMobile`, `useKeyboardInset`, `TOUCH_TARGET_CLASS`).

**Gaps — proposed only because nothing existing fits.** Each is generic, so each is a
candidate for all five resources, which is the point of memory going first:

| Proposed | Why nothing existing fits |
|---|---|
| **`useInfiniteList` hook** (not a component) | REQ-UI-6 needs keyset paging + an `IntersectionObserver` sentinel + "hold position, show N-new" (§11). Nothing in the repo does this — a grep for `IntersectionObserver` finds only `styles.css` and `ProjectVcsPanel`. All five resources need the identical behaviour. |
| **`DataList`** — the responsive list shell | `Table` renders a plain `<table>` with no row selection, no row click target, no per-row actions slot and no mobile fallback (`Table.tsx:49-60`). §4/§5 need one component that is columns on desktop and cards at ≤767px, with a shared selection model. Proposed as a composite that **wraps** `Table` + `Checkbox`, not a replacement for it. |
| **`BulkActionBar`** | The sticky/bottom-docked selection bar of §6 (count, verbs, cancel, `useKeyboardInset`) exists nowhere. REQ-UI-7/19 require it on all five resources. |
| **`FilterBar`** | §2/§3 need a filter row that is a `Drawer` on mobile and can be **disabled wholesale** with the REQ-UI-5 explanation. Assembled from `Select`/`Combobox`/`Drawer`/`Alert`; the assembly is what repeats. |
| **`Breadcrumbs` promoted into `@ui`** | It exists but is private to `AppShell.tsx:276` (F21). REQ-UI-14 makes it every page's contract on all five resources, so it belongs in `@ui/composites` with `PageShell` taking a `breadcrumbs` prop. |

Two notes for the reviewer, neither a proposal to change anything in this chain:
`patterns/ScopeField.tsx` imports app-level API endpoints (`../../../api/endpoints/*`), which
inverts the `@ui`→app layering the README sets out; and the `@ui` README's *"Status: Empty
scaffold"* line is stale (G-1) and is worth a one-line fix by whoever implements Phase 2.

## 13. Open questions, backend dependencies, and backend gaps

All seven of the questions in the first draft have been **ruled on by the coordinator**
(comment `cmt_18d75a08ff212ac7`). What remains is two answers pending from the user, plus
the dependency and gap register those rulings produced.

### 13a. Pending the user's answer (2)

**U-1 — does a user-created memory start `pending` or `active`?** Today `POST /memories`
defaults to `pending` (F4), so a memory the user writes in the UI needs the user to approve
their own memory. `POST /memories` accepts `status` (F6), so either branch is a one-line
client change. **Coordinator's recommendation: `active`.** Both branches, ready to apply:

| | If `active` (recommended) | If `pending` (today's default) |
|---|---|---|
| §7 create call | sends `status: "active"` | sends no status |
| §7 create-page note | *"Your memories take effect immediately. Agent proposals land in Proposals for approval."* | *"New memories start as proposals and need approving before agents receive them."* |
| §7 after save | → view page, status **Active** | → view page, status **Pending** |
| §1 | unchanged | unchanged |

The plan currently documents the `pending` branch, because that is what the code does today.
**Nothing else in the plan moves either way.**

**U-2 — landing tab.** §1's precedence is: explicit `?tab=` wins → else Proposals when
non-empty → else Active. If the user prefers "always Active", rule 2 is deleted; rules 1 and
3 and everything else stand.

### 13b. Backend dependencies — the page is designed for these; a degraded mode ships without them

**BACKEND-DEP-1 — the memory payload must expose read-only-ness.** `write_memory_json`
(F12) omits `owner_user_id`, so the client cannot tell a system memory from an editable one,
yet every write against one 403s (F11). **Preferred shape: an explicit `read_only: bool`**,
not `owner_user_id` — the client should not have to know that the string `"system"` is magic,
and a boolean leaks no owner ids into the payload. §6 specifies both the designed behaviour
(read-only row, no actions, "System" badge) and the Phase-1 degraded behaviour (attempt the
write, surface the 403 as a toast, count it in partial failures).

**BACKEND-DEP-2 — the search hit's route is stale.** `route_expr` emits
`/settings/memory?memory_id=…` (F17) while the live pages are `/memory` and `/memory/:id`
(F22), so the **command palette** currently sends memory hits to a legacy route. §3 ignores
`hit.route` and builds `/memory/<hit.id>` from the id, so this plan does not wait on the fix
— but `search_fts.odin:120` should be corrected as separate backend work, since the palette
has the same bug today and is not in this chain's scope.

### 13c. Backend gaps — recorded, not fixed here

| Gap | Detail | Effect on this plan |
|---|---|---|
| **No route back to `pending`** | The only status routes are approve / reject / archive (F5); `update_memory_status` is not generically exposed. A rejected proposal cannot be returned to the queue | §6 labels the rejected row's verb **Approve**, not "Restore", so the consequence is visible |
| **Scope filters honour only the first CSV token** | `memory_filter_query` splits on the first comma (F8) — a multi-value filter is silently truncated | §2's scope filters are **single-select**, matching what the endpoint does. This is a live bug in the shipped page, which sends CSV and shows chips for ids it is not filtering by |
| **Keyset drops ties** | The seek is strictly `m.updated_at < cursor` (F9), so memories sharing an `updated_at` at a page boundary are skipped | Accepted; documented in §11. Rare at second-or-finer timestamps |
| **No hard delete** | There is no `DELETE /api/v1/memories/:id` (F5); archive is the only removal | §6 offers archive and calls it "Archive". Whether a true delete is ever wanted is an FYI for the user, not a Phase-1 decision |
| **`approve` has no status precondition** | `approve_memory` moves a memory to `active` from *any* status, with or without edits (F14) | §6 relies on the UI, not the API, to gate which rows offer which verb — noted so an implementer does not read the API's permissiveness as intent |

### 13d. Rulings already applied (no action needed)

Recorded so a later reader does not reopen them: no "Created" column (`created_at` is not
serialised, and no column needs it) · single-select scope filters confirmed for Phase 1 ·
reduced search row confirmed (N+1 hydration on a debounced search is not a trade worth
making) · ignore `hit.route` · REQ-UI-7 reads as "bulk destructive action" — bulk **archive**
and bulk **reject** · G-4's cursor column is per-resource; memory keys on `updated_at`.

---

## Appendix A — Conventions this plan sets for the other four resources

Not part of the 13-section template. These are the choices that are **arbitrary but must be
consistent**, so projects / agents / actions / shells inherit them rather than re-deciding.
A later plan that diverges should say why.

| Convention | Rule |
|---|---|
| **§0 fact table** | Every plan opens with a numbered fact table, each row cited to `file:line`, listing what the design rests on. Hints are verified, not inherited |
| **URL param names** | Short, human-facing names in the URL (`project`, `agent`, `type`), mapped to the API's names (`project_ids`, …) at fetch time |
| **Cursors** | Never in the URL. Scroll restoration is by remembered row id, capped at **5 pages**, landing at top with a one-line note when the row is gone |
| **REQ-UI-20** | Rendered rows hold position; changes arrive as an **"N new or updated"** pill applied on tap; a row the user just acted on updates **in place** and never jumps |
| **Bulk select count** | *"12 selected (of the 50 loaded)"* — never "of all", never a total the API cannot supply |
| **Destructive policy** | **Undo toast** for a single low-blast-radius action; **modal confirm** for anything bulk, and for any single action that changes agent behaviour. Partial failure reports *"10 archived, 2 failed"* and leaves the failed rows selected |
| **Loading** | Skeletons at the real row height, never spinners, never a layout shift. Paging errors append a retry strip and never destroy loaded rows |
| **Empty states** | Four distinct ones, not one: first-run · no-results-for-filters · no-results-for-query · the resource's "good empty" if it has one. First-run invites creation; no-results blames the filter and hands back the control that caused it |
| **Tab labels** | Where a tab hosts a filter that can change what the tab contains, the **tab label states it** (`Proposals · Rejected`) rather than letting the filter contradict the tab |
| **Landing tab** | An explicit `?tab=` in the URL always wins over any heuristic; a failed probe falls back silently to the default tab |
| **Search vs filters (REQ-UI-5)** | Filter chrome is **disabled, not hidden**; an `Alert` names the exact filter state being held and offers a one-click restore; the tab strip shows no tab as selected while a query is active |
| **Display-name length** | **200 characters, client-side**, on any single-line display-name field (`title` / `name` / `label`) — a soft guard at the input, not an API contract. A resource whose server imposes a real cap uses that number and says so |
| **Desktop list component** | `DataList` (wrapping `Table`), never `Table` directly — it carries the selection model, row click target, action slot and mobile fallback |
| **Scope inputs** | `ScopeField` / `ScopeChips`. Empty never renders as "none": a RECORD page states every dimension ("All bridges", `variant="full"`), a LIST ROW collapses to a single **Global** chip, or the narrowing chips plus one muted "all other scopes" |
| **Column economy** | A truncated one-line prose **summary next to a title does not earn its column** — drop it; the detail is one tap away. Applies to the Summary/description column on all five resources |
| **Buttons by viewport** | **No icon-only buttons on desktop** (labelled **Edit** / **More**); icon buttons on touch, carrying the same string as their accessible name. One component — `ActionButton` — renders both; no page forks on `useIsMobile` for this |
| **Page heading** | The **terminal breadcrumb IS the `<h1>`**. Pages pass the full trail; `PageShell` renders the ancestors and promotes the last crumb, so nothing is printed twice |
| **Filters** | Collapsed behind a **Filters** button on **every** viewport, with chips for the non-default filters only (each chip clears its own filter) and the explanatory note inside the drawer |
| **Search placement** | Inline with the tab row, never a full-width band above it |
| **Spacing & type** | `PageShell rhythm="banded"` owns the band rhythm and the body's inline padding; prose capped to a measure (`.ui-measure`); row title `text-title` at full contrast with every other column receding in colour and weight |
| **Bottom-docked chrome** | Anything pinned to the bottom edge reads `--ui-bottom-chrome` (published by the shell from the tab bar's measured height) on top of `useKeyboardInset()` |
| **Option catalogs** | Three states, worded differently: loading · empty ("No bridges available") · failed ("Couldn't load bridges" + Retry). An empty list is not an explanation |

---

# Amendment 1 — user decisions (coordinator, applied at approval)

Revision 2 of this plan crossed with the user's answers to §13a and to a new request. The
plan was approved **as amended by this section**. Where this section and the body above
disagree, **this section wins**, and the implementation task is bound to it.

## A1.1 — user-created memories are born `active` (settles U-1)
`POST /api/v1/memories` accepts `status` (F6). The create form sends `status: "active"`.

- §7's "New memories start as proposals and need approving before agents receive them."
  note is **deleted**. Creating a memory from the UI puts it into force immediately.
- §7's "Save & approve" second button applies **only** to editing an existing `pending`
  proposal (F14). It does not appear on create.
- `pending` therefore means exactly one thing: **an agent proposed this and a human has not
  decided yet.** That sentence belongs wherever it sharpens the Proposals tab's purpose, and
  it is what makes §10's "No proposals waiting" legitimately the good state.

## A1.2 — landing-tab heuristic confirmed (settles U-2)
§1's precedence list stands exactly as written: explicit `?tab=` wins, else Proposals when
its first page is non-empty, else Active; probe failure falls back to Active silently and
never blocks first paint. Delete the "awaiting the user's answer" parenthetical in §1.

## A1.3 — a third tab: **Proposals · Active · Archived**
The user asked for archived memories to have their own tab. This **supersedes §1's "two
tabs"** and touches §2, §6, §10 and §11. Binding constraints:

- All four statuses (`pending`, `active`, `rejected`, `archived`) stay reachable. State
  where `rejected` lives.
- **Prefer deleting status-switching from the other tabs over labelling around it.** §1's
  F-6 fix (the tab label carrying a `· Rejected` qualifier) is correct but exists only
  because a tab could show rows that are not its own status. With a real Archived tab that
  problem may disappear at the root for `archived`; take that simplification where it is
  available. Any tab that *keeps* a status filter keeps the qualifier rule — a tab must
  never read as selected while showing rows of another status.
- The landing-tab rule is unchanged: the probe concerns Proposals only. **Archived is never
  a landing tab.**
- §6 gains an Archived column. Its bulk verb is **Restore selected**. F-2 does **not** apply
  here: `archived` → `active` is a genuine restore to a state a human already sanctioned.
  F-2 applies only to `rejected` rows, whose verb remains **Approve**.
- §10 gains an empty state for an empty Archived tab, distinct from the other four.
- §11's `tab=` param gains `archived`.
- Archived is visited rarely. It must cost the common path nothing: no extra request on
  load, no count badge (there are no totals anyway).

## A1.4 — archive is the permanent answer to delete
No hard delete is wanted. §13c's "no `DELETE /api/v1/memories/:id`" stays a recorded backend
gap, not a request.

## A1.5 — scope of the Archived-tab convention
"A dedicated tab per terminal state" is **memory-specific, not a chain-wide convention.**
Projects has an `archived` state and may reasonably copy it; agents, actions and shells have
no comparable lifecycle and must not have it forced on them for symmetry. Appendix A is
amended accordingly.

---

# Amendment 2 — the redesign (supersedes §4, §5, §6's row actions, and §8)

**This amendment, not the sections above it, describes the page that exists.**

`docs/ui-rebuild/memory-redesign-spec.md` is the user's own words and is authoritative. Where
this plan disagreed with it, the spec won and the plan is updated here. What follows is what was
BUILT, not what was proposed.

## A2.1 — the column table is gone; a row is FOUR LINES (supersedes §4 and §5)
The desktop table is replaced by a **row list on every viewport** (`MemoryRow`). The anatomy is
the user's own and supersedes the spec's "title + one-line snippet + meta line":

    row 1   Title ...........................................  [ … ]
    row 2   body line 1
    row 3   body line 2
    row 4   [type] [status] [scope] ...................  12m ago

- **Row 1** pairs the title with the overflow trigger. The title truncates to one line *against*
  the trigger and must never push it off the row — that is `min-w-0` on the title's flex item,
  without which a flex child refuses to shrink below its content width.
- **Rows 2-3** are the body, clamped at **two** lines then ellipsis (user: *"ensure body can span
  two lines and not truncate just on one"*). Markdown is stripped to plain text first.
  The two lines are **reserved even when a memory has no body**, computed from the type tokens as
  `calc(2 × var(--text-body-sm-size) × var(--text-body-sm-leading))` — so a body-less row does not
  collapse and leave its pills sitting a line above its neighbours'. Token-derived, not a magic px.
- **Row 4** puts the pills hard left and the relative time hard right, with the absolute date in
  `title`.

**72px is a FLOOR, not the height.** Four lines take what they take: **measured at 135px** with the
current type scale (Firefox 155 at 1440px, `getBoundingClientRect`). Measure it again if the scale
changes rather than re-asserting a number.

`DataList`'s table path is untouched and still generic — Agents and Actions carry more columns than
Memory ever did and still need it, along with Amendment 4's scroll region.

**Pill order — time is LAST** (user ruling, overriding the spec's "type · status · time · scope").
The chips are what the eye scans across rows; a timestamp wedged between them breaks the run.

## A2.2 — no Select mode; checkboxes are always visible (user ruling)
The `Select` toggle is **removed**. Checkboxes are persistent on every viewport, including touch.
This satisfies REQ-UI-19 more directly than select-mode did: nothing is hover-revealed and
nothing is behind a mode. `BulkActionBar` appears as soon as a row is ticked.
`BulkActionBar.SelectToggle` still exists in `@ui` for a resource that wants it; Memory does not.

## A2.3 — a row carries a single `…` menu and NOTHING else (user rulings, in order)
This clause changed three times as the user used the page. **The final state is the only one that
matters; the discarded steps are recorded in A2.10 so nobody rebuilds them.**

- **A row renders no verb buttons at all** — no inline Approve/Reject, no hover-revealed cluster.
  User: *"hide the hover to show button. Only selection would show approve and reject button or
  within ..."*. Verified by counting buttons in the rendered row, not by reading the JSX:
  every row reports `inlineBtns: 0` beside its `…` trigger.
- **Approve and Reject exist in exactly three places** page-wide: the row's `…` menu, the bulk bar
  during selection, and the detail header. Nowhere else.
- **Inside the menu the verbs are WORDS**, never bare glyphs. This is the whole reason the menu is
  the right home for them: `Reject` and `Archive` are read rather than guessed from an icon sitting
  next to `Approve`. An icon *beside* a label is fine; an icon *instead of* a label is not.
- **The overflow trigger is an icon on every viewport** (`ActionButton iconOnly`), 44×44, with a
  real accessible name (`aria-label="Actions for <title>"`). `…` is the convention for an overflow
  menu and a text "More" reads as a verb it is not.
- **There is no Select toggle** (A2.2), settled again directly by the user: *"no selecttoggel."*
- **Filters is an icon button immediately right of the search field**, with a badge counting
  selected **values**, not dimensions.
- Active filter chips and **Clear filters** sit on their own row directly below the search bar.

**Hit-testing — the classic bug in this layout.** Tapping `…` must not also open the detail. The
row ignores any click originating inside `[data-row-control]` (the checkbox and the menu), and the
title stays a real `<a>` so keyboard focus, middle-click and "copy link address" still behave. A
stretched-link pseudo-element over the whole row was **rejected**: it would sit on top of the scope
chips' `+N` affordance and swallow it.

## A2.4 — two-pane master/detail at >=1024
List (max-width 420px) on the left, the memory in a pane on the right, selected row highlighted.
768–1023 is a single centred column; below 768 the detail is its own page.

**The route is unchanged.** `#/memory/:id` still deep-links, and at >=1024 that route renders
list + pane. One memory therefore never has two URLs. The href **carries the list's state**
(`#/memory/:id?tab=proposals&type=fact`): without it, opening a row silently reset the tab and
filters underneath the user — caught in verification, not by reading.

## A2.5 — detail view (supersedes §8)
Surface cards: **Body** (copy inline with the label) · **Evidence** (monospace rows, copy inline,
hidden when empty) · **Scope** · **Details**. Right rail (320px) for Scope + Details when the pane
is >=900px wide, else stacked. Mobile gets a sticky Reject|Approve bar, 50/50, above the tab nav.

**The header's Approve/Reject are DESKTOP-ONLY** (`hidden md:contents` in `MemoryDetail.tsx`).
Rendering them at every width put **two** Approve buttons on one phone screen — the header pair
plus the sticky bar, which is `md:hidden`. The user hit this in the preview and a 390px screenshot
caught it in the same minute; a type checker cannot see it. Below `md` the header keeps only the
`…` menu (Edit / Archive). Verified by counting *visible* buttons: 1 Approve + 1 Reject at 1440px
**and** at 390px. `md:contents` and not `md:flex` — the buttons are laid out by the header's own
flex row, so a wrapper that became a flex item would collapse them into one box with the wrong gap.

- **Scope and Linked resources are MERGED** into one 4-row key/value list. All four empty renders
  `Global: applies everywhere` plus an **Edit scope** link. The ALL-four-must-match rule is an
  info affordance, not a permanent paragraph.
- **Details = Updated + Memory ID** only. Type and Status are in the header meta line.
- **No Created row** — `created_at` is not serialised (F12).
- **No Source agent / "Agent" badge** — a memory has no author field, and `status == 'pending'`
  is a lifecycle state, not provenance. The `"Agent proposed: "` prefix IS stripped from
  displayed titles (`stripProposalPrefix`), because it is noise in a title.
- **Evidence `file:line` refs are NOT auto-linked.** Unstructured free text can only be matched
  heuristically, and a link that goes somewhere wrong is worse than text that is honest.
- **Delete does not exist.** The menu reads Edit / Archive.

## A2.6 — tabs carry no count badges
The list APIs return no totals (F10). A loaded-row count on a keyset-paged list would be a
number that looks like a total and is not. Badges return only if a count endpoint lands.
"Decrement the tab count optimistically" is therefore moot; **auto-advance** still ships — acting
on a proposal moves the pane to the next one, and closes it when that was the last.

## A2.7 — interaction
- Keyboard: `/` focuses search, `j`/`k` move (and open, in two-pane), `a` approves, `r` rejects.
  Every shortcut is ignored while typing in a field or while a modal is open, and a verb only
  fires when the focused row actually offers it.
- Touch: **there is no swipe gesture.** It was built, shipped to the preview, and removed at the
  user's instruction — *"remove the slide for actions feature it doesn't work well on mobile"*.
  Nothing was orphaned by removing it: the `…` menu was always the accessible path behind the
  gesture, so every verb is still one tap away, discoverable, and reachable from a keyboard.
  **The reject undo toast stays** — it belongs to rejecting as a verb, not to the gesture that
  used to trigger it.
  *Do not reintroduce swipe on the other four resources.* See A2.10.

## A2.8 — REQ-UI-5's banner removed (user ruling)
The "Showing search results across all memory — tabs and filters don't apply" `Alert` is gone,
on the user's instruction. **The behaviour is unchanged**: a query still replaces the list, the
server still disregards tabs and filters, and the held filter state still returns when the query
is cleared. The signal is now shown rather than narrated — no tab reads as selected and the
Filters control is inert (`disabledTitle` explains it on hover). §3's other rulings stand.

## A2.9 — global fixes
- The scroll container clears the bottom chrome by MEASUREMENT (`--ui-bottom-chrome` + the
  safe-area inset), not a guessed `pb-20`.
- The mobile tab bar is **solid**, not a translucent blur, and carries the safe-area inset.
- Icons come from one line-icon set. **No emoji anywhere** — `MarkdownBody`'s copy button was
  rendering 📋 and its attachment chip 📎; both are now inline SVGs from the same set, which
  fixes them app-wide rather than only on Memory.

## A2.10 — built, then removed by the user (do NOT rebuild these on the other four)
Three row affordances were implemented, seen in the preview, and then cut. They are recorded
because the next four resources inherit this row, and a reasonable engineer would otherwise
propose each of them again — they are not oversights.

| Removed | The user's words | Why it was right to cut |
|---|---|---|
| **Inline Approve/Reject on Proposals rows** | *"Lets remove the button all together from the entries then."* | Repeating two verbs down every row is noise, and a destructive verb sitting inches from an approving one is a misclick waiting to happen. |
| **Hover-to-reveal action cluster** | *"hide the hover to show button"* | Hover does not exist on touch, and a control that appears only on hover is undiscoverable for everyone else. It also made the whole list twitch under the cursor. |
| **Swipe right = approve / left = reject** | *"remove the slide for actions feature it doesn't work well on mobile"* | A gesture is invisible, unreachable from a keyboard, and competes with the scroll container. It never earned its complexity. |

**What replaced all three: one `…` menu per row.** It is discoverable, keyboard-reachable, labels
its verbs in words, and offers only the verbs that mean something in that row's state. The lesson
worth inheriting is the general one — *a row should carry one obvious way to act, not three clever
ones.*

**Also removed at the user's instruction, earlier in the same pass:** the Select toggle (A2.2), the
tab count badges (A2.6) and REQ-UI-5's banner (A2.8).
