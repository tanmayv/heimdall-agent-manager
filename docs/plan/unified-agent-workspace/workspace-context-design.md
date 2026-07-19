# WorkspaceContext adapter and route mapping design

Task: `task-19f794ac4f7`

Inputs:
- `docs/plan/unified-agent-workspace/README.md`
- `docs/plan/unified-agent-workspace/current-state-inventory.md`
- current routing/render flow in `src/ui/components/App.tsx`

This design defines the normalized route/context layer for the unified workspace shell and the single generic agent page contract that must serve conversation, direct-agent, and chain-coordinator contexts.

## 1. Design goals

This task covers:

- required `/workspace/...` route mapping for UAW-3;
- one normalized `WorkspaceContext` shape for UAW-5;
- data/capability-driven inspector tab visibility for UAW-6;
- debug-id preservation/migration rules for UAW-8;
- reuse of existing daemon-backed queries/state for UAW-10;
- one generic agent page component contract for UAW-11.

Non-goal: full shell implementation.

## 2. Canonical route family

## 2.1 Route grammar

```ts
type WorkspaceRoute =
  | { kind: 'workspace_home' }
  | { kind: 'conversation'; agentInstanceId: string }
  | { kind: 'agent'; agentInstanceId: string }
  | { kind: 'chain_coordinator'; chainId: string }
  | { kind: 'task'; chainId: string; taskId: string }
  | { kind: 'project'; projectId: string }
  | { kind: 'artifact'; artifactId: string };
```

Canonical paths:

| Route kind | Path |
|---|---|
| `workspace_home` | `/workspace` |
| `conversation` | `/workspace/conversations/:agentInstanceId` |
| `agent` | `/workspace/agents/:agentInstanceId` |
| `chain_coordinator` | `/workspace/chains/:chainId/coordinator` |
| `task` | `/workspace/chains/:chainId/tasks/:taskId` |
| `project` | `/workspace/projects/:projectId` |
| `artifact` | `/workspace/artifacts/:artifactId` |

## 2.2 Legacy entry projection

The new shell should become canonical, but current query-param entry points can project into it until cleanup is complete.

| Current entry | Projection rule |
|---|---|
| `view=agent&agentId=:id` | look up agent instance; if `isConversationAgent(agent)` then project to `/workspace/conversations/:id`, else `/workspace/agents/:id` |
| `view=chain&chainId=:id` | project to `/workspace/chains/:id/coordinator` |
| `view=chain&chainId=:id&taskId=:taskId` | project to `/workspace/chains/:id/tasks/:taskId` |
| `view=new-conversation` | project to `/workspace` plus create/start conversation affordance state, not a separate page layout |
| existing artifact open actions | project to `/workspace/artifacts/:artifactId` or open artifact viewer in the shell main region/modal |

## 2.3 Route parsing split

Route handling should be split into two phases:

1. **location parsing**: URL/path -> `WorkspaceRoute`
2. **context adaptation**: `WorkspaceRoute` + existing daemon-backed data -> `WorkspaceContext`

That keeps routing independent from query-fetch logic.

## 3. Normalization pipeline

```text
URL / legacy query params
  -> parseWorkspaceRoute()
  -> select existing daemon-backed entities from App/query/store
  -> adaptWorkspaceContext(route, sources)
  -> <UnifiedWorkspaceShell context={context}>
       -> left sidebar
       -> main content outlet
       -> context inspector tabs
```

The shell should branch on:
- `context.surfaceKind`
- `context.capabilities`
- presence/absence of data

It should not branch on old page names like `ConversationThreadPage` or `AgentDetailPage`.

## 4. Normalized context model

## 4.1 Core route/context shape

