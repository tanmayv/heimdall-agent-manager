# UI Request Layer Plan — RTK Query + Targeted WS Invalidation

Goal: stop high-refresh UI areas from spamming local/remote daemons, and stop each WebSocket event from triggering broad "refetch everything" fan-out. Move all recurring read/cache/dedupe/invalidation into a single cache authority instead of hand-orchestrating fetches in components and thunks.

Rule:

```text
component renders a hook / requests intent
  -> RTK Query owns fetch + dedupe + cache + invalidation
  -> WS events invalidate ONLY the exact cache entries that changed
  -> Redux store renders UI
```

Components should not chain low-level refreshes such as:

```ts
dispatch(updateSelectedTaskStatus(...))
dispatch(fetchTasksForChain(...))
dispatch(fetchSelectedTaskLog(...))
```

And WS handlers should not do broad fan-out such as:

```ts
// current App.tsx pattern — refetches whole surfaces per event
dispatch(refreshAgents())
dispatch(refreshMemory())
dispatch(fetchTasksForChain(chainId))
dispatch(refreshTaskBoard())
```

They should express one thing:

```ts
// component
const { data } = useFetchTaskLogQuery({ taskId })
const [setStatus] = useSetTaskStatusMutation()

// WS handler — surgical, entry-level invalidation
api.util.invalidateTags([{ type: 'TaskLog', id: taskId }, { type: 'ChainTasks', id: chainId }])
```

---

## Why RTK Query instead of a hand-rolled request coordinator

`@reduxjs/toolkit@2.2.8` and `react-redux@9.1.2` are already dependencies. RTK Query already provides — natively and battle-tested — everything a custom `RequestCoordinator` would reimplement:

| Need | Hand-rolled coordinator (rejected) | RTK Query (chosen) |
|------|-----------------------------------|--------------------|
| request key | `task-log:first:task-123` strings | endpoint + serialized args (automatic) |
| in-flight coalescing | manual map | automatic |
| short TTL cache | manual timestamps | `keepUnusedDataFor` |
| invalidate by prefix | manual prefix scan | `providesTags` / `invalidatesTags` |
| force refresh | `force: true` flag | `refetch()` / `initiate(..., { forceRefetch })` |
| non-overlapping polling | manual guards | `pollingInterval` (coalesced) |
| focus/reconnect revalidation | manual listeners | `refetchOnFocus` / `refetchOnReconnect` |
| optimistic send + rollback | manual | `onQueryStarted` optimistic updates |
| WS event → refresh | manual `dispatch(fetchX)` | `api.util.invalidateTags([...])` |
| telemetry | manual counters | DevTools + `getRunningQueries` |

The current codebase already half-builds this in `taskSlice` (`TASK_LOG_RELOAD_DEDUPE_MS`, `taskLogLoadingByTaskId`, `taskLogLoadedAtByTaskId`, `condition:` gates) and `chatSlice`. RTK Query replaces those bespoke maps with one consistent mechanism, so we delete duplicated dedupe logic rather than adding a fourth data layer on top of it.

The current storm has two root causes, and this plan targets both:

1. Three independent triggers (route change, periodic/reconnect revalidation, WS events) hit the same resources with no shared cache. → RTK Query cache dedupes across all three.
2. Each WS event refetches whole surfaces. → We switch to entry-level tag invalidation keyed by the IDs in the event payload.

---

## Tag model (the core design)

Every cache entry is tagged by a concrete ID so WS events can invalidate precisely one entry. No `LIST`-only tags for high-refresh resources — always include the specific id when the event carries one.

