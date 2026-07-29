# Memory Settings Page — Plan

## Goal

A first-class **Settings → Memory** page (routed/cookie-auth shell) to:

1. **View** memories (all statuses) with filters, and see each memory's scope.
2. **Create** memories with a scope selector for every possible target:
   agent, project, bridge, and (see note) instance.
3. **Approve / reject** pending memory proposals.
4. **Edit scope + content before approving** a proposal.

**Hard UI constraint: no raw ID entry.** Every scope target (agent, project,
bridge, template, instance) and every enumerated value (type, status) MUST be a
**dropdown/select populated from live Hub data** — labelled by human-friendly
names, never by asking the user to type or paste an id. IDs are the stored
value behind each option's display label; the user only ever picks from a list.
This applies to create, edit, filters, and proposal review alike.
5. Use **cookie auth against the Hub** (`/api/v1/...`, `credentials: include`),
   NOT the legacy `daemonUrl` + `clientToken` path.
6. Ship a **separate system skill** teaching agents how to work with memory:
   best practices, choosing the right scope, and how to author a skill-type
   memory correctly.

## Current State

### Backend (Hub) — mostly present

- Domain `Memory` (`src/hub/domain/content.odin`) already has scope fields:
  `agent_id`, `project_id`, `bridge_id`, `template_id`, plus `type`
  (fact/habit/episode/expertise/skill), `status`, `title`, `body`,
  `evidence`.
- Routes (`src/hub/app/wiring.odin`):
  - `GET  /api/v1/memories` (list; owner-scoped; includes body preview)
  - `POST /api/v1/memories` (create; accepts `agent_id`/`target_agent_id`,
    `project_id`/`target_project_id`, `bridge_id`/`target_bridge_id`,
    `template_id`/`target_template_id`, `type`, `title`, `body`, `evidence`,
    `status`)
  - `GET  /api/v1/memories/{id}` (detail with full body + evidence)
  - `POST /api/v1/memories/{id}/{action}` where action ∈ `approve|reject|archive`
    (`memory_action_handler`) → sets status active/rejected/archived
  - Agent-facing: `POST /api/v1/agent-actions/memory/propose` (status `pending`,
    scope from instance + optional overrides)
- Service (`content_service.odin`): `create_memory`, `get_memory`,
  `list_memories`, `approve_memory`, `reject_memory`, `archive_memory`,
  `update_memory_status`. **System memories are read-only.**

### Gaps (backend)

- **No update-before-approve.** There is no route/service to edit a pending
  memory's `title/body/evidence/type/scope` prior to approval. Only status
  changes exist.
- **No `pending`-only / status filter** on list (returns all; filtering is
  client-side today).
- **No instance-level scope.** Memory targets are durable: `agent_id`,
  `project_id`, `bridge_id`, `template_id`. There is **no `agent_instance_id`**
  column (memories intentionally bind to the durable agent, not a running
  instance). See "Instance scope decision" below.

### UI — stale/legacy

- `src/ui/api/endpoints/memory.ts` uses `withSessionQuery` + `session.clientToken`
  + `daemonApi.*` (legacy). In the routed/Electron cookie shell
  `session.clientToken` is empty → memory calls no-op. Same bug class as the
  task-chain page we already fixed.
- `MemorySettingsPanel` in `AppShell.tsx` uses `cookieJsonFetch('/memories')`
  (read-only, correct auth) but is a bare list: no filters, no create, no
  approve/reject, no scope display, no edit.
- `MemoryManagementPage.tsx` exists but is wired to the legacy endpoints.

## Instance Scope Decision

Requirement asks for selection of **agent-id, project, bridge, instance**.

- agent / project / bridge / template map directly to existing columns.
- **Instance**: memories are durable and outlive a running instance; the model
  has no `agent_instance_id`. Two options:
  1. **Recommended (no schema change):** in the UI, an "instance" selector is a
     convenience that **resolves to the instance's `agent_id`** (and optionally
     its `project_id`/`bridge_id`) and stores those durable scopes. The UI shows
     "scoped to agent X (from instance Y)". This keeps memory semantics durable.
  2. If a genuine per-instance ephemeral memory is ever needed, add an
     `agent_instance_id` column + `applicable` filter (larger change). Out of
     scope unless explicitly requested.
