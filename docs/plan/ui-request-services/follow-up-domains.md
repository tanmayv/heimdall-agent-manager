# UI request-layer follow-up domains

This cleanup task keeps Redux (including the RTK Query cache slice) as the single UI state authority and records the remaining non-task/non-chat domains that still need the same endpoint/tag migration pattern.

The current chat/messaging path is the reference implementation to preserve while migrating other domains: one initial subscribed read populates Redux, mutations express intent through a domain endpoint, and WebSocket events patch Redux directly when they carry records or trigger one scoped fetch/invalidation when they only carry an id. Components should render from Redux selectors/RTKQ hook state and should not keep separate fetched-resource copies in component state.

## Current-state honesty (read this first)

The tag/endpoint model is only **partially** wired. Do not assume a domain is migrated just because a tag name exists in `HEIMDALL_TAG_TYPES` or because `wsInvalidation.ts` calls `invalidateTags` for it.

Measured against the code today:

- `heimdallApi.ts` declares 25 tag types, but only **7 have a query that `providesTags`**: `Task`, `TaskLog`, `TaskComments`, `ChainTasks`, `Chat`, `GuideChat`, `ConversationSummaries`.
- `wsInvalidation.ts` calls `invalidateTags` for `Chain`, `Memory`, `MemoryHistory`, `Workspace`, `Attention`, `ChatApprovals`, and `MergeDecisions`. **None of these tags have a providing query**, so those invalidations are silent no-ops. The visible update for those domains actually happens through the parallel legacy reducers (`applyMemoryEventRecord`, `chatApprovalEventReceived`, `mergeDecisionEventReceived`, `revalidateChainView`), not through RTK Query.
- The reference (task) domain still **dual-writes**: `handleTaskEvent` patches the RTK Query caches (`fetchTask`, `fetchChainTasks`, `fetchTaskLog`) *and* the legacy `state.tasks` slice (`updateTaskStateDirectly`, `taskEventReceived`), and `App.tsx` still reads `tasksById` / `chainTaskIds` / `taskLogsByTaskId` from `state.tasks`. Two projections for one domain is the main threat to consistent UI state and must collapse to one.
- Manual refresh orchestration still exists outside RTK Query: `chainViewSlice.revalidateChainView -> focusChainView` fans out a 3-way `Promise.all` refetch plus a coordinator chat fetch, and `App.tsx` runs raw `setInterval` pollers (a 1000ms `onRefreshAgents()` poll, 2000ms chain/creation ticks). The plan says polling must move to RTK Query `pollingInterval`; these are the callers that still need to move.

### Definition of "migrated" (per domain)

A domain is not done until **all** of these hold:

1. A query endpoint exists and **owns its tag** (`providesTags` is present for every tag the WS handler invalidates for that domain).
2. All component reads for that domain go through the RTKQ hook; the legacy slice projection for that domain is **deleted**, not just marked. No component selects both the RTKQ result and the legacy slice fields for the same data.
3. The WS handler either patches that cache via `updateQueryData` / `upsertQueryData` (record-carrying events) or invalidates a tag **that has a provider** (id-only events). It never invalidates a no-op tag.
4. No `setInterval` / thunk refresh chain remains for that domain. If polling is needed, it uses RTK Query `pollingInterval` on the owning query.

Order the work per domain as: **add query + provider first, then wire WS patch/invalidation, then delete the legacy reducer/thunk and component reads.** Adding WS invalidation before a providing query exists just creates another no-op.

## Transitional wrappers retained in code

These wrappers remain only to avoid expanding this chain into full follow-up migrations:

- `src/ui/store/taskSlice.ts`
  - `refreshTaskBoard`
  - `fetchTasksForChain`
  - `fetchSelectedTaskLog`
- `src/ui/store/chatSlice.ts`
  - `refreshConversationSummaries`
  - `fetchSelectedChat`
  - `fetchGuideChat`
- `src/ui/store/homeSlice.ts`
  - `submitNewChain` still refreshes the board once so a newly created chain appears in the overview
  - `refreshTaskBoard` remains the home-board list read until a `ChainList` RTKQ query owns it
- `src/ui/store/chainViewSlice.ts`
  - `revalidateChainView` / `focusChainView` (multi-fetch fan-out)
  - `fetchWorkspaceForChain`, `fetchWorkspaceDiff`, `previewWorkspaceMerge` (pre-RTKQ workspace reads)
  - `loadAgentSideSheet` (direct `fetchTask` / `fetchTaskComments` reads)
- `src/ui/store/memorySlice.ts`
  - `refreshMemory`, `fetchMemoryDetail`, and the legacy `applyMemoryEventRecord` projection
- `src/ui/store/attentionSlice.ts`
  - `refreshChatApprovals`, `refreshMergeDecisions`, and the legacy `chatApprovalEventReceived` / `mergeDecisionEventReceived` projections
- `src/ui/store/projectSlice.ts`
  - `refreshProjects`, `fetchProjectDetail`
- `src/ui/components/App.tsx`
  - still selects `state.tasks` (`tasksById` / `chainTaskIds` / `taskLogsByTaskId`) alongside RTKQ task hooks
  - raw `setInterval` pollers (1000ms `onRefreshAgents()`, 2000ms chain/creation ticks) that should move to RTKQ `pollingInterval`