```text
Tag types and ids:
  TaskLog      id = taskId
  Task         id = taskId
  TaskComments id = taskId (only if comments become a separate endpoint)
  ChainTasks   id = chainId
  Chain        id = chainId
  ChainList    id = 'ALL' or filter key
  Chat         id = agentInstanceId
  GuideChat    id = GUIDE_AGENT_ID
  CoordinatorChat id = chainId
  ConversationSummaries id = 'ALL'
  Agents       id = 'ALL' (list), agentInstanceId (single)
  AgentTemplate id = templateId
  Team         id = teamId
  Memory       id = memoryId, and 'ALL' for the list
  MemoryHistory id = memoryId (only if history gets RTKQ endpoint)
  Project      id = projectId
  Projects     id = 'ALL'
  Workspace    id = chainId
  WorkspaceDiff id = `${chainId}:${file}`
  Artifact     id = artifactId
  ArtifactContent id = artifactId (only if content fetch moves into RTKQ)
  Preferences  id = 'ALL' or preference key
  ChatApprovals id = 'ALL'
  MergeDecisions id = 'ALL'
  Attention    id = 'ALL'
```

---

# Daemon API audit — single-resource fetch availability

RTK Query should prefer single-resource endpoints whenever a WS payload identifies one changed resource. The current daemon/UI API already supports most of the needed reads.

| Resource | Single-resource fetch exists? | Current UI helper | Daemon route/action | RTK Query tag to use | Notes |
|----------|-------------------------------|-------------------|---------------------|----------------------|-------|
| Task | Yes | `fetchTask({ taskId })` | `GET /tasks/{task_id}` | `Task:<taskId>` | Use for task detail patches/refetches. Do not refetch all tasks when a `task_event` carries `task_id`. |
| Task log/events | Yes | `fetchTaskLog({ taskId, cursor })` | `POST /user-rpc action=task_log` | `TaskLog:<taskId>` | Cursor/page aware. Invalidate only the affected task log, and only when the event affects the open/subscribed task. |
| Task comments | Yes | `fetchTaskComments({ taskId })` | `GET /tasks/{task_id}/comments` | `TaskComments:<taskId>` if added | Currently separate from task log. Add a tag only if comments become their own RTKQ endpoint. |
| Task chain | Yes | `fetchTaskChain({ chainId })` | `GET /task-chains/{chain_id}` | `Chain:<chainId>` | Use for chain metadata/title/status changes. |
| Chain task list | Scoped list by chain | `listChainTasks({ chainId })` | `GET /task-chains/{chain_id}/tasks` | `ChainTasks:<chainId>` | This is the right granularity for board/task-list refreshes; never refetch every chain's tasks from one chain event. |
| Task chain list | List only | `listTaskChains` / `fetchTaskChains` | `GET /task-chains?...` | `ChainList:<filter>` | Invalidate only when list membership/order/filter result changes (create/archive/status filter boundary), not on normal task events. |
| Agent instance | Yes | `showAgent({ agentInstanceId })` | `POST /agents/show` | `Agents:<agentInstanceId>` or `Agent:<agentInstanceId>` | Available but not REST-shaped. Good enough for RTKQ. Gap: no `GET /agents/{id}` and no durable `agent_id` show helper. |
| Agent list | List/page | `listKnownAgents` / `listKnownAgentsPage` | `GET /agents?...` | `Agents:ALL`, optionally project-scoped | Runtime/lifecycle WS events should patch/update one list row or invalidate one agent, not full list unless membership changed. |
| Agent template | Yes | `showAgentTemplate({ templateId })` | `POST /agents/templates/show` | `AgentTemplate:<templateId>` | Templates are low-frequency. |
| Team | Yes | `fetchTeam({ teamId })` | `GET /teams/{team_id}` | `Team:<teamId>` | Useful for chain roster refreshes. |
| Direct/agent chat messages | Scoped conversation page | `fetchChat({ agentInstanceId, cursor })` | `GET /chats/{agent_id}/messages` | `Chat:<agentInstanceId>` | No single-message fetch. WS `chat_event` with inline `message` should patch cache; otherwise invalidate that conversation only. |
| Coordinator chat | Scoped by `chain_id` filter | `fetchChat({ agentInstanceId, chainId, cursor })` / coordinator flows | `GET /chats/{agent_id}/messages?chain_id=...` and send coordinator route | `CoordinatorChat:<chainId>` | If coordinator agent id is needed, endpoint args should include it, but tag should be chain-scoped. |
| Conversation summaries | List only | `listConversations` | `POST /user-rpc action=list_chats` | `ConversationSummaries:ALL` | Invalidate after chat events/sends/read changes; no single summary route today. |
| Memory record | Yes | `showMemory({ memoryId })` | `POST /user-rpc action=memory_show` / `POST /memory/show` | `Memory:<memoryId>` | `memory_event` with `memory_id` should invalidate/patch this only. Invalidate `Memory:ALL` only on list membership/filter changes. |
| Memory history | Yes | `memoryHistory({ memoryId })` | `POST /user-rpc action=memory_history` | `MemoryHistory:<memoryId>` if added | Low frequency. |
| Project | Yes | `showProject({ projectId })` | `POST /user-rpc action=project_show` / `POST /projects/show` | `Project:<projectId>` | Good single-record support. |
| Project list | List only | `listProjects` | `POST /user-rpc action=project_list` | `Projects:ALL` | Invalidate on create/delete/reorder; patch list row on update if record is returned. |
| Workspace state | Chain-scoped | `fetchWorkspace({ chainId })` | `GET /chains/{chain_id}/workspace` | `Workspace:<chainId>` | Good granularity for merge/workspace WS events. |
| Workspace diff | Chain/file-scoped | `fetchWorkspaceDiff({ chainId, file })` | `GET /chains/{chain_id}/workspace/diff?file=...` | `WorkspaceDiff:<chainId>:<file>` | Large payload; never refresh all diffs after one file event. |
| Artifact metadata | Yes | `fetchArtifactMeta({ artifactId })` | `GET /artifacts/{artifact_id}` | `Artifact:<artifactId>` | Good single-record support. |
| Artifact content | Yes | `artifactContentUrl({ artifactId })` | `GET /artifacts/{artifact_id}/content` | `ArtifactContent:<artifactId>` if proxied via RTKQ | URL helper today; content can remain one-shot or move to RTKQ if viewer caching is needed. |
| Preferences/settings | Key delete exists; list read only | `fetchPreferences`, `savePreference`, `resetPreference` | `GET /preferences`, `POST /preferences`, `DELETE /preferences/{key}` | `Preferences:ALL` or `Preference:<key>` | No single preference GET, but low frequency. |
| Attention/approvals | Aggregate/list | `fetchAttention`, `listPendingChatApprovals` | `GET /attention`, `GET /chat-approvals/pending` | `Attention:ALL`, `ChatApprovals:ALL`, `MergeDecisions:ALL` | Aggregates are acceptable, but WS should invalidate only the affected aggregate, not unrelated task/chat/agent data. |

