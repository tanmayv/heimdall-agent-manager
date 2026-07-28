# UI ↔ backend gap analysis (UI-17)

Status: implementation prerequisite for the Hub Rewrite UI chain. This document reconciles the planned UI surfaces with the currently implemented Hub `/api/v1` backend and the existing legacy UI data layer. Unsupported needs are recorded here and must not be silently mocked.

Sources:
- `docs/plans/ui-architecture.md`
- `docs/plans/ui-routes-component-hierarchy.md`
- `docs/plans/hub-bridge-user-owned-architecture-and-api.md`
- `docs/plans/hub-bridge-runtime-protocol.md`
- Current Hub route registration: `src/hub/app/wiring.odin`
- Current Hub handlers under `src/hub/transport/http`
- Current UI RTK Query/legacy API modules under `src/ui/api`

## 1. Summary

The backend now exposes a broad `/api/v1` surface for users, Bridges, agents, agent instances, projects, task chains/tasks, chats, memories, artifacts, templates, and one user WebSocket. That is enough to start the UI rewrite with real data for shell auth, conversation basics, launch, chain lists, agent/session lists, project/Bridge settings, and basic artifact viewing.

The largest gaps for the requested UI are:

1. The current UI endpoint modules still call many legacy daemon paths (`/agents/start`, `/tasks/*`, `/artifacts/*/versions`, `/user-rpc`, `/user-ws/{client}?client_token=...`) instead of `/api/v1` trusted-proxy routes.
2. Conversation summaries do not yet include `project_id`/project name or grouped unread rollups needed for Project → `agent_id` → session sidebar grouping.
3. Task detail is missing several Hub routes required by the Chain UI: task detail by id, task comments, task update, assignment/reviewer updates, reviewer vote records, and participant-style picker helpers.
4. Artifact versions, rollback, annotations, and binary download/stream details are not implemented in current `/api/v1`; only list/create/detail/content/rename-description/delete exists.
5. Provider/profile inspection is only available indirectly through Bridge capability reports; there is no dedicated providers/profile refresh endpoint.
6. Global search/batch lookup for command palette and mention autocomplete (`GET /api/v1/search`, `POST /api/v1/batch/get`) is specified in the architecture doc but not currently registered in the Hub. This is now tracked by backend follow-up `task-19f8ed3ac87` (UI-18), which depends on this UI-17 gap analysis and is the production entity-search prerequisite for Command palette task `task-19f8ec915a2`.
7. `/api/v1/user-ws` exists, but current source only publishes `agent_instance` resource changes; chat/task/artifact/memory/project/bridge invalidations still need publisher coverage.
8. Auth supports `/me` and `/me/logout-url`, but there is no unauthenticated public UI config/bootstrap endpoint carrying `login_url`.

Safe temporary assumptions are listed per surface. Any unsupported need marked **Backend follow-up** should either receive a backend task before feature completion or be hidden/disabled with clear UI copy until implemented.

## 2. Current implemented backend route inventory

Registered in `src/hub/app/wiring.odin`:

### User/auth and real-time

- `GET /api/v1/health`
- `GET /api/v1/me`
- `GET /api/v1/me/logout-url`
- `GET /api/v1/user-ws` (WebSocket upgrade)

### Chat/conversation

- `GET /api/v1/chats`
- `POST /api/v1/chats`
- `GET /api/v1/chats/{conversation_id}/messages`
- `POST /api/v1/chats/{conversation_id}/messages`
- `POST /api/v1/chats/{conversation_id}/read`

Current `POST /api/v1/chats` can create an `AgentInstance` + `ChatConversation` when `agent_instance_id` is omitted, then optionally send an initial body. Current parser accepts launch fields (`agent_id`, `bridge_id`, `provider`, `tier`, `project_id`, `chain_id`) and `initial_message.body`; attachment ids are parsed as a top-level `artifact_ids` array in source.

### Agents and agent instances

