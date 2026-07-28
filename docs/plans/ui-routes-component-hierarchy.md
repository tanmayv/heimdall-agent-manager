# UI routes + component hierarchy (UI-16)

Status: v1 implementation map for the Hub Rewrite UI chain. This document is the durable route/component ownership section required before feature implementation proceeds.

Sources:
- `docs/plans/ui-architecture.md`
- `docs/plans/hub-bridge-user-owned-architecture-and-api.md`
- `docs/plans/hub-bridge-runtime-protocol.md`
- Current legacy inventory under `src/ui/components`, `src/ui/components/workspace`, `src/ui/api/endpoints`, and `src/ui/store`

## 1. Routing principles

- The UI is a chat-first SPA backed by `/api/v1`; route ownership is frontend-only and must not invent backend behavior.
- The shell owns global navigation, current auth/config state, settings overlay/fullscreen state, sidebar collapse state, command palette, and the single `/api/v1/user-ws` connection.
- Routed pages own page-specific side panels. There is no global right inspector, guide panel, global attention route, or workspace shell in v1.
- Desktop and mobile use the same route IDs and `data-debug-id`s. Mobile changes layout only: drawers, bottom sheets, and drill-down screens replace side-by-side panes.
- The default project for conversations is the user-owned `Conversations` project (renamable, not deletable). Route URLs never encode legacy workspace concepts.

## 2. Planned v1 route map

The router may be implemented as hash routing for Electron/file refresh safety, but the semantic route paths below are canonical for component ownership and tests.

| Route | Owner page/component | Primary API state | Notes |
|---|---|---|---|
| `/` | `ShellRouteRedirect` | current user/config | Authenticated users land on `/conversations`; unauthenticated users render `UnauthenticatedLanding`. |
| `/conversations` | `ConversationHomePage` | conversations/projects/agents summaries | Shows grouped project → `agent_id` → session tree context and New Conversation empty state. |
| `/conversations/new` | `NewConversationPage` | agents, projects, bridges, capabilities | Composer-first launch surface; no standalone wizard. First send creates TaskChain + AgentInstance + ChatConversation transactionally. |
| `/conversations/:conversation_id` | `ConversationPage` | chat, bound `AgentInstance`, immutable chain, artifacts/memory | Main chat thread. Owns `ConversationInspector` and `CurrentTaskStrip`. |
| `/chains` | `ChainListPage` | task-chain list | Simplified chain destination; no graph editor. |
| `/chains/new` | `NewChainModal`/`ChainCreatePage` | agents/projects | Opens create-chain flow; may be modal on desktop and fullscreen on mobile. |
| `/chains/:chain_id` | `ChainPage` | chain + tasks + comments | Creation-ordered task list plus task detail pane/drill-down. |
| `/chains/:chain_id/tasks/:task_id` | `ChainPage` + `TaskDetailPanel` | selected task, comments, votes | Deep-link into selected task detail. |
| `/agents` | `AgentListPage` | agent identities | Durable agent identities/templates. |
| `/agents/new` | `AgentCreateModal`/`AgentCreatePage` | provider defaults | Create agent, then route to `/agents/:agent_id`. |
| `/agents/:agent_id` | `AgentDetailPage` | agent, sessions, bridge support, memories | Overview/Sessions/Bridges/Memory tabs. Sessions show `agent_instance_id` and open the bound conversation. |
| `/library` | `LibraryPage` | artifacts list + filters | Global artifact list/grid across conversations/chains/projects. |
| `/library/artifacts/:artifact_id` | `LibraryPage` + `ArtifactViewer` | artifact metadata/content/versions/annotations | Fullscreen kind-aware viewer; route remains valid on mobile. |
| `/settings` | `SettingsSurface` | config/settings catalog | Modal on desktop, fullscreen route/screen on mobile. |
| `/settings/bridges` | `SettingsSurface.BridgesSection` | bridge list/detail/enrollments | Bridge enrollment, rename, revoke, capabilities, instances, project path overrides. |
| `/settings/projects` | `SettingsSurface.ProjectsSection` | projects + bridge paths | Project metadata/default path/per-Bridge overrides. |
| `/settings/projects/:project_id` | `SettingsSurface.ProjectDetail` | project detail | Deep-linkable detail inside settings surface. |
| `/settings/providers` | `SettingsSurface.ProvidersSection` | bridge capability reports/provider defaults | Read-only provider profile inspection and refresh capabilities. |
| `/settings/memory` | `SettingsSurface.MemorySection` | global memory list/proposals | Global counterpart to agent/conversation memory surfaces; not a top-level nav route outside settings. |
| `/settings/defaults` | `SettingsSurface.DefaultsSection` | defaults/dev/debug | Account defaults, dev-proxy/daemon connection, debug toggles. |