```ts
type WorkspaceSurfaceKind =
  | 'generic_agent'
  | 'task_detail'
  | 'project_overview'
  | 'artifact_viewer';

type WorkspaceContextRouteKind =
  | 'conversation'
  | 'agent'
  | 'chain_coordinator'
  | 'task'
  | 'project'
  | 'artifact';

type WorkspaceInspectorTabId =
  | 'tasks'
  | 'task_chains'
  | 'chain_agents'
  | 'artifacts'
  | 'vcs'
  | 'project'
  | 'memory'
  | 'runtime';

type WorkspaceCapabilities = {
  canChat: boolean;
  canNudge: boolean;
  canInterrupt: boolean;
  canUploadArtifact: boolean;
  canChangeRuntime: boolean;
  canShowTasks: boolean;
  canShowTaskChains: boolean;
  canShowChainAgents: boolean;
  canShowArtifacts: boolean;
  canShowVcs: boolean;
  canShowProject: boolean;
  canShowMemory: boolean;
  canShowRuntime: boolean;
};

type WorkspaceIdentityRef = {
  agentInstanceId?: string;
  durableAgentId?: string;
  chainId?: string;
  taskId?: string;
  projectId?: string;
  artifactId?: string;
};

type WorkspaceDebugPlan = {
  shellPrefix: 'workspace';
  inspectorTabPrefix: 'workspace-inspector-tab';
  inspectorPanelPrefix: 'workspace-inspector-panel';
  genericAgent?: WorkspaceGenericAgentDebugPlan;
};

type WorkspaceContext = {
  routeKind: WorkspaceContextRouteKind;
  surfaceKind: WorkspaceSurfaceKind;
  ids: WorkspaceIdentityRef;
  title: string;
  subtitle?: string;
  breadcrumbLabel?: string;
  statusLabel?: string;
  projectName?: string;
  capabilities: WorkspaceCapabilities;
  visibleInspectorTabs: WorkspaceInspectorTabId[];
  genericAgent?: WorkspaceSelectedAgentContext;
  taskDetail?: WorkspaceTaskContext;
  project?: WorkspaceProjectContext;
  artifact?: WorkspaceArtifactContext;
  debug: WorkspaceDebugPlan;
};
```

## 4.2 Single normalized selected-agent object for UAW-11

Coordinator, conversation, and direct-agent routes must all adapt to the same selected-agent shape.

```ts
type WorkspaceSelectedAgentContext = {
  agentPageKind: 'conversation' | 'direct_agent' | 'chain_coordinator';
  agentInstanceId: string;
  durableAgentId: string;
  displayName: string;
  title: string;
  subtitle: string;
  projectId?: string;
  projectName?: string;
  chainId?: string;
  chainTitle?: string;
  runtime: {
    status: 'active' | 'idle' | 'starting' | 'stopped' | 'unknown';
    statusLabel: string;
    provider: string;
    modelTier: string;
    projectId?: string;
    canStart: boolean;
    canStop: boolean;
    canRestart: boolean;
  };
  chat: {
    conversationKey: string;
    emptyText: string;
    sendMode: 'message' | 'nudge' | 'coordinator_message';
    supportsNudge: boolean;
    supportsInterrupt: boolean;
    supportsExactResumeCopy: boolean;
  };
  related: {
    taskIds: string[];
    chainIds: string[];
    artifactProjectId?: string;
  };
  capabilities: WorkspaceCapabilities;
  debug: WorkspaceGenericAgentDebugPlan;
};
```

### Why this shape

This is the key UAW-11 contract:

- `ConversationThreadPage`, `AgentDetailPage`, and `ChainView` coordinator chat collapse into one `GenericAgentWorkspacePage`.
- The generic page receives one `WorkspaceSelectedAgentContext`, not page-specific props.
- Differences between conversation/direct/coordinator are represented as data and capabilities, not separate layouts.

## 4.3 Non-agent contexts

