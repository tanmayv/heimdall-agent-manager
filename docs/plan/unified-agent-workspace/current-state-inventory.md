# Unified agent workspace current-state inventory

Task: `task-19f794ac462`

This inventory covers the three current agent-like chat surfaces that must converge into one workspace shell:

- `ConversationThreadPage` — `src/ui/components/App.tsx:3489`
- `AgentDetailPage` — `src/ui/components/App.tsx:2982`
- `ChainView` coordinator chat — `src/ui/components/App.tsx:5079`

It records current routes, component reuse, style dependencies, debug IDs, data/query ownership, and redundant information that should move into the unified shell.

## 1. Current route / entry-point inventory

Current navigation is still query-param driven out of `App.tsx`, not `/workspace/...` routes.

| Current entry | Current URL state / selector | Current render target | Future unified route |
|---|---|---|---|
| `openAgentPage(agentId)` | `view=agent&agentId=<id>` + `agentPageId` local state (`App.tsx:1284`, `1452-1561`) | `ConversationThreadPage` when `isConversationAgent(selectedPageAgent)`, otherwise `AgentDetailPage` | `/workspace/conversations/:agentInstanceId` or `/workspace/agents/:agentInstanceId` |
| `openChain(chainId)` | `view=chain&chainId=<id>` + `home.surface === 'chain'` (`App.tsx:1231`, `1666-1708`) | `ChainView` | `/workspace/chains/:chainId/coordinator` |
| task open from chain | `view=chain&chainId=<id>&taskId=<id>` (`App.tsx:1689`, `1022-1026`) | still `ChainView`; task detail lives in the right task pane, not its own page | `/workspace/chains/:chainId/tasks/:taskId` |
| legacy/new conversation launch | `view=new-conversation` (`App.tsx:1322`, `1579-1604`) | `NewConversationPage` | likely projects into `/workspace` create/start flow |

### Routing observations

- Direct-agent and conversation pages already share the same entry helper (`openAgentPage`) and diverge only after agent lookup.
- Chain coordinator is still a separate surface selected by `home.surface === 'chain'`.
- Task detail is not a first-class route surface yet; it is a right sidebar expansion inside `ChainView`.
- The left navigation shell already exists at app level via `ConversationFocusedSidebar`, but the main content panes still render page-specific layouts.

## 2. Shared chat primitive usage matrix

| Surface | `ChatHeader` | `ChatMessageList` | `ChatWorkBanner` | `ChatComposer` | `RuntimeRestartControls` | Artifact UI | Extra wrappers / style dependencies |
|---|---|---|---|---|---|---|---|
| Conversation thread | Yes (`3586`) | Yes (`3628`) | Yes (`3661`) | Yes (`3664`) | Via composer, enabled (`3686`) | Composer upload + `ChatArtifactsSidePanel` (`3644`) | Centered `max-w-[820px]`, separate summary card, page-level artifact side panel |
| Direct agent | Yes (`3239`) | Yes (`3248`) | Yes (`3276`) | Yes (`3277`) | Via composer, enabled (`3303`) | Composer upload + `ChatArtifactsSidePanel` (`3259`) | Two-column chat area plus `ChatSidebar`; extra hero/actions/cards outside chat |
| Chain coordinator | Yes (`5224`) | Via `CoordinatorMessageList` -> `ChatMessageList` (`4890`, `5236`) | Yes (`5241`) | Yes (`5244`) | Via composer, present but disabled (`5272`) | Composer upload + global evidence/artifacts sidebar (`5403-5449`) | Chat lives inside chain-specific split view with task/evidence right pane |

### Shared primitive observations

- UAW-4 is already partly satisfied structurally: all three contexts reuse the same chat primitives.
- Visual parity is currently broken by page scaffolding around those primitives rather than by the primitives themselves.
- `ChatHeader`/`ChatComposer` styling is customized per page through props (`className`, `shellClassName`, `textareaClassName`, footer content, etc.), so parity work should normalize those wrapper props.
- Artifact handling is duplicated: each context keeps composer upload, but each also mounts a separate side panel implementation or evidence tab.

## 3. Current page-specific surfaces and redundant information