## 3. App shell hierarchy

```text
HeimdallApp
  AppProviders
    ReduxProvider
    ApiProvider/RTKQuery
    RouterProvider
  AuthGate
    UnauthenticatedLanding
    AuthenticatedShell
      UserWsProvider               // exactly one /api/v1/user-ws connection
      ResponsiveChrome
        DesktopShell
          SidebarRegion
            SidebarHeader
            NewConversationButton
            CommandPaletteButton
            LibraryNavItem
            ProjectConversationTree
              ProjectGroup
                AgentGroup
                  SessionRow
            TaskChainsNavItem
            AgentsNavItem
            FooterUserChip
            SettingsButton
          MainRouteOutlet
        MobileShell
          MainRouteOutlet
          MobileBottomTabBar
          MobileSidebarDrawer
      CommandPaletteOverlay
      SettingsSurfaceOverlay
      ToastRegion
```

Shell-owned state:
- authenticated current user and public auth/config URLs;
- sidebar collapsed/expanded and mobile drawer state;
- command palette open state;
- settings overlay/fullscreen active section;
- one user WebSocket invalidation connection;
- layout breakpoint state.

Shell must not own:
- conversation inspector tab state;
- chain selected task state;
- artifact viewer internal zoom/pan state;
- task comment drafts;
- provider/tier launch controls after they are bound to a conversation.

## 4. Conversation hierarchy

```text
ConversationPage
  ConversationHeader
    AgentProjectBridgeStatusChips
    WorkChip
    ReviewNeededChip
    InspectorToggle
  ChatMessageList
    MessageBubble
    ArtifactChip
    MentionChip
  ChatComposerShell
    LaunchControls                  // only in /conversations/new before first send
      AgentSelector
      ProjectSelector(default = Conversations)
      AdvancedBridgeProviderTierControls
    LockedLaunchChips               // after creation
    CurrentTaskStrip
    AttachmentUploadTray
    MentionAutocomplete
    ChatInput
  ConversationInspector             // page-owned, collapsible; bottom sheet on mobile
    WorkTab
    WorkspaceTab
    MemoryTab
    ArtifactsTab
```

Ownership notes:
- `/conversations/new` owns the unbound composer state until first send.
- `/conversations/:conversation_id` owns transcript state, bound instance/chain lookups, inspector tabs, current-task inference, and composer drafts.
- `CurrentTaskStrip` and `WorkTab` derive from the same loaded chain/task cache; no separate current-task source is introduced.
- Chat messages and task comments remain explicit separate actions.

## 5. Chain hierarchy

```text
ChainPage
  ChainHeader
    BackButton
    ChainStatusProgress
    CoordinatorConversationLink
  ChainTaskLayout
    TaskListPane                 // desktop side-by-side; mobile list screen
      TaskRow(created_at order)
      ShowCompletedToggle
    TaskDetailPane               // desktop right pane; mobile drill-down screen
      TaskMetadataHeader
      DescriptionAcceptanceSection
      DependsOnLinks
      AssigneePicker
        SameChainAgentInstanceOptions
        AddAgentToChainAction
      ReviewerPicker
        UserReviewerOption
        SameChainAgentInstanceOptions
        AddAgentToChainAction
      StatusTransitionButtons
      NudgeBox
      VoteButtons
      TaskCommentsThread
        LoadOlderComments
        AddCommentComposer
  EmptySelectionOverview
```

Chain v1 constraints:
- Task list order is creation order with deterministic tie-break; no client-computed dependency graph or dependency editing.
- Same-chain actor validation is enforced in pickers: assignees are same-chain agent instances; reviewers are user or same-chain agent instances.
- Adding an agent to a chain uses `POST /api/v1/agent-instances` with existing `chain_id`, then selects the resulting `agent_instance_id`.

## 6. Agent hierarchy

```text
AgentListPage
  AgentSearchFilter
  AgentCardList
  CreateAgentButton

AgentDetailPage
  AgentHeader
    EditAgentButton
    ArchiveAgentButton
  AgentTabs
    OverviewTab
      InstructionsSummary
      DefaultProviderTier
      BridgeSupportCounts
    SessionsTab
      LaunchInstanceButton
      SessionRow(agent_instance_id)
      RuntimeRestartControls
    BridgesTab
      AgentBridgeSupportTable
      ProviderTierOverrideControls
    MemoryTab
      AgentMemoryList
      PendingProposalActions
```

