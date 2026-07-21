# Pagination Audit — Heimdall list resources

Date: 2026-07-20
Scope: every daemon endpoint / frontend query that returns a collection which can grow unbounded, and whether it paginates (server-side), pages only in the client, or fetches everything.

This audit covers **two orthogonal problems**:

1. **Row-count** — the list has too many rows (needs pagination). See "Summary table" below.
2. **Row-weight** — each row embeds heavy content (long text / bodies) that should NOT
   travel in a list response; the list should return lightweight metadata + an id,
   and the heavy content is fetched on demand by id. See
   "Heavy content embedded in list rows" below.

Both multiply: a list that is both long AND fat (e.g. tasks with descriptions +
comment bodies, memories with bodies) is the worst case.

## Legend

- ✅ **Server-paginated & used** — daemon supports limit/offset (or cursor) AND the client uses it.
- ⚠️ **Server-paginated but not used** — endpoint supports paging, but the client requests everything (huge `limit`, or ignores it).
- 🟡 **Client-only paging** — daemon returns the full list; client slices for display (memory/CPU risk, no network relief).
- ❌ **No pagination anywhere** — full-collection dump, unbounded.
- 🟢 **Bounded by nature** — single record, or a small fixed cap that cannot grow with usage.

---

## Summary table

| Resource | Endpoint / query | Daemon | Client | Status |
|---|---|---|---|---|
| Conversations (chat list) | `user-rpc list_chats` → `chat_list_json` | none | `SIDEBAR_PAGE_SIZE=5` slice | 🟡 client-only |
| Task chains | `GET /task-chains?limit&offset` → `handle_get_task_chains` | limit/offset + `has_more` (default 20) | `listTaskChains(limit=1000)` | ⚠️ paginated, not used |
| Tasks (global) | `GET /tasks?limit&offset` → `handle_get_tasks` | limit/offset | `listTasks(limit=50)` (rare) | ✅ / see notes |
| Tasks in a chain | `GET /task-chains/{id}/tasks` → `handle_get_chain_tasks` | none | renders all | 🟡 client-only |
| Task store snapshot | `user-rpc list_tasks` → `task_store_state_json` | none (ALL tasks+chains+participants+votes+comments) | consumed wholesale | ❌ none |
| Task comments | `GET /tasks/{id}/comments` → `handle_get_task_comments` | none (all comments) | `task-detail-comments-load-older-btn` slices client-side | 🟡 client-only |
| Task event log | `user-rpc task_log` → `task_log_json_paginated` | limit/cursor | `fetchTaskLog(limit=50)` + load-older | ✅ |
| Chat messages (thread) | `GET /chats/{id}/messages?limit&cursor` | limit/cursor + `next_cursor` | `fetchDirectChatPage` + load-older | ✅ |
| Memory (list) | `user-rpc memory_list` → `memory_db_list_records` | none (`SELECT … FROM memories` no LIMIT) | renders all | ❌ none |
| Memory history | `fetchMemoryHistory` | per-record | small | 🟢 bounded |
| Projects | `GET /projects` → `project_list_json` | none (all projects) | renders all | ❌ none (low cardinality) |
| Agents / identities | `GET /agents?include_identities` → registry+store dump | none on this path (full) | `listAgents` full; sidebar/mgmt slice `SIDEBAR_PAGE_SIZE` | 🟡 client-only |
| Agents (paged variant) | `GET /agents?limit&offset` → `has_more/next_offset` | limit/offset + `has_more` | `listKnownAgentsPage` (exists, rarely used) | ⚠️ paginated, not used |
| Artifacts | `GET …/artifacts?limit` → `artifact_db_list … LIMIT` | cap only (default 100, no offset/cursor) | `listArtifacts(limit=100)` | ⚠️ capped, no true paging |
| Artifact versions | `artifact_db_list_versions LIMIT ARTIFACT_MAX_VERSIONS` | fixed cap | — | 🟢 bounded |
| Agent inbox messages | provider `fetch` | limit (≤100) + since-cursor | — | ✅ (provider), see notes |
| Federation peers | `federation_peers_list_json` | none | small | 🟢 bounded |
| Federation advertised agents | `federation_advertised_agents_json` | none (all advertised) | fetched on picker open | 🟡 low cardinality |

---

## Priority findings

### P0 — Full-collection dumps that grow unbounded with usage

1. **`task_store_state_json` (`user-rpc list_tasks`)** ❌
   Returns **every** task, chain, participant, vote and comment in one JSON blob. This is the heaviest offender: it grows with total lifetime tasks across all chains. Used to hydrate the task cache. Needs real pagination or per-chain lazy loading.