| Current surface | Where today | Redundant with | Recommended canonical destination |
|---|---|---|---|
| Conversation summary card (`conversation-thread-summary-card`) | Conversation page body | Header title/subtitle + status chips | Workspace top bar / shared `ChatHeader` |
| Conversation affordance strip (`exact resume`, `history preserved`, `agent live`) | Conversation summary card | Runtime / context metadata | Header subtitle or Runtime inspector tab |
| Conversation project chip + footer project line | Header + composer footer | Project context shown multiple times | Project inspector tab + minimal breadcrumb/title |
| Conversation artifact side panel | Right side of conversation page | Global artifact inspector concept | Inspector `Artifacts` tab |
| Agent hero status/actions | Top of agent page | Shared chat top bar actions | Workspace top bar |
| Agent stat cards (`project`, `role`, `provider`, `runtime`) | `agent-detail-*` cards | Runtime/project/identity metadata | `Project`, `Runtime`, and possibly header subtitle |
| Agent chat right sidebar (`AgentChatSidebarContent`) | `ChatSidebar` beside chat | Chain/tasks info also shown below | Inspector `Tasks` / `Task chains` |
| Agent lower pending/completed task lists | `agent-detail-tasks` section | Same task relationship data | Inspector `Tasks` |
| Agent memory section/editor | `agent-detail-memory` section | Durable memory belongs to context inspector | Inspector `Memory` |
| Agent artifact side panel | Right side of chat panel | Shared artifact inspector concept | Inspector `Artifacts` tab |
| Agent start/stop progress cards | Above agent chat | Runtime lifecycle detail | Runtime inspector tab or header notice area |
| Chain description panel | Expandable page section | Chain context / plan metadata | Inspector `Task chains` or top-bar summary |
| Chain task pane (`TaskTodoList`) | Right pane of `ChainView` | Future inspector task tabs | Inspector `Tasks` |
| Chain evidence sidebar (`GlobalRightSidebar`) | Separate right pane | Future inspector `Artifacts` + `VCS` tabs | Inspector `Artifacts` / `VCS` |
| Chain project footer in composer | Composer footer | Project context repeated elsewhere | Project inspector tab + minimal breadcrumb |
| Duplicate start affordances | Header buttons + `ChatWorkBanner` start buttons | Runtime action shown twice | Canonical top-bar start/stop; keep banner only when stopped if needed |

## 4. Current debug-ID coverage that must be preserved or intentionally migrated

The code already has strong `data-debug-id` coverage. The main risk is losing IDs when surfaces move from page-specific panes into shell/header/composer/inspector slots.

### 4.1 Left sidebar / route shell IDs already in use

`ConversationFocusedSidebar` and related sidebars already provide shell-like IDs:

- `conversation-focused-sidebar`
- `conversation-sidebar-collapse-btn`
- `conversation-sidebar-expand-btn`
- `sidebar-new-conversation-btn`
- `nav-home-btn`, `nav-memory-btn`, `nav-agents-btn`, `nav-task-chains-btn`, `nav-projects-btn`, `nav-settings-btn`
- `sidebar-new-chain-btn`
- `conversation-sidebar-chain-<chainId>`
- `sidebar-agent-group-open-btn-<agentId>`
- `sidebar-agent-new-instance-btn-<agentId>`
- `sidebar-agent-live-instance-row-<instanceId>`

These are the natural starting point for the unified left workspace column.

### 4.2 Chat-header / top-bar IDs by context

| Context | Key IDs today |
|---|---|
| Conversation | `conversation-thread-back-btn`, `conversation-thread-status-chip`, `conversation-thread-project-chip`, `conversation-thread-artifacts-toggle-btn`, `conversation-thread-refresh-btn`, `conversation-thread-start-btn`, `conversation-thread-stop-btn` |
| Direct agent | `agent-detail-back-btn`, `agent-detail-title`, `agent-detail-live-status`, `agent-detail-all-instances-btn`, `agent-detail-start-btn`, `agent-detail-stop-btn`, `agent-detail-edit-btn`, `agent-detail-delete-btn` |
| Chain coordinator | `chain-back-btn`, `global-right-sidebar-toggle-btn`, `chain-open-editor-btn`, `chain-tasks-toggle-btn`, `chain-coordinator-live-status` |

### 4.3 Shared message-list namespaces already established

`src/ui/components/chat/debugPrefixes.ts` defines the current namespaces:

- conversation: `conversation-thread` / `conversation-composer` / `conversation-attach` / `conversation`
- direct agent: `agent-detail-chat` / `agent-detail-chat-artifact-upload`
- chain coordinator: `chain-coordinator` / `chain-coordinator-artifact-upload`