- This plan implements option (1). Call it out in the UI so users understand
  instance selection = that instance's durable agent (+ project/bridge) scope.

## Scope Model (what the selectors set)

A memory may set any combination of:
- `agent_id` — applies to that durable agent (empty = all agents of the owner)
- `project_id` — applies within a project
- `bridge_id` — applies on a specific machine/bridge
- `template_id` — applies to agents using a template
- `type` — fact | habit | episode | expertise | skill
- `template_id` is a scope target; `template` is not a memory type.

Empty scope field = "any". `applicable` resolution already exists for bootstrap
(`bootstrap_memory_applies`). The UI just needs to let users pick these.

---

## Backend Changes

### B1 — Update-before-approve endpoint

Add the ability to edit a memory's content + scope while it is `pending`
(and, for owner memories, while `active` too — an edit re-proposes or updates in
place; keep it simple: allow editing content/scope for `pending` and `active`,
reject for `system`).

- Service: `update_memory(auth, id, input)` in `content_service.odin`:
  - reject if `owner_user_id == "system"` (read-only) or not owner.
  - apply provided `title/body/evidence/type/agent_id/project_id/bridge_id/
    template_id` (only fields present in the request).
  - bump `updated_at`; keep `status` unchanged.
- Route: `PATCH /api/v1/memories/{id}` → `patch_memory_handler`.
- Approve-with-edits is then a UI two-step (PATCH then POST approve) OR add an
  optional body to the approve action:
  - `POST /api/v1/memories/{id}/approve` may accept an optional partial body;
    if present, apply the edits (same validation as PATCH) before flipping to
    `active`. Recommended so "edit + approve" is atomic.

Files: `content_service.odin`, `content_handlers.odin`, `wiring.odin`.

### B2 — List filtering + pagination (optional but recommended)

- `GET /api/v1/memories?status=pending&type=skill&agent_id=…&project_id=…&
  bridge_id=…&limit=&cursor=`
- Filter server-side; keep `created_at DESC` ordering + keyset cursor (mirror
  the projects/agents pattern).
- Ensure `write_memory_json` includes all scope fields (it already emits
  `agent_id`, `project_id`, `bridge_id`, `template_id` + `target_*` aliases).

Files: `content_handlers.odin` (`list_memories_handler`), `content_service.odin`.

### B3 — Memory workflow skill (seed migration)

Add migration `016_memory_workflow_skill_memory.sql` seeding a **system** skill
memory `mem_system_heimdall_memory` (owner `system`, type `skill`, status
`active`, empty scope so it applies to all agents), teaching:
- when to propose memory vs. keep ephemeral,
- choosing the right **scope** (agent vs project vs bridge vs template; prefer
  the narrowest correct scope),
- choosing the right **type** (fact/habit/episode/expertise/skill), and using `template_id` only as a scope target,
- how to author a **skill-type** memory: SKILL.md front-matter (`name:`,
  `description:`), concise imperative body, when it loads,
- the propose→review→approve lifecycle and how NGTM/edits work,
- CLI: `./.heimdall/bin/ham-ctl agent memory propose --type <t> --title <..>
  --body <..> [--target-agent-id|--target-project-id|--target-bridge-id]`.

