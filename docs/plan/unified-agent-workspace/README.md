# Unified Agent Workspace mockups

Goal: replace separate-looking coordinator, conversation, and direct-agent chat pages with one context-driven workspace shell. The selected item can be a conversation agent, durable/running agent instance, or a chain coordinator, but the layout and controls stay the same.

## Hard design requirements

1. There must be **one generic agent page component** for all agent-like contexts.
   - This single component must render coordinator chat, conversation chat, and direct agent chat.
   - Do not keep three visually distinct page components for these contexts.
   - Existing entry points may adapt/redirect into this component, but the visible page shell must be shared.

2. The component must be **context/data-driven**, not type-styled.
   - The UI should not branch into separate layouts because the context is `coordinator`, `conversation`, or `agent`.
   - It should receive a normalized agent/context object plus available related data.
   - Contextual panels/tabs appear only when the corresponding data/capability exists.

3. Coordinator, conversation, and direct-agent contexts must be visually indistinguishable except for data.
   - Same page shell.
   - Same top-bar zones.
   - Same chat panel.
   - Same composer/runtime/artifact controls.
   - Same collapsible context sidebar/tab system.
   - Differences should be limited to title, status, selected agent/context, and visible contextual tabs.

4. The right sidebar must describe **the selected agent/context**, not the page type.
   - If the selected context has task-chain data, show task-chain tabs.
   - If it has assigned/reviewer/coordinator tasks, show task tabs.
   - If it has VCS workspace data, show VCS.
   - If it has project/memory/artifact/runtime data, show those tabs.
   - If data is absent, hide the tab instead of showing empty page-type-specific chrome.

5. Build with existing Heimdall components/styles.
   - Recompose current components rather than introducing a new visual design language.
   - The implementation-faithful mockup is `mockups/existing-components.html`; the original `mockups/index.html` is layout concept only.

## Visual mockup

Open the self-contained concept mockup locally:

```text
docs/plan/unified-agent-workspace/mockups/index.html
```

Open the implementation-faithful mockup that reuses current Heimdall/Tailwind component styling:

```text
docs/plan/unified-agent-workspace/mockups/existing-components.html
```

Useful hash URLs in the concept mockup:

```text
mockups/index.html#/workspace/conversations/conversation@s-demo
mockups/index.html#/workspace/agents/coder@s-demo
mockups/index.html#/workspace/chains/chain-demo/coordinator
mockups/index.html#/workspace/chains/chain-demo/tasks/task-demo
```

The scenario buttons in the left sidebar update the same shell instead of loading different page designs.

## Proposed product routes

Canonical route family:

| Route | Purpose | Notes |
|---|---|---|
| `/workspace` | Default workspace; opens most recent selected conversation/agent/chain context. | Keeps the shell mounted. |
| `/workspace/conversations/:agentInstanceId` | Open an exact conversation instance in the unified shell. | Replaces visually distinct `ConversationThreadPage`. |
| `/workspace/agents/:agentInstanceId` | Open a direct agent chat in the unified shell. | Replaces visually distinct `AgentDetailPage` chat-first view. |
| `/workspace/agents/:agentId/instances/:agentInstanceId` | Optional identity + exact instance route when both durable and instance identity are needed. | Same shell, richer context. |
| `/workspace/chains/:chainId/coordinator` | Open the chain coordinator chat in the unified shell. | Replaces special `ChainView` coordinator-chat layout. |
| `/workspace/chains/:chainId/tasks/:taskId` | Open a task detail in center content, with chain context in inspector. | Same shell, main content switches from chat to task detail. |
| `/workspace/projects/:projectId` | Open project overview in center content. | Same shell; inspector shows project-related tabs. |
| `/workspace/artifacts/:artifactId` | Open artifact viewer in center content or modal-in-center. | Same shell; inspector can show versions/annotations/context. |

Legacy redirects/entry points should map into the shell:

| Existing entry | Redirect/projection |
|---|---|
| Agent detail chat | `/workspace/agents/:agentInstanceId` |
| Conversation thread | `/workspace/conversations/:agentInstanceId` |
| Chain coordinator panel | `/workspace/chains/:chainId/coordinator` |
| Task detail from chain | `/workspace/chains/:chainId/tasks/:taskId` |

## Component structure and nesting