## API gaps to account for

- There is no REST-style `GET /agents/{agent_instance_id}`. Use existing `POST /agents/show` for now; optionally add a REST route later for consistency.
- There is no dedicated durable-agent-identity `showAgentIdentity(agentId)` UI helper. `showAgent` is instance-oriented. If the Agents tab needs identity-only RTK cache entries, add a daemon route/helper rather than filtering `listKnownAgents` repeatedly.
- There is no single chat-message fetch. This is fine if `chat_event` payloads include the message body; otherwise invalidate only the conversation page (`Chat:<agentId>` / `CoordinatorChat:<chainId>`).
- Task chain list and conversation summaries are list-only. Invalidate them only when list membership, ordering, unread counts, or summary fields change.
- Existing mutation responses vary in how much updated record data they return. Prefer patching RTKQ cache from returned records when available; otherwise invalidate only the precise affected tags.

Implementation implication: the RTKQ migration does **not** require broad daemon API expansion. It mostly needs endpoint wrappers around existing single-resource routes and careful WS tag mapping.

---

# Phase 1 — Introduce the RTK Query API slice

Add:

```text
src/ui/api/heimdallApi.ts        # createApi root: baseQuery, tagTypes, empty endpoints
src/ui/api/endpoints/tasks.ts    # injectEndpoints
src/ui/api/endpoints/chats.ts
src/ui/api/endpoints/agents.ts
src/ui/api/endpoints/memory.ts
src/ui/api/endpoints/workspace.ts
src/ui/api/endpoints/attention.ts
src/ui/api/wsInvalidation.ts     # maps WS events -> invalidateTags
```

## `heimdallApi.ts`