```ts
type WorkspaceTaskContext = {
  chainId: string;
  taskId: string;
  title: string;
  subtitle?: string;
  projectId?: string;
  selectedTaskIds: string[];
};

type WorkspaceProjectContext = {
  projectId: string;
  projectName: string;
  subtitle?: string;
};

type WorkspaceArtifactContext = {
  artifactId: string;
  title: string;
  projectId?: string;
};
```

## 5. Generic agent page contract

The required shared agent page component should be explicit:

```ts
type GenericAgentWorkspacePageProps = {
  context: WorkspaceSelectedAgentContext;
  messages: ChatMessage[];
  pagination: {
    hasMore: boolean;
    loading: boolean;
    onLoadOlder?: () => void;
  };
  composer: {
    draft: string;
    onDraftChange: (value: string) => void;
    onSubmit: () => Promise<void> | void;
    onPaste?: (event: any) => Promise<void> | void;
    sendDisabled: boolean;
    sendError?: string;
  };
  actions: {
    onRefreshChat?: () => void;
    onStart?: () => void;
    onStop?: () => void;
    onRestartRuntime?: (next: { provider: string; modelTier: string; projectId: string }) => Promise<void> | void;
    onToggleInspector?: () => void;
  };
};
```

### Rendering rules

The component must always render the same core structure:

```text
<GenericAgentWorkspacePage>
  <ChatHeader />
  <ChatMessageList />
  <ChatWorkBanner />
  <ChatComposer />
</GenericAgentWorkspacePage>
```

Differences by route kind are limited to:

- header title/subtitle/status/action labels;
- message empty text;
- whether nudge/interrupt controls are shown;
- whether runtime controls are enabled;
- which inspector tabs are visible;
- which debug-prefix set applies.

### Explicitly forbidden by UAW-11

- separate `ConversationThreadPage` chat layout;
- separate `AgentDetailPage` chat-first layout;
- separate `ChainView` coordinator-chat layout.

Those pages can survive temporarily as wrappers that adapt to `GenericAgentWorkspacePage`, but they must not remain distinct layout systems.

## 6. Route-kind adapter outputs

## 6.1 Conversation adapter

```ts
adaptConversationWorkspaceContext({
  agent,
  conversationSummary,
  chats,
  projects,
}): WorkspaceContext
```

Outputs:
- `routeKind: 'conversation'`
- `surfaceKind: 'generic_agent'`
- `genericAgent.agentPageKind: 'conversation'`
- `capabilities.canChat = true`
- `capabilities.canNudge = false`
- `capabilities.canInterrupt = false`
- `capabilities.canShowMemory = true` only if durable identity memory is relevant
- visible tabs usually: `artifacts`, `project`, `runtime`, optionally `tasks`/`task_chains` when linked work exists

## 6.2 Direct-agent adapter

```ts
adaptDirectAgentWorkspaceContext({
  agent,
  tasksById,
  chainsById,
  applicableMemory,
  projects,
}): WorkspaceContext
```

Outputs:
- `routeKind: 'agent'`
- `surfaceKind: 'generic_agent'`
- `genericAgent.agentPageKind: 'direct_agent'`
- `capabilities.canChat = true`
- `capabilities.canNudge = true`
- `capabilities.canInterrupt = true` if direct-agent interrupt/nudge behavior is retained
- visible tabs usually: `tasks`, `task_chains`, `artifacts`, `project`, `memory`, `runtime`

## 6.3 Chain-coordinator adapter

```ts
adaptChainCoordinatorWorkspaceContext({
  chain,
  coordinatorAgent,
  tasks,
  workspace,
  team,
  projects,
}): WorkspaceContext
```

Outputs:
- `routeKind: 'chain_coordinator'`
- `surfaceKind: 'generic_agent'`
- `genericAgent.agentPageKind: 'chain_coordinator'`
- `capabilities.canChat = true`
- `capabilities.canNudge = false` at the composer level unless coordinator flow intentionally supports it
- `capabilities.canShowTasks = true`
- `capabilities.canShowTaskChains = true`
- `capabilities.canShowChainAgents = true`
- `capabilities.canShowArtifacts = true`
- `capabilities.canShowVcs = hasWorkspace`
- `capabilities.canShowProject = true`
- `capabilities.canShowRuntime = true`