Register in `migrations.odin` `migration_order` + `migration_sql`. Because the
bridge now materializes all applicable skills (commit "Materialize scoped bridge
skills"), this skill will appear as its own SKILL.md.

Files: `migrations.odin`, new `migrations/016_memory_workflow_skill_memory.sql`.

---

## Frontend Changes

### F1 — Rewrite memory endpoints to cookie auth

Rewrite `src/ui/api/endpoints/memory.ts` to use `cookieJsonFetch`/`cookieMutation`
against `/api/v1/memories...` (drop `withSessionQuery` + `daemonApi` +
`session.clientToken`), mirroring `chats.ts`/`projects.ts`/`tasks.ts` fixes:
- `listMemory({ status?, type?, agentId?, projectId?, bridgeId?, limit?, cursor? })`
  → `GET /memories?…`
- `fetchMemory(memoryId)` → `GET /memories/{id}`
- `createMemory(input)` → `POST /memories`
- `updateMemory(memoryId, input)` → `PATCH /memories/{id}` (B1)
- `approveMemory(memoryId, editsOptional?)` → `POST /memories/{id}/approve`
- `rejectMemory(memoryId)` → `POST /memories/{id}/reject`
- `archiveMemory(memoryId)` → `POST /memories/{id}/archive`
Tag `Memory`/`{id}`; invalidate on mutations.

Files: `src/ui/api/endpoints/memory.ts`, `heimdallApi.ts` (tags if needed).

### F2 — Scope selectors (shared component)

A `MemoryScopeSelector` used by both create and edit. **All fields are
dropdowns only — no free-text ID inputs anywhere.** Each option renders a
human-friendly label (name/title) and carries the id as its value; ids are never
shown as the primary label and never typed by the user.

- **Agent** `<select>` — options from `useListAgentsQuery` (cookie). Label =
  agent name; value = `agent_id`. First option "Any agent" (empty value).
- **Project** `<select>` — from `useListSidebarProjectsQuery`. Label = project
  name; value = `project_id`. "Any project".
- **Bridge** `<select>` — from `useListBridgesQuery`. Label = bridge label /
  hostname; value = `bridge_id`. "Any bridge".
- **Template** `<select>` — from templates list (add cookie `GET /templates` if
  not present). Label = template name; value = `template_id`. "Any template".
- **Instance** `<select>` (convenience) — from running instances
  (`/agent-instances` or `useListAgentsQuery`). Label = a readable instance
  descriptor (agent name + bridge + short suffix); value = `agent_instance_id`.
  On pick, resolves to that instance's `agent_id` (+ optionally project/bridge)
  and sets those fields, with a hint "scoped to agent X (from instance Y)".
  (See Instance Scope Decision.)
- **Type** `<select>` — fact/habit/episode/expertise/skill (fixed enum). `template` is not a type.

Emits `{ agent_id, project_id, bridge_id, template_id, type }` (ids resolved from
the chosen option values). If a referenced list is still loading, the select
shows a disabled "Loading…" option rather than allowing free text. Use the shared
`AgentSelect`/`AgentPickerV2` pattern where practical so agent selection stays
name-first and debug-id compliant.

Debug IDs: `memory-scope-agent-select`, `memory-scope-project-select`,
`memory-scope-bridge-select`, `memory-scope-template-select`,
`memory-scope-instance-select`, `memory-scope-type-select`,
`memory-scope-summary`.

### F3 — Memory Settings page (list + filters + create)

Replace `MemorySettingsPanel` with a real surface (new
`src/ui/components/settings/MemoryPanel.tsx`, routed at `/settings/memory`).

- **Filter bar**: status (all/pending/active/archived/rejected), type, and the
  scope selectors (agent/project/bridge) as filters.
- **List**: rows show title, type chip, status chip, scope chips
  (agent/project/bridge/template), body preview, updated time.
- **Create form** (uses `MemoryScopeSelector`): type, title, body, evidence,
  scope. Submits `POST /memories` (status defaults to `active` for
  user-authored, or `pending` if you want a self-review flow — default
  `active`).
- Row actions: open detail, edit, archive.

Debug IDs: `settings-memory-panel`, `memory-filter-status-select`,
`memory-filter-type-select`, `memory-create-toggle-btn`,
`memory-create-type-select`, `memory-create-title-input`,
`memory-create-body-textarea`, `memory-create-evidence-input`,
`memory-create-submit-btn`, `memory-create-error`,
`settings-memory-row-${memoryId}`, `memory-row-open-btn-${memoryId}`,
`memory-row-edit-btn-${memoryId}`, `memory-row-archive-btn-${memoryId}`,
`memory-row-scope-${memoryId}`.

### F4 — Proposals review (approve / reject / edit-before-approve)

A **Proposals** section (or filter = pending) surfacing `status == pending`:
- Each proposal card shows type/title/body/evidence/scope, editable inline.
- Actions:
  - **Approve** → if the card was edited, call approve-with-edits
    (`POST /memories/{id}/approve` with body) OR PATCH then approve; else plain
    approve. → status `active`.
  - **Reject** → `POST /memories/{id}/reject`.
  - **Save edits** (without approving) → `PATCH /memories/{id}`.
- Editing includes the `MemoryScopeSelector`, so the reviewer can correct scope
  before approving.

Debug IDs: `memory-proposals-panel`, `memory-proposal-${memoryId}`,
`memory-proposal-title-input-${memoryId}`,
`memory-proposal-body-textarea-${memoryId}`,
`memory-proposal-evidence-input-${memoryId}`,
`memory-proposal-scope-${memoryId}` (hosts `MemoryScopeSelector`),
`memory-proposal-save-btn-${memoryId}`,
`memory-proposal-approve-btn-${memoryId}`,
`memory-proposal-reject-btn-${memoryId}`.

### F5 — AGENTS.md registry

Add all new debug IDs to `AGENTS.md` under a `MemoryPanel` / `MemoryScopeSelector`
row.

---

## UI Mock (ASCII)

```
+----------------------------------------------------------------------+
| [Bridges] [Providers] [User tokens] [Projects] [Memory*] [Defaults]  |
+----------------------------------------------------------------------+
|  Memory                                             [ + New memory ] |
|                                                                      |
|  Filters: status [ pending v ] type [ any v ]                        |
|           agent [ any v ] project [ any v ] bridge [ any v ]         |
|                                                                      |
|  Proposals (pending)                                                 |
|  +----------------------------------------------------------------+ |
|  | [skill] "Use ripgrep not grep"                    pending      | |
|  | body:  [ Prefer rg for searches … (editable) ________________ ]| |
|  | scope: agent [ backend-dev v ] project [ any v ] bridge [any v]| |
|  |        type  [ habit v ]                                       | |
|  | [ Save edits ]   [ Reject ]   [ Approve ]                      | |
|  +----------------------------------------------------------------+ |
|                                                                      |
|  All memories                                                        |
|  +----------------------------------------------------------------+ |
|  | "Project test command"   [fact] [active]                      | |
|  | agent:backend-dev · project:site · bridge:—                   | |
|  | Use nix develop --command odin check src/hub                  | |
|  |                                    [Open] [Edit] [Archive]     | |
|  +----------------------------------------------------------------+ |
+----------------------------------------------------------------------+

New memory:
  type [ fact v ]  title [__________]  body [____________________]
  evidence [__________]
  scope: agent [any v] project [any v] bridge [any v] template [any v]
         instance [ (optional) v ]  → "scoped to agent X (from instance Y)"
  [ Create ]
```

---

## Tasks & Sequencing

1. **B1** — `PATCH /api/v1/memories/{id}` + approve-with-edits (backend).
2. **B2** — list filtering + pagination (backend, optional-but-recommended).
3. **F1** — cookie-auth rewrite of `memory.ts` (unblocks all UI).
4. **F2** — `MemoryScopeSelector` shared component.
5. **F3** — Memory settings page: list + filters + create.
6. **F4** — proposals review with edit-before-approve.
7. **B3** — memory workflow skill seed migration `016`.
8. **F5** — AGENTS.md registry + validation.

Validation each step: `odin build src/hub` (B*), `npm run typecheck` (F*), and
an E2E: propose via `ham-ctl agent memory propose` → appears in Proposals →
edit scope/body → approve → becomes `active` → shows in a new agent's AGENTS.md.

## Risks / Notes

- **Cookie auth only.** Do not reintroduce `withSessionQuery`/`clientToken`/
  `daemonApi` for these; use `cookieJsonFetch`/`cookieMutation` (`/api/v1`,
  `credentials: include`). This is the concrete bug making memory unusable in the
  routed shell today.
- **System memories are read-only** — hide edit/reject/approve for
  `owner_user_id == "system"` (backend already forbids; UI should reflect it).
- **Instance scope** = durable agent scope (option 1). Make the UI wording clear;
  do not imply per-run ephemeral memory.
- **Approve-with-edits** should be atomic (single endpoint) to avoid a
  half-applied edit if approve fails.
- **No raw ID text inputs anywhere** (create, edit, filters, proposal review):
  agent/project/bridge/template/instance are `<select>` dropdowns populated from
  live Hub data, labelled by name, with the id as the hidden option value. Type
  and status are fixed-enum dropdowns. This is a hard requirement, not a nicety.
- Every new interactive element needs a `data-debug-id` + `AGENTS.md` entry.
- Skill memory (B3) must carry distinct front-matter `name:` so it materializes
  as its own SKILL.md alongside the comms/task skills.