```ts
import { createApi, fakeBaseQuery } from '@reduxjs/toolkit/query/react';

// Reuse existing daemonApi.ts functions inside a custom baseQuery so we do not
// rewrite request/response handling. fakeBaseQuery + queryFn per endpoint keeps
// the existing session (daemonUrl/clientToken) plumbing intact.
export const heimdallApi = createApi({
  reducerPath: 'heimdallApi',
  baseQuery: fakeBaseQuery(),
  tagTypes: [
    'TaskLog', 'Task', 'TaskComments', 'ChainTasks', 'Chain', 'ChainList',
    'Chat', 'GuideChat', 'CoordinatorChat', 'ConversationSummaries',
    'Agents', 'AgentTemplate', 'Team',
    'Memory', 'MemoryHistory', 'Project', 'Projects',
    'Workspace', 'WorkspaceDiff', 'Artifact', 'ArtifactContent',
    'Preferences', 'ChatApprovals', 'MergeDecisions', 'Attention',
  ],
  keepUnusedDataFor: 30,          // default cache lifetime (s)
  refetchOnReconnect: true,
  endpoints: () => ({}),
});
```

Wire into the store:

```ts
// store.ts
reducer: {
  ...existing,
  [heimdallApi.reducerPath]: heimdallApi.reducer,
},
middleware: (gDM) => gDM().concat(actionLogger, heimdallApi.middleware),
```

Add `setupListeners(store.dispatch)` for focus/reconnect revalidation.

## `queryFn` pattern

Each endpoint's `queryFn` reads session from `getState()` and delegates to the existing `daemonApi` function, so we do not duplicate transport:

```ts
queryFn: async ({ taskId, cursor = 0 }, { getState }) => {
  const { session } = (getState() as any).chat;
  const data = await daemonApi.fetchTaskLog({
    daemonUrl: session.daemonUrl,
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
    taskId, limit: 50, cursor,
  });
  return { data: normalizeTaskLog(data, cursor) };
},
```

---

# Phase 2 — Task endpoints

```ts
fetchTaskLog: build.query<TaskLogPage, { taskId: string; cursor?: number }>({
  queryFn: ...,
  providesTags: (_r, _e, { taskId }) => [{ type: 'TaskLog', id: taskId }],
  // For infinite log, use RTKQ infiniteQuery or merge in a serializeQueryArgs
  // that drops cursor + a merge() that appends pages.
}),

fetchChainTasks: build.query<Task[], { chainId: string }>({
  queryFn: ...,
  providesTags: (r, _e, { chainId }) => [
    { type: 'ChainTasks', id: chainId },
    ...(r ?? []).map((t) => ({ type: 'Task' as const, id: t.taskId })),
  ],
}),

setTaskStatus: build.mutation<void, { taskId: string; chainId: string; status: string; body: string }>({
  queryFn: ...,
  invalidatesTags: (_r, _e, { taskId, chainId }) => [
    { type: 'TaskLog', id: taskId },
    { type: 'Task', id: taskId },
    { type: 'ChainTasks', id: chainId },
  ],
}),
```

Same pattern for `addTaskComment`, `assignTask`, `setReviewer`, `voteTask`, `nudgeTask`, `updateTask`.

Key rules:

- Mutations declare `invalidatesTags` for exactly the entries they change. The follow-up refetch is automatic and coalesced — no manual `dispatch(fetchSelectedTaskLog({ force: true }))`.
- Pagination uses RTK Query `infiniteQuery` (RTKQ 2.x) or a merge strategy; older pages are never invalidated by TTL.

## Component migration targets

- `ChainView`, `TaskTodoList`, `ChainEditor`, attention task actions.
- Replace `dispatch(fetchSelectedTaskLog(...))` / `dispatch(fetchTasksForChain(...))` chains with `useFetchTaskLogQuery` / `useFetchChainTasksQuery` + mutation hooks.

---

# Phase 3 — Chat endpoints