- `GET /api/v1/agents`
- `POST /api/v1/agents`
- `GET /api/v1/agents/{agent_id}`
- `PATCH /api/v1/agents/{agent_id}`
- `POST /api/v1/agents/{agent_id}/archive`
- `GET /api/v1/agents/{agent_id}/bridge-support`
- `PUT /api/v1/agents/{agent_id}/bridge-support`
- `PATCH /api/v1/agents/{agent_id}/bridge-support/{bridge_id}`
- `DELETE /api/v1/agents/{agent_id}/bridge-support/{bridge_id}`
- `GET /api/v1/agent-instances`
- `POST /api/v1/agent-instances`
- `GET /api/v1/agent-instances/{instance_id}`
- `PATCH /api/v1/agent-instances/{instance_id}`
- `POST /api/v1/agent-instances/{instance_id}/restart`
- `POST /api/v1/agent-instances/{instance_id}/stop`

### Bridges and Bridge runtime

- `GET /api/v1/bridges`
- `GET /api/v1/bridges/{bridge_id}`
- `PATCH /api/v1/bridges/{bridge_id}`
- `POST /api/v1/bridges/{bridge_id}/revoke`
- `POST /api/v1/bridge-enrollments`
- `GET /api/v1/bridge-enrollments`
- `DELETE /api/v1/bridge-enrollments/{enrollment_id}`
- `POST /api/v1/bridges/enroll` (Bridge bearer enrollment token, not browser UI after setup command generation)
- `GET /api/v1/bridge-ws` (Bridge WebSocket, not browser UI)
- `GET /api/v1/bridge/agent-instances/{instance_id}/bootstrap` (Bridge bearer token, not browser UI)

### Projects and paths

- `GET /api/v1/projects`
- `POST /api/v1/projects`
- `GET /api/v1/projects/{project_id}`
- `PATCH /api/v1/projects/{project_id}`
- `PUT /api/v1/projects/{project_id}/bridge-paths/{bridge_id}`
- `DELETE /api/v1/projects/{project_id}/bridge-paths/{bridge_id}`
- `POST /api/v1/projects/{project_id}/bridge-paths/{bridge_id}/validate`

### Task chains and tasks

- `GET /api/v1/task-chains`
- `POST /api/v1/task-chains`
- `GET /api/v1/task-chains/{chain_id}`
- `POST /api/v1/task-chains/{chain_id}/publish`
- `POST /api/v1/task-chains/{chain_id}/complete`
- `GET /api/v1/task-chains/{chain_id}/tasks`
- `POST /api/v1/task-chains/{chain_id}/tasks`
- `POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/publish`
- `POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/status`
- `POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/nudge`

### Content

- `GET /api/v1/memories`
- `POST /api/v1/memories`
- `GET /api/v1/memories/{memory_id}`
- `POST /api/v1/memories/{memory_id}/approve`
- `POST /api/v1/memories/{memory_id}/reject`
- `POST /api/v1/memories/{memory_id}/archive`
- `GET /api/v1/artifacts`
- `POST /api/v1/artifacts`
- `GET /api/v1/artifacts/{artifact_id}`
- `GET /api/v1/artifacts/{artifact_id}/content`
- `PATCH /api/v1/artifacts/{artifact_id}`
- `DELETE /api/v1/artifacts/{artifact_id}`
- `GET /api/v1/templates`
- `POST /api/v1/templates`

## 3. Current UI data-layer inventory

The stable UI data layer has useful RTK Query structure (`src/ui/api/heimdallApi.ts`, endpoint modules, tag types, `wsInvalidation.ts`), but its request helpers mostly call old daemon paths through `src/ui/api/daemonApi.ts`.

Examples that must be converted before relying on them in rewrite implementation:

- Auth/session state currently assumes `daemonUrl`, `clientInstanceId`, and `clientToken`; `/api/v1` browser calls should rely on trusted-proxy cookies/headers and no query/body tokens.
- User WS currently appears as `/user-ws/{clientInstanceId}?client_token=...` in legacy `App.tsx`; rewrite must connect to `/api/v1/user-ws` without token query params.
- Agent endpoints call legacy `/agents/start`, `/agents/show`, `/agents/create`, `/agents/providers`, and federation/proxy endpoints; rewrite should use `/api/v1/agents`, `/api/v1/agent-instances`, `/api/v1/bridges`, and `/api/v1/agents/{id}/bridge-support`.
- Task endpoints call legacy global `/tasks/{id}`, `/tasks/comment`, `/tasks/vote`, `/user-rpc` action wrappers; rewrite must use chain-scoped `/api/v1/task-chains/{chain_id}/tasks...` routes and document missing routes below.
- Artifact endpoints call legacy version/annotation routes; rewrite must only use implemented `/api/v1/artifacts` operations until backend version/annotation routes exist.
- Attention/federation/workspace/guide endpoint modules are legacy-only and should not be used for new v1 surfaces except as refactor references.

## 4. Surface-by-surface gap matrix

Legend:
- **Ready** — current backend route is sufficient for first implementation.
- **Partial** — real backend support exists, but shape or coverage is incomplete.
- **Backend follow-up** — do not mock as complete; add a backend task or hide/disable the UI affordance.
- **UI adapter** — backend exists but current UI code must be rewritten to call `/api/v1`.