2. **Conversations `list_chats`** 🟡 → should be ✅
   Already discussed: daemon returns ALL conversations (observed 111 in one payload); the sidebar only client-slices 5 at a time. No server limit/cursor. Grows with total conversations ever created.

3. **Memory `memory_list`** ❌
   `SELECT … FROM memories` with **no LIMIT**. Returns every active/all memory. Grows with the durable memory corpus. No server paging, client renders all.

### P1 — Endpoints that already support paging but the client bypasses it

4. **Task chains** ⚠️
   `handle_get_task_chains` supports `limit`/`offset` and returns `has_more`, but `listTaskChains` calls it with **`limit=1000`** — effectively "fetch all". Wire the app + `TaskChainsSurface` + sidebar to real paging.

5. **Agents catalog** ⚠️ / 🟡
   The paged variant (`listKnownAgentsPage`, `has_more`/`next_offset`) exists but the primary `listAgents` uses the full include-identities dump; sidebar/management then client-slice. Grows with total agent-ids + instances (already 188 instances locally).

### P2 — Per-parent lists that are usually small but can spike

6. **Tasks in a chain** (`/task-chains/{id}/tasks`) 🟡 — no server limit; fine for typical chains, risky for very large ones.
7. **Task comments** (`/tasks/{id}/comments`) 🟡 — returns all comments; client has a "load older" affordance but the network payload is already full.
8. **Artifacts** ⚠️ — `LIMIT` cap only (default 100), no offset/cursor, so beyond the cap items are silently unreachable.

### Bounded / acceptable

- Chat thread messages, task event log, agent inbox `fetch`: ✅ proper limit/cursor with load-older.
- Projects, federation peers, artifact versions, memory history: 🟢 low cardinality or fixed caps.

---

---

## Heavy content embedded in list rows (row-weight)

Separate from row-count: several list endpoints inline large per-row text that
should be **excluded from the list** and fetched lazily by id. The list should
carry only lightweight fields (id, title, short summary, counts, timestamps,
status) plus the ids needed to fetch detail.

| List endpoint | Heavy fields embedded today | Should return in list | Fetch-by-id detail |
|---|---|---|---|
| **Tasks** (`task_store_state_json`, `/task-chains/{id}/tasks`, task_write_state_json) | `description`, `acceptance_criteria`, **full `unresolved_comments[].body`** | task id, title, status, assignee, reviewer ids, `unresolved_comment_count`, **`comment_ids[]`** only | `GET /tasks/{id}` for description/AC; `GET /tasks/{id}/comments/{comment_id}` (or batched by ids) for each comment body |
| **Task comments** (`/tasks/{id}/comments`) | full `body` of every comment | comment id + author + resolved + created_ms | `GET /tasks/{id}/comments/{comment_id}` for body |
| **Memory** (`memory_list` / `memory_write_record_json`) | full **`body`** (+ `evidence`, `metadata_json`) | memory id, `title`, `type`, status, target scope, version, updated_ms | `GET /memory/{id}` (`showMemory`) returns `body`/evidence/metadata |
| **Agent templates** (`/agents/templates`, agent_template_record_json) | full **`persona`** + **`instructions`** (1–7 KB each × 12 templates) | template id, display_name, description, defaults | `GET` template-show / `handle_agent_template_show` for persona+instructions (already exists) |
| **Task chains** (`task_write_chain_json`) | full **`description`** (canonical design doc, ~2–3 KB) + `final_summary` | chain id, title, status, coordinator/reviewer ids, progress counts | `GET /task-chains/{id}` for description/final_summary |
| **Chat messages** (thread) | full `body` per message | — (bodies ARE the payload here; correct to include) | n/a — this list *is* the content |

### Notes / rationale

- **Tasks + comments (the requested change):** the task projection currently
  inlines `unresolved_comments` with full bodies. The list should carry only
  `comment_ids` (+ `unresolved_comment_count`); each comment body is fetched by
  `comment_id`. This shrinks `list_tasks` / chain-tasks payloads dramatically and
  decouples comment volume from task list size. Add a
  `GET /tasks/{task_id}/comments/{comment_id}` (or a batch `?comment_ids=`) detail
  route; keep `GET /tasks/{id}/comments` for the full paginated thread on the
  task detail view.
- **Memory (the requested change):** `memory_list` returns `body` for every row.
  Change it to return `title` + `type` + scope + `updated_unix_ms` only; the
  `body`/evidence/metadata come from `showMemory(memory_id)` which already exists
  (`GET /memory/{id}`). Bootstrap generation (`/memory/applicable`) still needs
  bodies — keep a `include_body=true` / dedicated applicable path for the wrapper,
  but the UI/list path defaults to metadata-only.