```ts
fetchChat: build.query<ChatPage, { agentInstanceId: string; cursor?: number }>({
  providesTags: (_r, _e, a) => [{ type: 'Chat', id: a.agentInstanceId }],
}),
fetchGuideChat: build.query<ChatPage, { cursor?: number }>({
  providesTags: [{ type: 'GuideChat', id: GUIDE_AGENT_ID }],
}),
fetchCoordinatorChat: build.query<ChatPage, { chainId: string; cursor?: number }>({
  providesTags: (_r, _e, a) => [{ type: 'CoordinatorChat', id: a.chainId }],
}),
listConversationSummaries: build.query<Summary[], void>({
  providesTags: [{ type: 'ConversationSummaries', id: 'ALL' }],
}),
```

Sending uses `onQueryStarted` optimistic update against the relevant `Chat`/`GuideChat`/`CoordinatorChat` cache entry, then relies on the WS `chat_event` to confirm — no forced full reload.

Mark-read is a request policy on the query (argument), not component logic.

## Component migration targets

- `AgentDetailPage`, guide side panel, chain coordinator chat, sidebar conversation list, chat approval / attention chat actions.

---

# Phase 4 — Targeted WebSocket invalidation

This is the second core deliverable. Replace the broad fan-out in `App.tsx` `socket.onmessage` with a single mapping module that invalidates only the entries named in the event.

## `wsInvalidation.ts`

```ts
export function handleWsEvent(payload: any, dispatch: AppDispatch, ctx: { focusedChainId?: string; selectedAgentId?: string }) {
  switch (payload?.type) {
    case 'task_event': {
      const taskId = payload.task?.task_id;
      const chainId = payload.chain_id ?? payload.chain?.chain_id ?? payload.task?.chain_id;
      // Patch known records directly; do not refetch the world.
      if (payload.task) dispatch(heimdallApi.util.upsertQueryData('fetchTask', { taskId }, normalizeTask(payload.task)));
      const tags: any[] = [];
      if (taskId) tags.push({ type: 'Task', id: taskId }, { type: 'TaskLog', id: taskId });
      if (chainId) tags.push({ type: 'ChainTasks', id: chainId });
      // Only invalidate TaskLog if that task's log is actually mounted/subscribed.
      dispatch(heimdallApi.util.invalidateTags(tags));
      return;
    }
    case 'chat_event': {
      const agentId = payload.agent_instance_id ?? '';
      const chainId = payload.chain_id ?? '';
      // If we got the message inline, append optimistically; else invalidate one entry.
      if (payload.message && agentId) {
        dispatch(appendChatMessage({ agentId, message: payload.message })); // patchQueryData
      } else if (chainId) {
        dispatch(heimdallApi.util.invalidateTags([{ type: 'CoordinatorChat', id: chainId }]));
      } else if (agentId) {
        dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: agentId }]));
      }
      dispatch(heimdallApi.util.invalidateTags([{ type: 'ConversationSummaries', id: 'ALL' }]));
      return;
    }
    case 'memory_event': {
      const memId = payload.memory_id;
      if (memId) dispatch(heimdallApi.util.invalidateTags([{ type: 'Memory', id: memId }]));
      // Only touch the list on add/remove, not on in-place status changes.
      if (payload.change === 'created' || payload.change === 'archived')
        dispatch(heimdallApi.util.invalidateTags([{ type: 'Memory', id: 'ALL' }]));
      return;
    }
    case 'agent_update':
    case 'agent_lifecycle_changed':
    case 'agent_runtime_changed': {
      const id = payload.agent_instance_id;
      if (payload.agent && id)
        dispatch(heimdallApi.util.upsertQueryData('showAgent', { agentInstanceId: id }, normalizeAgent(payload.agent)));
      // Patch the list row in place; invalidate the single agent, not the whole list.
      if (id) dispatch(heimdallApi.util.invalidateTags([{ type: 'Agents', id }]));
      return;
    }
    case 'merge_decision_pending': {
      const chainId = payload.chain_id;
      if (chainId) dispatch(heimdallApi.util.invalidateTags([{ type: 'Workspace', id: chainId }, { type: 'MergeDecisions', id: 'ALL' }]));
      return;
    }
    case 'chat_approval':
      dispatch(heimdallApi.util.invalidateTags([{ type: 'ChatApprovals', id: 'ALL' }]));
      return;
  }
}
```