| UI surface | Endpoint/data needs | Current `/api/v1` support | Gaps and recommended follow-up |
|---|---|---|---|
| App shell + auth (`/`, shell, user chip) | Current user, logout URL, login URL/config, 401 vs 403 handling, one user WS. | **Partial.** `GET /api/v1/me`, `GET /api/v1/me/logout-url`, and `/api/v1/user-ws` exist. | **Backend follow-up:** public UI bootstrap/config for `login_url` and `logout_url` usable before auth. Current logout URL requires auth. **UI adapter:** map 401 to unauthenticated landing/login redirect; do not redirect on 403. |
| Sidebar conversation tree (`/conversations`) | Conversation summaries grouped by project → `agent_id` → session; session/agent/project unread rollups; default `Conversations` project metadata. | **Partial.** `GET /api/v1/chats` returns conversation summaries with `conversation_id`, `agent_id`, `agent_instance_id`, `chain_id`, title, unread count, preview/timestamps. `GET /api/v1/projects` exists. | **Backend follow-up:** include `project_id`/project name on chat summaries or support `expand=project`; expose aggregate unread rollups by project/agent/session or accept client-side grouping after fetching instances/projects. **Safe temporary assumption:** group by conversation `agent_id` and fetch bound instance/project when needed; project rollups may be chat-only until task/artifact counts exist. |
| New conversation launch (`/conversations/new`) | Agent selection, Bridge/provider/tier/project controls, first-send transaction creating TaskChain + AgentInstance + ChatConversation, initial attachments. | **Ready/Partial.** `POST /api/v1/chats` supports first-send creation via `agent_id` launch params and creates instance+conversation; `POST /api/v1/agent-instances` can launch an empty conversation. `GET /api/v1/agents`, `/bridges`, `/agents/{id}/bridge-support`, `/projects` support controls. | **UI adapter:** use `/api/v1/chats` for composer first-send; use `/api/v1/agent-instances` for explicit launch without initial body. **Backend follow-up:** document/accept `initial_message.artifact_ids` or standardize top-level `artifact_ids`; add `Idempotency-Key` behavior for first-send/launch if not already enforced. |
| Conversation page (`/conversations/:conversation_id`) | Chat messages, send, mark read, bound instance, immutable chain, restart/reconfigure. | **Ready/Partial.** Message list/send/read exist by `conversation_id`; instance detail/restart/stop/reconfigure and chain detail/tasks exist. | **UI adapter:** current legacy UI fetches by `agentInstanceId`; rewrite must route and cache by `conversation_id`. **Backend follow-up:** response should include enough bound ids (`project_id`, `chain_id`, `agent_instance_id`) in chat summary/detail; current summary lacks `project_id`. |
| ChatComposer attachments + mentions | Upload artifacts before send, progress/retry/remove, send `artifact_ids`; `@category:id` autocomplete for agent/task/task-chain/memory/project/artifact. | **Partial.** Artifact create exists and chat messages accept `artifact_ids`. Resource list endpoints exist for bounded fallback autocomplete. | **Backend follow-up:** global search endpoint `task-19f8ed3ac87` / UI-18 (`GET /api/v1/search`) for production mention autocomplete; optional structured `mentions` field if clickable/validated mention storage is required. **Safe temporary assumption:** body-only mentions and bounded fan-out search can be used narrowly for beta, but not as an unbounded search-as-you-type implementation. |
| Conversation Work chip/current task/inspector Work tab | Chain detail, creation-ordered task list, review-needed count/current task inference. | **Partial.** Chain detail and chain task list exist; task statuses expose enough state for inference. | **Backend follow-up:** optional conversation summary fields (`current_task_id`, `review_needed_count`) to avoid fetching tasks for each session; WS publishers for task changes. **Safe temporary assumption:** infer after opening the conversation and loading its chain tasks. |
| Chain list/detail (`/chains`, `/chains/:chain_id`) | Chain list/detail, tasks in creation order, selected task, comments, legal transitions, nudge, vote, assignee/reviewer pickers, add agent to chain. | **Partial.** Chain list/detail/create/publish/complete exist. Task list/create/publish/status/nudge exist. Add agent to existing chain is supported via `POST /api/v1/agent-instances` with `chain_id`. | **Backend follow-up:** route for task detail by id or documented lookup from chain list; `GET/POST task comments`; task update endpoint; assign/reviewer update endpoint; reviewer vote endpoint or audit record if status-only voting is insufficient; same-chain actor picker helper or reliable filters on `GET /agent-instances?chain_id=...`. |
| Task comments vs chat messages | Separate task comments thread and chat messages. | **Backend follow-up.** Chat message routes exist; current registered routes do not include task comments even though the architecture doc specifies them. | Add `GET /api/v1/task-chains/{chain_id}/tasks/{task_id}/comments`, `POST .../comments`, comment resolve if still needed, and WS/resource invalidation for task comments. Do not reuse chat messages as task comments. |
| Agent list/detail (`/agents`, `/agents/:agent_id`) | Agent identities, overview, sessions/instances, Bridges support, memory. | **Ready/Partial.** Agents CRUD/archive, agent instances list/detail, Bridge support CRUD, and memory list/detail exist. | **UI adapter:** current `agents.ts` calls legacy endpoints and federation helpers; replace with `/api/v1/agents` + `/api/v1/agent-instances`. **Backend follow-up:** filters/expansions on list instances (`agent_id`, `chain_id`, `project_id`) and memory filtering by `agent_id` if current handler ignores query filters. |
| Library and artifact viewer (`/library`, `/library/artifacts/:artifact_id`) | Filterable artifacts, content viewer, upload, download, rename/description, delete, versions, rollback, annotations. | **Partial.** Implemented `/api/v1/artifacts` operations: list (GET), create (POST), detail (GET `{id}`), content (GET `{id}/content`), rename/description (PATCH `{id}`), delete (DELETE `{id}`). | **UI adapter (task-19f8ec91231 / UI-10):** Library filters (kind/agent/project/chain/search) applied client-side from list provenance; viewer is fullscreen with kind-aware rendering (markdown/json/diff/text/image w/ pinch-zoom-pan/binary fallback); rename/edit-description via PATCH + delete via DELETE `/api/v1/artifacts/{id}` (Bearer). **Backend GAPS (deferred v1, tracked as UI-BE-4):** server-side list filters (`project_id`, `agent_id`, `agent_instance_id`, `chain_id`, `task_id`, `kind`); versions, rollback, and annotations list/create/update/delete are NOT served by the Hub `/api/v1` surface (only by the legacy daemon `/artifacts/*` routes, which the rewrite must not depend on). The viewer's version-selector/rollback/annotation surfaces therefore run against unserved routes and are deferred until UI-BE-4 lands; rename/description + delete + download + view DO work against the Hub. |
| Settings → Bridges | Bridge list/detail, enrollments, rename, revoke, capabilities, instances, path overrides. | **Ready/Partial.** Bridge list/detail/rename/revoke and enrollment create/list/revoke exist; project bridge paths exist. | **UI adapter (task-19f8ec91375 / UI-11):** new `bridgeSupport` endpoint module (fetchBridgeDetail, renameBridge, revokeBridge, createBridgeEnrollment, listBridgeEnrollments, revokeBridgeEnrollment, project bridge-path PUT/DELETE/validate); new `settings/BridgesPanel.tsx` renders list + enrollment ceremony (one-time token, copy, secret warning) + rename (PATCH) + revoke (= "remove", POST /revoke). **Backend follow-up:** token rotation (`POST /bridges/{id}/rotate-token`) is specified in architecture but NOT registered; capability refresh is indirect via Bridge runtime heartbeat only. UI surfaces a backend-gap note for rotate-token. |
| Settings → Projects | List/create/update project, default path, per-Bridge overrides, path validation, default `Conversations` project not deletable. | **Ready/Partial.** Project list/create/detail/update and bridge path override/validate exist. | **UI adapter (task-19f8ec91375 / UI-11):** ProjectsPanel extended with `ProjectBridgePathsSection` (per-bridge override PUT, clear DELETE, validate POST); validation is advisory-only and never blocks launch. **Backend follow-up:** explicit marker for default `Conversations` project (`is_default_conversations`, not deletable) if UI needs enforcement copy beyond name/slug convention; delete project is not currently registered and should remain absent for default project. |
| Settings → Providers/provider profiles | Read-only provider/profile inspection and refresh capabilities. | **Partial.** Bridge `capabilities` expose provider/default tier summary; agent/bridge-support exposes provider/tier policy. | **Backend follow-up:** dedicated provider profile endpoint or richer Bridge capabilities shape with tiers, profile labels, status, and refresh action if Settings must show more than current provider/default tier. |
| Settings → Global memory | Memory list/detail/propose/approve/reject/archive. | **Partial.** List/create/detail/approve/reject/archive exist. | **Backend follow-up:** memory proposal workflow/history endpoints if UI requires proposal review/history; current `/api/v1` does not expose history. **UI adapter:** legacy `memory.ts` uses old proposal/action endpoints and must map to supported v1 operations. |
| Settings → Templates/defaults | Template list/create; account/default agent settings. | **Partial.** `GET/POST /api/v1/templates` exists. | **Backend follow-up:** update/archive templates, defaults/preferences, and provider defaults if Settings keeps those panels. Current legacy preferences/default-agent endpoints are not `/api/v1`. |
| Command palette | Unified navigation/entity/action search and mention autocomplete. | **Ready.** `GET /api/v1/search` is registered in the Hub (`src/hub/app/wiring.odin`) and serves grouped hits (conversation/agent/agent_instance/task-chain/task/project/artifact/memory) with id/label/sublabel/score/route. Optional `POST /api/v1/batch/get` remains a separate optimization (not required for v1). | **UI adapter (task-19f8ec915a2 / UI-12):** new `search.ts` endpoint module consuming `GET /api/v1/search` (q/types/limit); new `command-palette/CommandPalette.tsx` unifies Navigate + entity search + Actions with debounce (RTK Query keeps only latest arg → cancels superseded requests) and keyboard-first nav (↑/↓/Enter/Esc). Invocations: Cmd/Ctrl-K, sidebar Search button, mobile bottom-tab center button. No client fan-out over list endpoints. **Backend follow-up:** optional `POST /api/v1/batch/get` for post-selection hydration; UI-18 (`task-19f8ed3ac87`) may refine search ranking/indexing but the production endpoint is already served. |
| Responsive/mobile | Same data needs as desktop; no backend-specific extra routes. | **Ready.** | No backend gap. Mobile uses the same route IDs and `/api/v1` adapters (UI-13, `task-19f8ec9175c`): shared `shell/responsive.tsx` primitives (`useViewport`, `useKeyboardInset`, `MobileTabBar`, `MobileTopBar`, `MobileBackHeader`, `MobileInspectorSheet`, `TOUCH_TARGET_CLASS`); sidebar = off-canvas drawer; right inspector = bottom sheet reusing the canonical `workspace-inspector` debug-id; chain list/detail = drill-down; keyboard/safe-area-aware bottom-pinned composer; `data-debug-id` values are layout-independent. |
| Data layer + user WS invalidation | RTK Query tags, one `/api/v1/user-ws`, resource invalidations for chat/task/agent/artifact/memory/project/bridge. | **Partial.** WebSocket route exists (`src/hub/app/wiring.odin` → `GET /api/v1/user-ws`, cookie-auth via trusted proxy); source currently publishes `agent_instance` changes. | **Backend follow-up:** publish resource_changed for chats/messages, task chains/tasks/comments, artifacts, memories, projects, bridges/enrollments; define summary payloads or require refetch-only semantics. **UI adapter (task-19f8ec91910 / UI-14):** RTK Query is the server-state layer (`heimdallApi.ts`); new cookie-auth `endpoints/sidebar.ts` (`listSidebarConversations` / `listSidebarProjects`) replaces the shell's raw `fetch` for sidebar/unread data; new `api/useUserWebSocket.ts` owns exactly ONE `/api/v1/user-ws` connection from the shell (cookie-auth, no client token in URL, unlike legacy `/user-ws/{instance}`) and routes all events through the single `wsInvalidation.handleUserWsEvent` path (patch-in-place where safe, scoped-tag invalidate otherwise, full resync on reconnect); `SidebarConversations` tag invalidated on chat events so unread badges refresh live. Existing token-session endpoints (`withSessionQuery`) remain for legacy surfaces and are not in the live shell data path. |
| Legacy cleanup | Remove guide/workspace/attention/proxy/federation surfaces. | **Ready.** | Do not depend on backend legacy routes. Delete unused legacy endpoint modules only after `/api/v1` replacements exist. **Status (task-19f8ec91aa4 / UI-15):** the LIVE app (`main.tsx` -> `AppShell`) mounts only rewrite surfaces; no excluded legacy surface (UnifiedWorkspaceShell, guide panel, home/onboarding hero, standalone Memory/Attention pages, proxy wizards, VimSidebar, ChainEditor graph editing, audit sidebar) is reachable from the live mount path. Genuinely-dead files with no importer (incl. no test) were deleted (`AuditSidebar.tsx`, `AuditCard.tsx`) along with their orphaned thunks/endpoint functions (`taskSlice.fetchUnreviewedChains`/`evaluateTaskChain` -> no-op stubs; `daemonApi.listUnreviewedTaskChains`/`evaluateTaskChain` removed). **Known follow-up:** the large unmounted `App.tsx` refactor source is retained because ~26 prior-task static guards encode their acceptance as App.tsx marker checks; deleting it wholesale is a dedicated follow-up that must migrate those guards off App.tsx first. `test_unified_workspace_shell_static.py` (UAW-* legacy REQs) guards removed legacy surfaces and is a pre-existing failure unrelated to this task. |