- **Templates:** the settings catalog loads all templates with full persona +
  instructions on startup even though the list UI only needs names. Drop
  persona/instructions from the catalog list; fetch them via the existing
  template-show endpoint when a template (or the agent identity page) is opened.
  (The remote-proxy template pass-through added recently is already the
  fetch-by-id pattern for the federated case.)
- **Task chains:** `description` is the canonical markdown design doc and is the
  single largest per-row field in the chains list. The sidebar/home/TaskChains
  surfaces only need title + status + progress; move `description`/`final_summary`
  to `fetchChain(id)` detail (the ChainView already fetches the chain).

### Recommended contract for list-vs-detail

- List rows return: identity + display metadata + **counts** + **child ids**
  (`comment_ids`, etc.), never large bodies.
- Detail-by-id endpoints return the heavy fields.
- Where callers legitimately need bulk bodies (e.g. wrapper bootstrap pulling
  applicable memories), expose an explicit opt-in flag (`include_body=true`) or a
  purpose-built endpoint rather than defaulting every list to full content.

---

## Recommended pattern (standardize)

Adopt one consistent contract for all growable list endpoints:

- Request: `?limit=<n>&cursor=<opaque|unix_ms>` (prefer keyset/cursor on a monotonic `*_unix_ms` for stable ordering; offset acceptable for admin views).
- Response envelope: `{ items: [...], next_cursor: <n|0>, has_more: <bool>, total?: <n> }`.
- Client: RTK Query `fetchXPage` + `merge`/append cache, "Show more" wired to `next_cursor` (mirror the existing `fetchDirectChatPage` / `fetchTaskLog` pattern, which are the reference implementations here).

---

## Action items (prioritized)

Priority key: **P0** = correctness/scale risk shipping today, biggest payloads;
**P1** = clear scale risk or wasted bandwidth, medium effort; **P2** = hardening /
long-tail. Effort: S ≈ <0.5d, M ≈ 0.5–1.5d, L ≈ 2d+. Each item lists the
backend (daemon), frontend (API/query), and UI changes required together, since
a list-vs-detail split is only safe when the UI is updated in the same change.

Legend for type: **[count]** = pagination, **[weight]** = list-vs-detail content split.

### P0

- [ ] **AI-1 — `list_chats` cursor pagination** [count] · M
  - Daemon: add `limit` + `cursor` (keyset on `last_message_unix_ms`) to
    `handle_user_rpc_list_chats` / `chat_list_json`; return `{ chats, next_cursor, has_more }`.
  - Frontend: `listConversationSummaries` → `fetchConversationSummariesPage(cursor)`;
    append-merge cache.
  - UI: wire the existing `sidebar-conversations-show-more-btn` to fetch the next
    page instead of client-slicing; keep the current title/liveness filter. Home
    recent-chains unaffected.

- [ ] **AI-2 — Memory list is metadata-only** [weight] · M
  - Daemon: `memory_write_record_json` used by `memory_list` drops `body`,
    `evidence`, `metadata_json`; returns `memory_id, title, type, status, target_*,
    version, updated_unix_ms`. Add `include_body=true` opt-in used ONLY by the
    wrapper bootstrap / `/memory/applicable` path (bodies still needed there).
  - Frontend: `listMemory` / `listApplicableMemory` normalizers stop expecting
    `body`; `fetchMemory(id)` (already exists) is the body source.
  - UI: Memory browser list + `agent-identity-memory-item-*` rows render
    title/type/scope only; opening a memory (memory detail / editor) fetches body
    by id. Ensure `AgentMemoryEditor` loads body on open, not from the list row.

- [ ] **AI-3 — Tasks: comment ids + lazy description** [weight] · L
  - Daemon: `task_write_state_json` replaces inline `unresolved_comments[].body`
    with `comment_ids: []` (+ keep `unresolved_comment_count`); move
    `description` + `acceptance_criteria` out of the list projection into
    `GET /tasks/{id}` detail only. Add `GET /tasks/{task_id}/comments/{comment_id}`
    (and/or batch `?comment_ids=`) returning bodies.
  - Frontend: `fetchTask(id)` becomes the source for description/AC; new
    `fetchTaskComment(taskId, commentId)` (or batch) query; task list normalizer
    stops reading description/comment bodies.
  - UI: `chain-task-row-*` and `task-detail-*` show title/status/counts from the
    list; expanding a task (`task-detail-description-*`) fetches description by id;
    each comment (`task-detail-comment-*`) fetches its body by comment id (or the
    already-present `task-detail-comments-load-older-btn` drives a paged fetch).