- `src/ui/components/SettingsPage.tsx`
- `src/ui/components/MemoryManagementPage.tsx`
- `src/ui/components/MessageBubble.tsx`

Each remaining component-level use is explicitly marked `TODO(rtkq-migration owner=task-19f69e242e4)` so it stays quarantined and visible.

## Data-flow guideline to preserve

Use the current chat flow as the model for every follow-up domain:

```text
initial page/component load
  -> subscribe to one RTKQ endpoint or dispatch one endpoint initiate
  -> endpoint fetches once per cache window and hydrates the Redux-owned projection

user action
  -> call a mutation/service endpoint that expresses the intent
  -> optionally apply an optimistic Redux patch owned by the endpoint/reducer
  -> do not chain component refreshes

WebSocket event
  -> wsInvalidation/domain handler patches Redux if the payload carries the record
  -> otherwise invalidates or initiates exactly one scoped resource fetch by id
  -> no broad surface refresh and no component-level state synchronization

render
  -> components read Redux/RTKQ state through hooks/selectors
  -> components keep only transient UI state locally (draft input, modal open, form dirty values)
```

Rules:

- Redux is the source of truth for UI-visible daemon data. RTK Query cache entries are part of that Redux state.
- Domain endpoints/mutations are the service boundary for requests. Components may trigger those services, but must rely on Redux updates to propagate results.
- Do not store fetched daemon resources in component `useState` after loading them. Local state is allowed only for ephemeral UI concerns and in-progress form drafts.
- Prefer record-carrying WS patches over refetch. For id-only WS events, use the narrowest tag or one `endpoint.initiate(..., { forceRefetch: true, subscribe: false })` when a compact event must be hydrated immediately.
- Mutations own optimistic updates and invalidation. Components must not do `mutation -> refresh list -> refresh detail -> refresh log` chains.
- Reuse domain normalizers/reducer helpers between endpoint fulfillment and WS handlers. Do not duplicate mapping logic or maintain separate RTKQ cache + slice projections longer than a marked transition requires.
- `*:ALL` list invalidation is only for membership/order/filter-boundary changes. In-place record changes should patch the row or invalidate the single record tag.

## Current UI code review notes

- `src/ui/api/endpoints/chats.ts` is the best current pattern:
  - `fetchDirectChat` / `fetchGuideChat` perform the first-page read and dispatch `chat/receiveChatPage` so the rendered chat projection is updated from Redux.
  - `sendAgentMessage` / `sendGuideMessage` perform endpoint-owned optimistic patches instead of forcing a full reload.
  - page fetches merge older messages into the existing cache/projection rather than replacing unrelated state.
- `src/ui/api/wsInvalidation.ts` already applies the desired WS behavior for chat:
  - inline `chat_event.message` patches the exact chat cache and dispatches `chat/appendMessage`;
  - status-only events patch message delivery/read state;
  - `fetch_required` chat events hydrate one `messageId` rather than refetching every conversation.
- Task migration is partially aligned:
  - `tasksApi` owns task/log/comment endpoint tags and mutations;
  - compact task WS events can issue one forced `fetchTask` for the affected task;
  - remaining `taskSlice` projections are transitional and should collapse behind shared `applyAuthoritativeTask`/`applyTaskEvent` helpers.
- Remaining problem areas to clean up during domain follow-up:
  - `src/ui/components/App.tsx` and `src/ui/components/SettingsPage.tsx` still dispatch `refreshAgents`, `refreshMemory`, and `fetchSelectedChat` from component effects/handlers.
  - `src/ui/store/chatSlice.ts` still has agent/settings thunks that call daemon helpers directly and then refresh lists after mutations (`startAgentInstance`, `stopAgentInstance`, `reorderAgentsFromUi`). Move these to endpoint-owned invalidation/patching.
  - Chat mapping code exists in both `endpoints/chats.ts` and `wsInvalidation.ts`; extract shared normalizers before extending the pattern to more domains.
  - Memory pages still issue component-level `refreshMemory`; migrate to hooks plus WS/domain invalidation while keeping editor drafts local.

## Follow-up domain map

The "Tag provider today" column is the honest status: `no-op` means `wsInvalidation.ts` already invalidates the tag but **no query provides it**, so the invalidation does nothing and the domain still updates through a legacy reducer. `none` means neither a query nor invalidation exists yet.