## 5. Task status and review enum mapping

Current Hub source serializes task statuses from `src/hub/transport/http/taskchain_handlers.odin` as:

| Backend status | UI label | UI behavior |
|---|---|---|
| `assigned` | Queued / Assigned | Work is not yet actively in progress. Show start/publish/status actions when legal. |
| `in_progress` | In progress | Assignee owns next action. Nudge targets assignee. |
| `in_validation` | Review needed | Reviewer owns next action. Conversation header Review-needed chip counts tasks in this state. |
| `validated_good` | Approved / LGTM | Review accepted. May unblock completion or dependent work. |
| `validated_not_good` | Changes requested / NGTM | Review rejected. UI should show rework/action state and allow returning to in_progress if legal. |
| `paused` | Paused | Not active; do not count as review-needed. |
| `completed` | Completed | Done. |
| `cancelled` | Cancelled | Terminal/cancelled. |

Task chains serialize as `active`, `completed`, `cancelled`; publish state serializes as `draft` or `published`.

Review/vote gap:

- Current registered Hub routes include `POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/status` but not a dedicated vote route.
- UI vote buttons can temporarily map LGTM to `validated_good` and NGTM to `validated_not_good` **only if** product accepts status-only review without durable per-reviewer votes/comments.
- If UI-8 requires durable vote records, reviewer comments, or multiple reviewer tallying, add a backend follow-up for `POST .../vote` (or equivalent) and task comments before marking Chain view complete.