## Invalidation-vs-patch rules

- If the event **carries the updated record**, patch the cache in place with `upsertQueryData` / `updateQueryData` and do **not** invalidate (no network at all).
- If the event carries only an **id**, invalidate that single tagged entry. RTK Query only refetches it if something is currently subscribed to it.
- Only invalidate a `*:ALL` list tag when membership changes (create/delete/add/remove), never for in-place field updates.
- Never invalidate the focused chain's tasks/chat unless the event's `chain_id` matches the focused chain.

## Acceptance criteria

- A `task_event` for task T in chain C invalidates at most `{Task:T, TaskLog:T, ChainTasks:C}` and refetches only the ones with live subscribers.
- An `agent_runtime_changed` for agent A refetches at most agent A (or zero requests if the payload includes the record).
- A `memory_event` status change for memory M refetches at most memory M and never the memory list.
- Background poll + WS + route change never issue overlapping requests for the same cache entry.

---

# Phase 5 — Enforce boundaries

Once endpoints exist:

## Rules

Components may use:

```ts
useFetchTaskLogQuery / useFetchChainTasksQuery / useFetchChatQuery / ...
useSetTaskStatusMutation / ... mutation hooks
Redux selectors + plain UI actions
```

Components may not:

```ts
import daemonApi.* read functions
dispatch(fetchSelectedTaskLog(...)) / dispatch(fetchTasksForChain(...))
dispatch(fetchSelectedChat(...)) / dispatch(refreshAgents(...))
call heimdallApi.util.invalidateTags(...)   // only wsInvalidation.ts + endpoint files
```

Exception: transitional code marked `// TODO(rtkq-migration)`.

## Static check

`tests/test_ui_service_boundaries.py` fails if `src/ui/components/*` contains:

- `daemonApi.fetchTaskLog`, `daemonApi.fetchChat`, `daemonApi.listChainTasks`,
  `daemonApi.listKnownAgents`, `daemonApi.listMemory`, `daemonApi.fetchWorkspace`, etc.
- `invalidateTags` / `upsertQueryData` outside `src/ui/api/`
- Legacy `dispatch(fetchSelectedTaskLog` / `dispatch(fetchTasksForChain` / `dispatch(fetchSelectedChat`

Allowed exceptions: one-shot artifact upload/download components, `src/ui/api/*`, tests.

---

# Phase 6 — Observability

RTK Query gives most of this via Redux DevTools and `heimdallApi.util.getRunningQueriesThunk`. Add a small dev-only debug panel:

- running queries count by endpoint
- cache entries by tag
- last-invalidation reason (attach an `invalidatedBy` note in `wsInvalidation.ts` under `import.meta.env.DEV`)

```text
[ui-rpc] fetchTaskLog({taskId:T}) served-from-cache
[ui-rpc] ws task_event -> invalidate Task:T, ChainTasks:C
[ui-rpc] ws agent_runtime_changed -> patched showAgent(A), no fetch
```

Acceptance: during a storm we can see which entries were invalidated, by which WS event, and whether a fetch actually fired.

---

# Migration order

1. **`heimdallApi` skeleton + store wiring**. This is the first implementation step; do not add a separate request-coordinator or temporary dedupe layer.
2. **Task endpoints + task UI migration**: move `fetchTaskLog`, `fetchChainTasks`, and task mutations to RTK Query; migrate `ChainView`/task detail actions so mutations invalidate precise tags instead of dispatching follow-up thunks.
3. **Chat endpoints + chat UI migration**: move direct, guide, coordinator chat reads/sends to RTK Query with optimistic cache updates.
4. **`wsInvalidation.ts`**: replace `App.tsx onmessage` fan-out with targeted patching/invalidation for only the affected IDs.
5. **Boundary test** to lock in the pattern and prevent new component-level fetch orchestration.
6. **Follow-up domains** (agents, memory, projects, attention, workspace, artifacts, settings) migrated with the same endpoint/tag model.

