# UI request-layer follow-up domains

This cleanup task keeps RTK Query as the single recurring read/cache/invalidation authority and records the remaining non-task/non-chat domains that still need the same endpoint/tag migration pattern.

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
- `src/ui/components/App.tsx`
- `src/ui/components/SettingsPage.tsx`

Each remaining component-level use is explicitly marked `TODO(rtkq-migration owner=task-19f69e242e4)` so it stays quarantined and visible.

## Follow-up domain map

| Domain | Endpoints/tags to add or finish | Current transitional callers | Notes |
|---|---|---|---|
| Agents | `listAgents`/`Agents:ALL`, `showAgent`/`Agents:<id>` | `refreshAgents` in `App.tsx`, `SettingsPage.tsx` | Runtime/lifecycle WS already uses scoped agent invalidation; remaining work is to move recurring list reads out of components. |
| Memory | `listMemory`/`Memory:ALL`, `showMemory`/`Memory:<id>`, `memoryHistory`/`MemoryHistory:<id>` | `refreshMemory`, `fetchMemoryDetail` in store/components | WS invalidation already targets `Memory`/`MemoryHistory`; remaining work is UI hook migration. |
| Projects | `listProjects`/`Projects:ALL`, `showProject`/`Project:<id>` | `refreshProjects`, `fetchProjectDetail` | Keep forms local; mutations own precise invalidation. |
| Attention | `fetchAttention`/`Attention:ALL`, `listPendingChatApprovals`/`ChatApprovals:ALL`, merge decisions/`MergeDecisions:ALL` | `refreshChatApprovals`, `refreshMergeDecisions` | WS invalidation already targets attention aggregates precisely. |
| Workspace | `fetchWorkspace`/`Workspace:<chainId>`, `fetchWorkspaceDiff`/`WorkspaceDiff:<chainId>:<file>` | `fetchWorkspaceForChain`, `fetchWorkspaceDiff`, `revalidateChainView` | Large diffs should stay file-scoped and coalesced. |
| Artifacts | scoped list tag, `fetchArtifactMeta`/`Artifact:<id>`, `fetchArtifactContent`/`ArtifactContent:<id>` | artifact viewer/upload components | Cache content only while viewers are live. |
| Settings | `fetchPreferences`/`Preferences:ALL`, settings catalog tags | `fetchPreferences`, `refreshSettingsCatalog` | Startup/reconnect reads should coalesce via RTKQ. |

## Guardrails

- Do **not** introduce `requestCoordinator`, `taskService`, `chatService`, or any parallel cache/service layer.
- Mutations own invalidation. Components express intent through hooks or endpoint `initiate` calls.
- If a transitional thunk remains, keep it thin and clearly marked with `TODO(rtkq-migration owner=task-...)`.
- Record-bearing WS payloads patch cache; id-only payloads invalidate only the matching scoped tags.