## 6. Conversation launch needs

Conversation launch can use real backend behavior now, with request-shape clarifications:

- **First-send composer:** call `POST /api/v1/chats` with `agent_id`, optional `bridge_id`, `provider`, `tier`, `project_id`, optional existing `chain_id`, `initial_message.body`, and attachment ids.
- **Agent detail Launch instance:** call `POST /api/v1/agent-instances` without `chain_id` to create a private/default chain + conversation, then navigate to returned `conversation_id`.
- **Add agent to chain:** call `POST /api/v1/agent-instances` with existing `chain_id`, then select the returned `agent_instance_id` for assignee/reviewer choices if allowed.
- **Locked chips:** after creation, use returned immutable `agent_instance_id`, `conversation_id`, `chain_id`, `bridge_id`, `provider`, `tier`, and `project_id`; later provider/tier changes must use `PATCH /api/v1/agent-instances/{instance_id}` or restart controls.

Gaps:

- Standardize attachments in the first-send request. The current handler parses top-level `artifact_ids`; the architecture text describes `initial_message.artifact_ids`.
- Add/document idempotency for first-send and `POST /agent-instances` to protect against double-submit.
- Include `project_id` in chat summary/detail responses for sidebar grouping and launch chip display.

## 7. Artifact/library needs

Basic artifact support is usable now:

- Upload/create metadata and content through `POST /api/v1/artifacts`.
- List with `GET /api/v1/artifacts`.
- Fetch metadata/content with `GET /api/v1/artifacts/{id}` and `/content`.
- Rename/description with `PATCH /api/v1/artifacts/{id}`.
- Delete with `DELETE /api/v1/artifacts/{id}`.
- Attach to chat messages with `artifact_ids`.

Unsupported for UI-10 as written:

- filterable list by `project_id`, `agent_id`, `agent_instance_id`, `chain_id`, `task_id`, kind, deleted state;
- binary-safe streaming/download and content disposition;
- artifact versions;
- rollback;
- annotations list/create/update/delete;
- artifact provenance/used-by summary if the Library needs to show where an artifact appears.

Recommended follow-up tasks:

1. Add artifact list filters and provenance fields to `/api/v1/artifacts`.
2. Add binary-safe download/content support.
3. Add version and rollback endpoints.
4. Add annotation endpoints and schema.

Until those are approved, do not fake versions/rollback/annotations as working. The UI may render disabled controls with explanatory copy or defer those controls within UI-10.

## 8. Backend endpoints supported but unused by planned UI

These are implemented or registered but should either be intentionally consumed, hidden from browser UI, or deferred:

| Endpoint | Recommendation |
|---|---|
| `GET /api/v1/health` | Use for diagnostics/dev settings only; not part of core navigation. |
| `GET /api/v1/templates`, `POST /api/v1/templates` | Surface in Settings/Agents if template creation remains in scope; otherwise leave as API-only for now. |
| `POST /api/v1/task-chains/{chain_id}/publish`, `POST /api/v1/task-chains/{chain_id}/complete`, `POST /api/v1/task-chains/{chain_id}/tasks/{task_id}/publish` | Use from Chain view legal transitions if draft/publish states are exposed. |
| Bridge enrollment endpoints | Use in Settings → Bridges enrollment flow. |
| `POST /api/v1/bridges/enroll` | Not for browser UI except showing setup command; used by `ham-bridge` with bearer enrollment token. |
| `GET /api/v1/bridge-ws` | Not for browser UI; Bridge runtime only. |
| `GET /api/v1/bridge/agent-instances/{id}/bootstrap` | Not for browser UI; Bridge bootstrap only. |
| Agent bridge-support CRUD | Use in Agent detail Bridges tab and launch capability constraints. |
| Project bridge-path override/validate | Use in Settings → Projects/Bridges. |