## 6.4 Task adapter

```ts
adaptTaskWorkspaceContext({ task, chain, workspace, team, projects }): WorkspaceContext
```

Outputs:
- `routeKind: 'task'`
- `surfaceKind: 'task_detail'`
- task content in main region
- chain/project/workspace/task relationships exposed through inspector tabs

## 6.5 Project adapter

```ts
adaptProjectWorkspaceContext({ project, chains, agents, artifacts }): WorkspaceContext
```

Outputs:
- `routeKind: 'project'`
- `surfaceKind: 'project_overview'`

## 6.6 Artifact adapter

```ts
adaptArtifactWorkspaceContext({ artifact, project, chain, agent }): WorkspaceContext
```

Outputs:
- `routeKind: 'artifact'`
- `surfaceKind: 'artifact_viewer'`

## 7. Inspector tab derivation

Inspector tabs must be derived from capabilities/data, not hard-coded per page.

```ts
function deriveVisibleInspectorTabs(context: WorkspaceContext): WorkspaceInspectorTabId[] {
  const tabs: WorkspaceInspectorTabId[] = [];
  if (context.capabilities.canShowTasks) tabs.push('tasks');
  if (context.capabilities.canShowTaskChains) tabs.push('task_chains');
  if (context.capabilities.canShowChainAgents) tabs.push('chain_agents');
  if (context.capabilities.canShowArtifacts) tabs.push('artifacts');
  if (context.capabilities.canShowVcs) tabs.push('vcs');
  if (context.capabilities.canShowProject) tabs.push('project');
  if (context.capabilities.canShowMemory) tabs.push('memory');
  if (context.capabilities.canShowRuntime) tabs.push('runtime');
  return tabs;
}
```

### Tab rules by route kind

| Route kind | Expected tab baseline |
|---|---|
| conversation | `artifacts`, `project`, `runtime`, optional `tasks`/`task_chains` |
| agent | `tasks`, `task_chains`, `artifacts`, `project`, `memory`, `runtime` |
| chain_coordinator | `tasks`, `task_chains`, `chain_agents`, `artifacts`, `vcs`, `project`, `runtime` |
| task | `tasks`, `task_chains`, `chain_agents`, `artifacts`, `vcs`, `project`, `runtime` |
| project | `artifacts`, `vcs`, `project` |
| artifact | `artifacts`, optional `project`, optional `task_chains` |

## 8. Query ownership and source-of-truth plan

No new persisted UI state should be introduced for agents, chains, tasks, artifacts, memory, runtime, or VCS.

## 8.1 App-level query owner stays canonical

The existing `App.tsx` query layer already owns:
- agents and agent detail;
- conversation summaries and message caches;
- chains and chain detail;
- chain tasks and task logs;
- workspace/VCS/team data;
- projects/settings/providers;
- artifacts and memory queries.

The adapter layer should consume those existing results.

## 8.2 Adapter input bag

A single selector/input bundle is enough:

```ts
type WorkspaceDataSources = {
  agents: any[];
  chainsById: Record<string, any>;
  tasksById: Record<string, any>;
  projectsById: Record<string, any>;
  conversationSummaryById: Record<string, any>;
  chatsByAgentId: Record<string, any[]>;
  paginationByAgentId: Record<string, { cursor: number; hasMore: boolean; loading: boolean }>;
  workspacesByChainId: Record<string, any>;
  teamsByChainId: Record<string, any>;
  applicableMemoryByDurableAgentId?: Record<string, any[]>;
  settingsProviders: any[];
};
```

This keeps UAW-10 intact: the adapter layer is read-only over existing daemon-backed query/store data.

## 9. Debug-id preservation and migration plan