Because `ChatMessageList`, `ChatWorkBanner`, `ChatComposer`, `RuntimeRestartControls`, and `ArtifactUploadButton` derive most debug IDs from these prefixes, preserving these namespaces during shell migration will protect most chat automation coverage.

### 4.4 Composer / runtime / artifact IDs already emitted by shared primitives

| Zone | Conversation | Direct agent | Chain coordinator |
|---|---|---|---|
| Composer shell/input/send | `conversation-composer-shell`, `conversation-composer-input`, `conversation-composer-send-btn` | `agent-detail-chat-composer-shell`, `agent-detail-chat-input`, `agent-detail-chat-send-btn` | `chain-coordinator-composer-shell`, `chain-coordinator-composer-input`, `chain-coordinator-send-btn` |
| Upload button/input/error | `conversation-attach-btn` / `-input` / `-error` | `agent-detail-chat-artifact-upload-btn` / `-input` / `-error` | `chain-coordinator-artifact-upload-btn` / `-input` / `-error` |
| Runtime controls | `conversation-runtime-controls`, `conversation-provider-select`, `conversation-tier-select`, `conversation-project-select`, `conversation-restart-btn` | `agent-detail-chat-runtime-controls`, `agent-detail-chat-provider-select`, `agent-detail-chat-tier-select`, `agent-detail-chat-project-select`, `agent-detail-chat-restart-btn` | `chain-coordinator-runtime-controls`, `chain-coordinator-provider-select`, `chain-coordinator-tier-select`, `chain-coordinator-project-select` |
| Work banner | `conversation-composer-status-banner`, `conversation-composer-status-start-btn` | `agent-detail-chat-status-banner`, `agent-detail-chat-status-start-btn` | `chain-coordinator-status-banner`, `chain-coordinator-status-start-btn` |

### 4.5 Right-sidebar / inspector / task-control IDs that will need migration

| Current area | Important IDs |
|---|---|
| Conversation artifacts side panel | `conversation-thread-artifacts-panel`, `conversation-thread-artifacts-refresh-btn`, `conversation-thread-artifacts-close-btn`, `conversation-thread-artifacts-list`, `conversation-thread-artifact-row-<artifactId>` |
| Agent artifacts side panel | `agent-detail-chat-artifacts-panel`, `agent-detail-chat-artifacts-refresh-btn`, `agent-detail-chat-artifacts-close-btn`, `agent-detail-chat-artifacts-list` |
| Chain evidence sidebar | `global-right-sidebar`, `global-right-sidebar-diffs-tab`, `global-right-sidebar-artifacts-tab`, `global-right-sidebar-close-btn`, `global-right-sidebar-diff-list`, `global-right-sidebar-artifact-list` |
| Agent chat sidebar | `agent-detail-chat-sidebar`, `agent-detail-chat-chain-summary`, `agent-detail-chat-sidebar-tasks`, `agent-detail-chat-chain-open-btn` |
| Chain task pane | `chain-task-row-<taskId>`, `chain-task-row-<taskId>-open-btn`, `chain-task-row-<taskId>-expand-btn`, `task-detail-status-start-btn-<taskId>`, `task-detail-status-done-btn-<taskId>`, `task-detail-status-block-btn-<taskId>`, `task-detail-status-later-btn-<taskId>`, `task-detail-status-cancel-btn-<taskId>`, `task-detail-comment-submit-btn-<taskId>`, `task-detail-nudge-btn-<taskId>`, `task-detail-vote-lgtm-btn-<taskId>`, `task-detail-vote-ngtm-btn-<taskId>` |

### 4.6 Suggested migration rule for UAW-8

- Keep existing chat primitive prefixes (`conversation-thread`, `agent-detail-chat`, `chain-coordinator`) as long as the underlying context remains the same.
- Introduce new shell/inspector IDs only for truly new containers, not to rename existing buttons gratuitously.
- When page-only surfaces move into the inspector, preserve the leaf action IDs if possible and only change the container IDs.

## 5. Data/query ownership and daemon source-of-truth inventory

## 5.1 Shared app-level sources

`App.tsx` already centralizes the main daemon-backed queries and store projections:

- conversation summaries: `useListConversationSummariesQuery`
- projects: `useListProjectsQuery`
- providers/settings catalog: `useFetchSettingsCatalogQuery`
- chains: `useListChainsQuery`, `useFetchChainQuery`
- agents: `useListAgentsQuery`, `useFetchAgentQuery`
- chain workspace/team: `useFetchWorkspaceQuery`, `useFetchTeamQuery`
- chain tasks / logs: `useFetchChainTasksQuery`, `useFetchTaskLogQuery`, `useLazyFetchTaskLogPageQuery`
- artifacts: `useListArtifactsQuery`
- memory: `useListMemoryQuery`, `useListApplicableMemoryQuery`

This is compatible with UAW-10: the future shell can be an adapter/recomposition layer over existing query data rather than a new state owner.

## 5.2 Surface-specific source matrix

| Surface | Main data sources | Local UI-only state | Daemon-backed actions |
|---|---|---|---|
| Conversation thread | selected agent from `useFetchAgentQuery` + `useListAgentsQuery`; messages from `chat` Redux store + `fetchSelectedChat`; summaries from `useListConversationSummariesQuery`; projects/providers from app-level queries | draft, send phase, local stop flag, artifacts panel open, selected runtime overrides | `daemonApi.startAgent`, `daemonApi.stopAgent`, `onSendAgentMessage`, `useArtifactUpload`, runtime restart via exact instance restart |
| Direct agent | same agent/chat/project/provider sources as conversation; plus `tasksById`, `chainsById`; applicable memory from `useListApplicableMemoryQuery` | draft, agent action progress, edit modal, memory editor, artifacts panel open, runtime override state | `daemonApi.startAgent`, `stopAgent`, `updateAgent`, `archiveAgent`; memory propose/approve mutations; artifact upload/list |
| Chain coordinator | selected chain from `useFetchChainQuery`/`useListChainsQuery`; selected chain tasks from `useFetchChainTasksQuery`; team/workspace from `useFetchTeamQuery`/`useFetchWorkspaceQuery`; coordinator chat from Redux chat store and `fetchChainCoordinatorChatPage` | draft, selected task, comment/nudge drafts, tasks pane open, right sidebar tab | `sendCoordinatorMessage`, `daemonApi.startAgent`, workspace diff/merge preview queries, task status/comment/vote/nudge actions |

### Source-of-truth observations

- No page currently owns durable task, chain, agent, artifact, memory, runtime, or VCS state locally; most local state is transient UI state.
- The main duplication risk is not persistence but re-fetch/re-shaping logic being reimplemented separately per page.
- A `WorkspaceContext` adapter can safely derive normalized context data from current app-level queries and props without introducing competing state.

## 6. Context-specific inspector candidates from existing surfaces

| Context | Existing info that should become inspector tabs |
|---|---|
| Conversation | project chip/footer, artifact panel, runtime status/start-stop, exact instance metadata |
| Direct agent | project/provider/runtime cards, task sidebar, pending/completed task lists, memory section/editor, artifact panel, start/stop progress |
| Chain coordinator | task pane, evidence sidebar tabs, workspace diff/merge controls, project artifacts, chain description, chain progress, chain roster/task agent chips |

Recommended first tab ownership based on today’s UI:

- `Tasks`: agent pending/completed lists, chain task pane
- `Task chains`: agent chain summary, chain description/plan metadata
- `Chain agents`: chain roster / task agent chips / side sheet
- `Artifacts`: all three artifact side panels and chain artifact list
- `VCS`: `GlobalRightSidebar` diffs + `WorkspaceBox`
- `Project`: repeated project chips/cards/footer text
- `Memory`: direct-agent memory section/editor
- `Runtime`: runtime cards, start/stop progress, runtime restart selectors

## 7. Concrete implementation implications for the next task

1. **Unify around one shell, not new chat primitives.** The primitives are already shared; the page scaffolding is what diverges.
2. **Promote query data into a `WorkspaceContext` adapter.** Current sources are already centralized enough for this.
3. **Treat the current side panels as proto-inspector content.** `ChatArtifactsSidePanel`, `AgentChatSidebarContent`, `TaskTodoList`, and `GlobalRightSidebar` contain reusable content that can be rehomed.
4. **Preserve existing debug-prefix namespaces.** This is the lowest-risk UAW-8 migration path.
5. **Remove page-level duplicate metadata after shell adoption.** Agent cards, conversation summary card, chain-only sidebars, and repeated project/runtime/memory/task sections are the main redundancy targets.