## 9. Recommended follow-up task list

These are proposed backend/data-layer follow-ups discovered for UI-17. They can be created as separate tasks when the coordinator decides scope/order.

1. **UI-BE-1 Auth config:** add public UI config/bootstrap endpoint with `login_url` and logout destination semantics suitable for unauthenticated landing.
2. **UI-BE-2 Conversation summaries:** add `project_id`/project display fields, grouped/unread rollups, and optional `current_task_id`/`review_needed_count` summary fields.
3. **UI-BE-3 Task detail/comments/review:** add task detail/update/comment/assignment/reviewer/vote APIs or formally approve status-only review and no comments for v1.
4. **UI-BE-4 Artifact advanced features:** add filters, download, versions, rollback, annotations, and provenance support required by UI-10.
5. **UI-BE-5 Search/batch (`task-19f8ed3ac87`, UI-18):** add `GET /api/v1/search` for command palette task `task-19f8ec915a2`, sidebar search, and mention autocomplete. Requirements from the follow-up task: optimize for search-as-you-type; accept one-character `q`; empty/whitespace `q` returns empty or optional recent/suggested results without error; target sub-100ms p95 server time for short queries; select only compact hit fields; avoid expensive joins and per-hit N+1 queries; prefix/word-boundary matches rank above interior substring matches; matching is case-insensitive; very short queries are recency/usage biased and bounded; enforce per-group limits and hard scan caps; use indexed lowercased name/title/slug/id columns or a repository-owned search index/table rather than scanning message/body/artifact content; deterministic ranking; pure idempotent `GET`; repository-layer ownership of search/index details; no response-shape changes. Optional `POST /api/v1/batch/get` remains useful for post-selection hydration.
6. **UI-BE-6 Provider profiles:** expose richer provider profile/capability inspection and refresh semantics if Settings requires it.
7. **UI-BE-7 WS publishers:** publish `resource_changed` for all resources used by RTK Query, not only `agent_instance`.
8. **UI-DL-1 Frontend adapter:** replace legacy `daemonApi` calls with `/api/v1` RTK Query endpoint modules and remove query/body token assumptions.

## 10. No-mock policy for unsupported needs

For implementation tasks after UI-17:

- Use real `/api/v1` endpoints wherever marked Ready/Partial.
- If a required control depends on a Backend follow-up, render a disabled/deferred state or leave the feature behind an explicit TODO tied to a task id; do not create fake successful local-only mutations.
- Client-side derivation is acceptable only for documented safe temporary assumptions, such as current-task inference after loading a chain or beta fan-out search over already available list endpoints.
- Legacy UI endpoint modules may be used as refactor references, not as production data paths for the rewrite.