## 9.1 Preserve existing chat prefixes by route kind

The easiest UAW-8-compatible plan is to keep the existing namespaces as adapter output:

```ts
type WorkspaceGenericAgentDebugPlan = {
  headerPrefix: string;
  messageListPrefix: string;
  workBannerPrefix: string;
  composerPrefix: string;
  uploadPrefix: string;
  runtimePrefix: string;
  artifactsPrefix: string;
};
```

Mapping:

| Route kind | Prefixes to preserve |
|---|---|
| conversation | existing `conversationChatDebug` values |
| agent | existing `agentDetailChatDebug` values |
| chain_coordinator | existing `chainCoordinatorChatDebug` values |

That means the generic page can move into a new shell while still emitting the same leaf debug IDs for message list, composer, upload, runtime, and work-banner controls.

## 9.2 New shell/container IDs

New container IDs are acceptable where there is no current equivalent. Proposed additions:

- `workspace-shell`
- `workspace-left-sidebar`
- `workspace-main-region`
- `workspace-top-bar`
- `workspace-content-outlet`
- `workspace-inspector`
- `workspace-inspector-toggle-btn`
- `workspace-inspector-tab-<tabId>`
- `workspace-inspector-panel-<tabId>`

Rule: preserve existing leaf action IDs where possible; add new container IDs only for new shell structure.

## 9.3 Current page-only IDs to intentionally migrate

These should move into inspector/top-bar locations but keep their leaf semantics when feasible:

- `global-right-sidebar-*` -> `workspace-inspector-*` for VCS/artifacts containers
- `agent-detail-chat-sidebar-*` -> inspector `tasks` / `task_chains`
- `conversation-thread-artifacts-*` and `agent-detail-chat-artifacts-*` -> inspector `artifacts`
- `chain-task-*` / `task-detail-*` IDs remain valid when task controls move into the inspector task panel

## 10. Recommended file/module split for implementation tasks

The next implementation tasks should be able to land against small modules instead of growing `App.tsx` further.

Suggested split:

```text
src/ui/components/workspace/
  routes.ts                // parse/build canonical /workspace routes
  types.ts                 // WorkspaceRoute, WorkspaceContext, capabilities, tabs
  adapters.ts              // adaptConversation/Agent/Chain/Task/Project/Artifact
  debugPlan.ts             // maps route kinds to debug-prefix plans
  UnifiedWorkspaceShell.tsx
  GenericAgentWorkspacePage.tsx
  ContextInspector.tsx
```

And in `App.tsx`:
- keep current queries/selectors;
- replace page selection branches with route parse -> context adapt -> shell render;
- temporarily wrap legacy pages by projecting them into the new shell until dead code is removed.

## 11. Concrete mapping from today’s pages to the generic component

| Current page | Future surface | Adapter |
|---|---|---|
| `ConversationThreadPage` | `GenericAgentWorkspacePage` | `adaptConversationWorkspaceContext()` |
| `AgentDetailPage` chat area | `GenericAgentWorkspacePage` | `adaptDirectAgentWorkspaceContext()` |
| `ChainView` coordinator panel | `GenericAgentWorkspacePage` | `adaptChainCoordinatorWorkspaceContext()` |

This is the required UAW-11 convergence point.

## 12. Implementation notes for the next task

1. Add route parse/build helpers first so legacy query params can project into `/workspace/...` deterministically.
2. Extract the shared selected-agent/context adapter before touching layout.
3. Build `GenericAgentWorkspacePage` by reusing current `ChatHeader`, `ChatMessageList`, `ChatWorkBanner`, `ChatComposer`, `RuntimeRestartControls`, and artifact upload behavior.
4. Feed inspector tabs from `deriveVisibleInspectorTabs(context)` and move existing side-panel content into those panels.
5. Only after the generic page is rendering all three agent-like contexts should page-specific wrappers be removed.