| Domain | Endpoints/tags to add or finish | Tag provider today | Current transitional callers | Notes |
|---|---|---|---|---|
| Agents | `listAgents`/`Agents:ALL`, `showAgent`/`Agents:<id>` | none (WS patches legacy `chatSlice` agent rows) | `refreshAgents` in `App.tsx`/`SettingsPage.tsx`, 1000ms `setInterval` poll | Add the query + provider, then replace `refreshAgents` calls and the manual poller with a hook using `pollingInterval`. |
| Memory | `listMemory`/`Memory:ALL`, `showMemory`/`Memory:<id>`, `memoryHistory`/`MemoryHistory:<id>` | **no-op**: `Memory`/`MemoryHistory` invalidated but no provider; updates run through `applyMemoryEventRecord` | `refreshMemory`, `fetchMemoryDetail` in store/components | The WS wiring exists but is inert until a query provides `Memory`/`MemoryHistory`. Add providers first, then delete the legacy projection. |
| Projects | `listProjects`/`Projects:ALL`, `showProject`/`Project:<id>` | none | `refreshProjects`, `fetchProjectDetail` | Keep forms local; mutations own precise invalidation. |
| Attention | `fetchAttention`/`Attention:ALL`, `listPendingChatApprovals`/`ChatApprovals:ALL`, merge decisions/`MergeDecisions:ALL` | **no-op**: `Attention`/`ChatApprovals`/`MergeDecisions` invalidated but no provider; updates run through `chatApprovalEventReceived`/`mergeDecisionEventReceived` | `refreshChatApprovals`, `refreshMergeDecisions`, 15s `tickChatApprovalExpiry` timer | Add providing queries first; the current "targets aggregates precisely" claim is only true once a query owns each tag. |
| Workspace | `fetchWorkspace`/`Workspace:<chainId>`, `fetchWorkspaceDiff`/`WorkspaceDiff:<chainId>:<file>` | **no-op**: `Workspace` invalidated but no provider; updates run through `chainViewSlice` | `fetchWorkspaceForChain`, `fetchWorkspaceDiff`, `previewWorkspaceMerge`, `revalidateChainView` | Large diffs should stay file-scoped and coalesced. Retire the `revalidateChainView` fan-out. |
| Artifacts | scoped list tag, `fetchArtifactMeta`/`Artifact:<id>`, `fetchArtifactContent`/`ArtifactContent:<id>` | none | artifact viewer/upload components | Cache content only while viewers are live. |
| Settings | `fetchPreferences`/`Preferences:ALL`, settings catalog tags | none | `fetchPreferences`, `refreshSettingsCatalog` | Startup/reconnect reads should coalesce via RTKQ. |
| Chain metadata | `fetchChain`/`Chain:<id>`, `ChainList` list query | **no-op**: `Chain` chain-fetch path invalidates `Chain` but no query provides it | `refreshTaskBoard`, `revalidateChainView`, `focusChainView` | `ChainTasks` has a provider; `Chain` metadata and `ChainList` do not yet. |

## Guardrails

- Do **not** introduce `requestCoordinator`, `taskService`, `chatService`, or any parallel cache/service layer.
- The only durable UI state for daemon data lives in Redux: classic slices during transition and RTKQ cache entries/endpoints as the target. Components must not maintain their own fetched-data mirrors.
- Mutations own invalidation. Components express intent through hooks or endpoint `initiate` calls and then render the resulting Redux update.
- Initial page load should perform at most one subscribed fetch for the resource. Subsequent freshness comes from RTKQ cache policy, mutation invalidation, and WS patch/invalidation.
- WebSocket events are the live-update path: patch from payload first; if not enough data is present, fetch/invalidate only the scoped resource named in the event.
- If a transitional thunk remains, keep it thin and clearly marked with `TODO(rtkq-migration owner=task-...)`.
- Record-bearing WS payloads patch cache; id-only payloads invalidate only the matching scoped tags.
- Reuse existing components and shared domain normalizers/reducers while migrating; improve adjacent duplicated code instead of adding parallel one-off flows.
- **No orphan invalidation.** `invalidateTags(T)` is only allowed when some endpoint `providesTags(T)`. Invalidating a tag no query provides is a silent no-op and hides the fact that a domain still updates through a legacy reducer. When you remove the legacy reducer path, the providing query must already exist.
- **One projection per domain.** Once a domain has an RTKQ query, its legacy slice projection and any component `useSelector` reads of that data must be deleted. A domain must never be read from both RTKQ cache and a legacy slice at the same time.
- **No manual pollers for migrated domains.** Replace `setInterval` refresh loops with `pollingInterval` on the owning query, scoped to when the data is actually visible.

## Enforcement (tests to add/extend)

Extend `tests/test_ui_service_boundaries.py` (or add sibling tests) so the guardrails are mechanically checked, not just documented:

1. **No-orphan-invalidation test.** Parse the `type: '<Tag>'` targets passed to `invalidateTags` in `src/ui/api/wsInvalidation.ts` and the endpoint files, and assert every one has a matching `providesTags` in `src/ui/api/endpoints/*.ts`. Fail the build on any tag invalidated but not provided (except an allow-list of tags explicitly documented as "not yet migrated").
2. **Single-projection test.** For each domain that has an RTKQ endpoint, assert no `src/ui/components/*` file `useSelector`s the corresponding legacy slice fields (e.g. once Memory is migrated, no component reads `state.memory` records).
3. **No-manual-poller test.** Assert `src/ui/components/*` contains no `setInterval` whose body dispatches a domain refresh thunk (`refreshAgents`, `refreshMemory`, `revalidateChainView`, etc.) for a migrated domain.

The allow-list in test 1 is the single source of truth for "which no-op tags are still allowed," and it must shrink to empty as domains migrate.