Agent page rules:
- Agent identity is durable and project-agnostic.
- Sessions are restartable `AgentInstance` records and each has exactly one bound `ChatConversation`.
- Launching from agent detail without a `chain_id` creates a private/default chain + conversation and navigates to the conversation.

## 7. Library and Artifact viewer hierarchy

```text
LibraryPage
  LibraryToolbar
    SearchInput
    KindFilter
    AgentFilter
    ProjectFilter
    SecondaryChainTaskFilters
    UploadButton
    GridListToggle
  ArtifactCollection
    ArtifactCard
    ArtifactRow
    PaginationLoadMore
  ArtifactViewerOverlay
    ViewerHeader
      Breadcrumb
      RenameDescriptionControls
      DownloadButton
      DeleteButton
      CloseButton
    MetadataStrip
    KindAwareBody
      MarkdownTextJsonDiffViewer
      ImageZoomPanViewer
      BinaryFallback
    VersionPanel
      VersionSelector
      RollbackAction
    AnnotationPanel
      AnnotationList
      DesktopAnnotationCreate
```

The conversation inspector `ArtifactsTab` reuses list/viewer primitives but scopes queries to the active conversation. The top-level Library scopes to all artifacts and exposes filters.

## 8. Settings hierarchy

```text
SettingsSurface
  SettingsNav
    Bridges
    Projects
    Providers
    Memory
    DefaultsDevDebug
  BridgesSection
    BridgeList
    BridgeEnrollmentModal
    BridgeDetail
      RenameBridge
      CapabilityList
      InstanceList
      ProjectPathOverrides
      RevokeBridgeAction
  ProjectsSection
    ProjectList
    ProjectDetail
      MetadataEditor
      DefaultPathEditor
      BridgePathOverrideRows
      ValidatePathAction
      UsedBySummary
  ProvidersSection
    BridgeCapabilityReports
    ProviderDefaults
    ReadOnlyProfileInspection
    RefreshCapabilitiesAction
  MemorySection
    GlobalMemoryList
    ProposalDecisionActions
  DefaultsDevDebugSection
    DefaultAgents
    DaemonConnection
    DebugToggles
```

Desktop renders Settings as a modal/overlay. Mobile renders it fullscreen, while preserving route IDs and debug IDs.

## 9. Command palette hierarchy

```text
CommandPaletteOverlay
  PaletteInput
  ResultGroups
    NavigateResults
    ConversationResults
    AgentResults
    ChainResults
    ProjectResults
    ArtifactResults
    ActionResults
  ActionRunner
```

Entrypoints:
- desktop Cmd/Ctrl-K;
- sidebar Search item;
- mobile bottom tab bar center button.

Command palette actions open the same route/modal owners listed above. It does not introduce separate detail views.

## 10. Responsive/mobile collapse ownership

| Desktop layout | Mobile owner/collapse |
|---|---|
| Expanded/collapsed sidebar | `MobileSidebarDrawer`; primary destinations in `MobileBottomTabBar`. |
| Conversation + inspector | `ConversationInspector` becomes bottom sheet with segmented tabs. |
| Composer + CurrentTaskStrip | Same component; CurrentTaskStrip collapses to one-line above keyboard-aware input. |
| Chain list + detail side-by-side | `ChainPage` switches to list screen → task detail drill-down. |
| Library grid/list + viewer | 1–2 column list; filters in sheet; viewer fullscreen. |
| Settings modal | Fullscreen settings route/screen. |
| Command palette | Fullscreen/center sheet opened by bottom center button. |

Mobile constraints apply to all route owners:
- touch targets >= 44px;
- safe-area and keyboard-aware composer/comment surfaces;
- layout-independent `data-debug-id` names;
- no desktop-only route that blocks Tier-1 chat, artifact viewing, or task commenting.

## 11. Removed / not-ported legacy route and surface inventory

The current codebase still contains legacy implementation surfaces that are refactor sources only. The rewrite route map above replaces them rather than keeping them hidden.