```text
<App>
  <WorkspaceRouter>
    <UnifiedWorkspaceShell>
      <WorkspaceLeftSidebar>
        <WorkspaceSwitcher />
        <WorkspacePrimaryActions />
        <WorkspaceSearch />
        <ConversationList />
        <AgentList />
        <ChainList />
        <ProjectList />
      </WorkspaceLeftSidebar>

      <WorkspaceMainRegion>
        <WorkspaceTopBar>
          <ContextBreadcrumb />
          <ContextStatusChip />
          <ContextPrimaryActions />
        </WorkspaceTopBar>

        <WorkspaceContentOutlet>
          <UnifiedChatPanel context={ChatContext} />
          OR <TaskDetailPanel context={TaskContext} />
          OR <ProjectOverviewPanel context={ProjectContext} />
          OR <ArtifactViewerPanel context={ArtifactContext} />
        </WorkspaceContentOutlet>
      </WorkspaceMainRegion>

      <ContextInspector collapsed={...}>
        <InspectorTabRail tabs={visibleTabs} />
        <InspectorTabPanel id="tasks"><TasksPanel /></InspectorTabPanel>
        <InspectorTabPanel id="chains"><TaskChainsPanel /></InspectorTabPanel>
        <InspectorTabPanel id="agents"><ChainAgentsPanel /></InspectorTabPanel>
        <InspectorTabPanel id="artifacts"><ArtifactsPanel /></InspectorTabPanel>
        <InspectorTabPanel id="vcs"><VcsWorkspacePanel /></InspectorTabPanel>
        <InspectorTabPanel id="project"><ProjectPanel /></InspectorTabPanel>
        <InspectorTabPanel id="memory"><MemoryPanel /></InspectorTabPanel>
        <InspectorTabPanel id="runtime"><RuntimePanel /></InspectorTabPanel>
      </ContextInspector>
    </UnifiedWorkspaceShell>
  </WorkspaceRouter>
</App>
```

### Unified chat panel nesting

```text
<UnifiedChatPanel>
  <UnifiedChatHeader>
    <ContextAvatar />
    <ContextTitle />
    <ContextSubtitle />
    <RuntimeStateChip />
  </UnifiedChatHeader>

  <ChatMessageList />

  <ChatWorkBanner />

  <UnifiedChatComposer>
    <textarea />
    <ArtifactUploadButton />
    <RuntimeRestartControls />
    <SendModeToggle />        // normal / nudge / interrupt if supported
    <SendButton />
  </UnifiedChatComposer>
</UnifiedChatPanel>
```

## Context data model

All selected contexts should normalize to one shape before rendering:

```ts
type WorkspaceContext = {
  routeKind: 'conversation' | 'agent' | 'chain_coordinator' | 'task' | 'project' | 'artifact';
  title: string;
  subtitle?: string;
  primaryAgentInstanceId?: string;
  durableAgentId?: string;
  projectId?: string;
  chainId?: string;
  taskId?: string;
  artifactId?: string;
  workspaceId?: string;
  runtime?: {
    status: 'active' | 'idle' | 'starting' | 'stopped' | 'unknown';
    provider: string;
    modelTier: string;
    projectId?: string;
    canStart: boolean;
    canStop: boolean;
    canRestart: boolean;
  };
  capabilities: {
    canChat: boolean;
    canNudge: boolean;
    canUploadArtifact: boolean;
    canChangeRuntime: boolean;
    canShowTasks: boolean;
    canShowChains: boolean;
    canShowChainAgents: boolean;
    canShowArtifacts: boolean;
    canShowVcs: boolean;
    canShowProject: boolean;
    canShowMemory: boolean;
  };
};
```

The UI should not branch by page type for layout. It should branch only by context capabilities and available data.

## Inspector tab visibility rules

| Tab | Show when |
|---|---|
| Tasks | selected agent has assigned/reviewer/coordinator tasks, or selected chain has tasks. |
| Task chains | selected agent participates in chains, or selected context is chain/task. |
| Agents | selected context has a chain/team roster. |
| Artifacts | selected context has upload/list capability. |
| VCS | selected chain/project has a VCS workspace. |
| Project | selected context has a project. |
| Memory | selected context has durable agent/team/project memory scope. |
| Runtime | selected context has a runnable agent instance. |

## Controls parity

Every chat context should use the same visible control zones:

| Zone | Canonical controls |
|---|---|
| Left sidebar | new conversation, search, recent conversations, agents, chains, projects. |
| Top bar | breadcrumb, runtime state, refresh, start/stop, inspector collapse. |
| Composer | text input, artifact upload, provider, tier, project, restart/apply, send mode, send. |
| Inspector | tabs for related information, not page-specific lower cards. |

Controls can be disabled or hidden by capability, but placement should remain stable.

## Redundant information to remove/relocate

Move these out of page-specific locations and into canonical shell locations:

- Agent detail top cards for project/provider/runtime → inspector `Runtime`/`Project` tabs.
- Agent detail lower task lists → inspector `Tasks` tab.
- Conversation summary card → top bar title/subtitle plus inspector tabs.
- Coordinator task sidebar → inspector `Tasks`/`Task chains` tabs.
- Separate artifact side panels → inspector `Artifacts` tab, with composer upload kept as quick action.
- Repeated project chips/footer text → single breadcrumb/project tab; composer footer can be minimal.
- Duplicate Start buttons → one top-bar Start/Stop plus optional banner Start only when stopped, not both if too noisy.

## Implementation phases

1. Add static shell components with no behavior change: `UnifiedWorkspaceShell`, `WorkspaceLeftSidebar`, `WorkspaceMainRegion`, `ContextInspector`.
2. Add `WorkspaceContext` adapter functions for conversation, agent detail, and chain coordinator.
3. Render existing chat data through `UnifiedChatPanel` for all three contexts.
4. Move tasks/artifacts/project/memory/runtime details into `ContextInspector` tabs.
5. Redirect existing routes/page entry points to `/workspace/...` routes.
6. Remove redundant page-specific cards/sidebars once parity is validated.
7. Add screenshot/static tests proving the three contexts share the same shell and control placements.