- [ ] **AI-4 — Stop shipping `task_store_state_json` wholesale** [count+weight] · L
  - Daemon: deprecate `user-rpc list_tasks` full dump for UI use; rely on
    per-chain `GET /task-chains/{id}/tasks` (add `limit`/`cursor`) + lazy chain
    load. Keep a bounded admin/debug variant if needed.
  - Frontend: `taskSlice` / `chainViewSlice` fetch tasks per active chain on
    demand instead of hydrating the entire store; drop the global task hydration.
  - UI: no visible change when on a chain (tasks already scoped to the open
    chain); Home/attention counts move to lightweight count endpoints or
    per-chain progress already returned by the chains list.

### P1

- [ ] **AI-5 — Task chains: lazy description + real paging** [count+weight] · M
  - Daemon: `task_write_chain_json` (list path) drops `description` +
    `final_summary`; both come from `GET /task-chains/{id}`. `handle_get_task_chains`
    already returns `limit/offset/has_more` — keep it.
  - Frontend: `listChains` sends real `limit` (not `1000`) + `offset`/cursor,
    append-merge; `fetchChain(id)` supplies description/final_summary.
  - UI: `TaskChainsSurface` (`task-chains-active-list` / `-completed-list`),
    sidebar `conversation-active-chains`, and Home recent-chains render
    title/status/progress only + a "Show more" control; `ChainView` +
    `ChainDescriptionPanel` fetch description on open (ChainView already fetches
    the chain).

- [ ] **AI-6 — Agent templates: catalog is name-only** [weight] · S
  - Daemon: `/agents/templates` list variant drops `persona` + `instructions`
    (keep `template_id, display_name, description, defaults`); `handle_agent_template_show`
    already returns full content.
  - Frontend: settings catalog `templates` no longer carries persona/instructions;
    add `fetchTemplate(id)` query (mirror the remote-proxy pass-through already added).
  - UI: template pickers/labels use name only; `AgentIdentityPage` template panel
    fetches persona/instructions by id on expand (local path mirrors the remote
    path already implemented).

- [ ] **AI-7 — Agents catalog via paged variant** [count] · M
  - Daemon: `GET /agents?limit&offset` (with `has_more/next_offset`) already
    exists; ensure identities can be paged too or split identities vs instances.
  - Frontend: primary `listAgents` moves off the full include-identities dump to
    the paged endpoint; keep a cached identities list for pickers.
  - UI: `AgentsManagementSurface` list, sidebar durable-agents, and `AgentPickerV2`
    consume paged data with "Show more"; pickers keep search over the loaded page +
    on-demand fetch for exact-id matches.

### P2

- [ ] **AI-8 — Artifacts: cursor/offset beyond the cap** [count] · S
  - Daemon: `artifact_db_list` add `offset`/cursor (currently `LIMIT` cap only, so
    items past the cap are unreachable).
  - Frontend: `listArtifacts` paged; UI artifact lists get "Show more".

- [ ] **AI-9 — Task comments thread paging** [count] · S
  - Daemon: `GET /tasks/{id}/comments` add `limit`/`cursor`.
  - Frontend/UI: `task-detail-comments-load-older-btn` drives real paging (today it
    slices a fully-loaded list).

- [ ] **AI-10 — Per-chain tasks paging for very large chains** [count] · S
  - Daemon: `GET /task-chains/{id}/tasks` add `limit`/`cursor`.
  - UI: chain task lists (`chain-task-list-active` / `-completed`) page for
    outlier chains; typical chains unaffected.

- [ ] **AI-11 — Standardize the list/detail contract** · S (cross-cutting)
  - Document + enforce the envelope `{ items, next_cursor, has_more, total? }` and
    the "list = ids + metadata + counts, detail = heavy fields" rule for all new
    endpoints. Add the reference implementations (`fetchDirectChatPage`,
    `fetchTaskLog`) to contributor docs.

### Dependency / sequencing notes

- AI-3 and AI-4 share the task projection; do AI-3 (content split) first, then
  AI-4 (drop the global dump) so the per-chain path is already lean.
- AI-5 depends on the chains-list content split but not on tasks work; can run in
  parallel with AI-3.
- AI-2 must ship backend + UI together (memory editor must fetch body by id before
  the list stops sending it) to avoid a blank-body regression. Same coupling for
  AI-3 (task description), AI-5 (chain description), AI-6 (template content).
- Keep `include_body` / applicable-memory + template-show paths intact for the
  wrapper bootstrap throughout — those consumers legitimately need full content.