| Legacy route/surface | Current inventory | Rewrite disposition |
|---|---|---|
| `/workspace` | `src/ui/components/workspace/routes.ts` `workspace_home` | Remove; `/conversations` is the default authenticated daily surface. |
| `/workspace/conversations/:agentInstanceId` | `workspace/routes.ts` `conversation` | Replace with `/conversations/:conversation_id`; route by conversation id, not workspace agent route. |
| `/workspace/agents/:agentInstanceId` | `workspace/routes.ts` `agent` | Replace with `/agents/:agent_id`; sessions list links to conversations. |
| `/workspace/chains/:chainId/coordinator` | `workspace/routes.ts` `chain_coordinator` | Replace with `/chains/:chain_id`; coordinator chat is linked out, not embedded workspace. |
| `/workspace/chains/:chainId/tasks/:taskId` | `workspace/routes.ts` `task` | Replace with `/chains/:chain_id/tasks/:task_id`. |
| `/workspace/projects/:projectId` | `workspace/routes.ts` `project` | Replace with Settings → Projects detail and project filters/chips. |
| `/workspace/artifacts/:artifactId` | `workspace/routes.ts` `artifact` | Replace with `/library/artifacts/:artifact_id` viewer route. |
| Global workspace shell/inspector | `UnifiedWorkspaceShell`, `WorkspaceLeftSidebar`, `WorkspaceMainRegion`, `ContextInspector`, `GenericAgentWorkspacePage` | Do not port as shell infrastructure; page-owned panels only. |
| Guide panel | `GuideSidePanel`, guide chat/debug controls in `App.tsx` | Remove; no guide panel in v1. |
| Standalone Attention surface/global badge | `Attention` rendering in `App.tsx`, `attentionSlice`, attention endpoints where unused | Remove; use per-surface unread/review badges and command palette. |
| Standalone Memory page | `MemoryManagementPage.tsx` | Remove as top-level; memory appears in conversation inspector, agent detail, and Settings. |
| Proxy/federation wizard | `NewLocalProxyAgentWizard.tsx`, remote proxy UI branches | Do not port; out of v1. |
| Vim/global edit sidebar | `VimSidebar.tsx` | Do not port as a global component. |
| Old ChainEditor graph/dependency editing | `ChainEditor.tsx` | Do not port until backend graph/dependency editing is approved. |
| Home/onboarding hero dashboard | `homeSlice` hero/onboarding assumptions, `OnboardingWizard.tsx` | Replace with conversation home/new conversation and settings-first setup surfaces. |
| Global right sidebar/evidence panel | `GlobalRightSidebar` in `App.tsx` | Replace with ConversationInspector, Chain task detail, and ArtifactViewer page-owned surfaces. |

## 12. Later task traceability

| Later UI task | Route/component owners from this doc |
|---|---|
| UI-1 App shell | `AuthenticatedShell`, `SidebarRegion`, `MainRouteOutlet`, `MobileShell` |
| UI-2 Auth states | `AuthGate`, `UnauthenticatedLanding`, auth redirect/logout config |
| UI-3 Sidebar tree | `ProjectConversationTree`, `ProjectGroup`, `AgentGroup`, `SessionRow` |
| UI-4 Conversation launch | `/conversations/new`, `LaunchControls`, `AdvancedBridgeProviderTierControls` |
| UI-5 Composer attachments/mentions | `ChatComposerShell`, `AttachmentUploadTray`, `MentionAutocomplete` |
| UI-6 Task chain in chat | `ConversationHeader`, `WorkChip`, `ReviewNeededChip`, `CurrentTaskStrip`, `WorkTab` |
| UI-7 Conversation inspector | `ConversationInspector` tabs |
| UI-8 Chain view | `/chains/:chain_id`, `ChainTaskLayout`, `TaskDetailPane` |
| UI-9 Agent detail | `/agents/:agent_id`, `AgentTabs` |
| UI-10 Library/artifact viewer | `/library`, `/library/artifacts/:artifact_id`, `ArtifactViewerOverlay` |
| UI-11 Settings | `/settings/*`, `SettingsSurface` sections |
| UI-12 Command palette | `CommandPaletteOverlay` and action/result groups |
| UI-13 Responsive/mobile | `MobileShell`, `MobileBottomTabBar`, drawers/sheets/drill-down modes |
| UI-14 Data layer + WS | `heimdallApi` endpoint modules and `UserWsProvider`/`wsInvalidation` |
| UI-15 Legacy cleanup | Removed/not-ported inventory in §11 |

## 13. Known gaps for UI-17 follow-up

These are intentionally not resolved in UI-16 and are analyzed in `ui-backend-gap-analysis.md` (UI-17):

- exact frontend route implementation choice (hash routing vs browser routing) and migration policy for old `/workspace` deep links;
- backend support for unread rollup summaries by project/agent/session;
- availability of public UI bootstrap/config endpoint for login/logout URLs;
- exact endpoint shapes for conversation summaries grouped by project → `agent_id` → session;
- any missing artifact annotation create/update/delete endpoints versus viewer scope;
- whether settings provider-profile inspection has enough structured fields in Bridge capability reports.