Legacy thunks may remain as thin wrappers only where a component is not yet migrated; they must be deleted as each surface moves to hooks.
Current transitional wrappers and per-domain migration notes live in `docs/plan/ui-request-services/follow-up-domains.md`.

---

# Success criteria

- Opening a task detail → at most one first-page `task_log` request per cache window (served from cache otherwise).
- Task mutation → invalidates only `{Task, TaskLog, ChainTasks}` for the affected ids; at most one coalesced refetch each.
- Opening a chat → at most one first-page fetch per cache window.
- Sending chat → one send RPC + optimistic UI; confirmation via WS, no forced full reload.
- Each WS event → invalidates/patches only the entries named in its payload; carries-record events issue zero fetches.
- Background polling, WS, and route changes never overlap on the same cache entry.
- Components contain no `mutation -> refresh A -> refresh B` orchestration and no WS fan-out.

---

# Follow-up domains

Each is "define endpoints + tags," which is cheap once the root api slice exists. Same rules: precise tags, mutation-owned invalidation, WS events patch-or-invalidate a single entry.

## `agents`
- `listAgents` (tag `Agents:ALL`), `showAgent` (tag `Agents:<id>`), `startAgent`, `stopAgent`, `updateAgent`, `archiveAgent`.
- Launch/stop polling uses `pollingInterval` on `listAgents` (coalesced) instead of manual timers.
- Migration: `AgentDetailPage`, sidebar launcher, `AgentPicker`, `ChainEditor` roster, guide startup.

## `memory`
- `listMemory` (`Memory:ALL` + per-id), `showMemory`, `memoryHistory`, `proposeMemory`, `decideMemory`, `listApplicableMemory`, `triggerMemoryAudit`.
- Approval/proposal invalidates `Memory:<id>` and, only on membership change, `Memory:ALL`.
- Preserve editor drafts: RTKQ refetch updates cache but component form state is local; refetch never rehydrates open editor fields unless memory identity changes.
- Migration: `MemoryManagementPage`, `AgentDetailPage` memory, attention approvals, audit panels.

## `projects`
- `listProjects`, `showProject`, `createProject`, `updateProject`, `deleteProject`, `reorderProjects`.
- Mutations own single invalidation; forms rehydrate only on project identity change.
- Migration: `SettingsPage` project panel, `NewProjectModal`, home project list.

## `attention`
- `fetchAttention`, `listPendingChatApprovals`, `answerChatApproval`, `dismissChatApproval`, merge decisions.
- One background poll; `chat_approval` / `merge_decision_pending` WS events invalidate the specific list tag only.
- Migration: `AttentionSurface`, merge/approval cards.

## `workspace`
- `fetchWorkspace` (`Workspace:<chainId>`), `fetchWorkspaceDiff` (`WorkspaceDiff:<chainId>:<file>` — coalesced, large payloads), `previewWorkspaceMerge`, `executeWorkspaceMerge`.
- Merge execution invalidates `Workspace:<chainId>` + `Attention:ALL`.
- Migration: `WorkspaceBox`, attention merge cards, chain workspace panel.

## `artifacts`
- `listArtifacts` (per-scope tag), `fetchArtifactMeta`, `fetchArtifactContent` (cache while viewer open), `createArtifact`, `updateArtifact`, `deleteArtifact`.
- Uploads keep per-temp-id in-flight protection; mutation invalidates the relevant list + meta.
- Migration: `ArtifactUpload`, `ArtifactViewer`, `ChainArtifactsPanel`, markdown/message previews.

## `settings`
- `fetchPreferences`, `savePreference`, `resetPreference`, `refreshSettingsCatalog`.
- Startup/reconnect reads coalesce via cache; saving updates cache and forces at most one refetch.
- Migration: `SettingsPage`, sidebar launch defaults, onboarding wizard.

## Target end state

```text
components -> RTK Query hooks -> daemonApi transport
WS events -> wsInvalidation -> patch or invalidate exactly the changed cache entries
RTK Query cache -> selectors -> components
```

No component orchestrates a read/mutation chain. No WS event refetches a whole surface. Components express intent; the cache decides whether a request is needed.
