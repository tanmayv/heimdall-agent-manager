#!/usr/bin/env python3
"""Static contract checks for unified workspace chat reuse and debug wiring."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
ADAPTERS = (ROOT / 'src/ui/components/workspace/adapters.ts').read_text(encoding='utf-8')
GENERIC_PAGE = (ROOT / 'src/ui/components/workspace/GenericAgentWorkspacePage.tsx').read_text(encoding='utf-8')
SHELL = (ROOT / 'src/ui/components/workspace/UnifiedWorkspaceShell.tsx').read_text(encoding='utf-8')
INSPECTOR = (ROOT / 'src/ui/components/workspace/ContextInspector.tsx').read_text(encoding='utf-8')
TYPES = (ROOT / 'src/ui/components/workspace/types.ts').read_text(encoding='utf-8')
ROUTES = (ROOT / 'src/ui/components/workspace/routes.ts').read_text(encoding='utf-8')
DEBUG_PREFIXES = (ROOT / 'src/ui/components/chat/debugPrefixes.ts').read_text(encoding='utf-8')
AGENTS = (ROOT / 'AGENTS.md').read_text(encoding='utf-8')


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f'missing {label}: {snippet}')


def require_count(text: str, snippet: str, minimum: int, label: str) -> None:
    actual = text.count(snippet)
    if actual < minimum:
        raise AssertionError(f'missing {label}: expected at least {minimum}x {snippet!r}, found {actual}')


def main() -> None:
    for snippet in [
        "import GenericAgentWorkspacePage from './workspace/GenericAgentWorkspacePage';",
        "import UnifiedWorkspaceShell from './workspace/UnifiedWorkspaceShell';",
        "import WorkspaceLeftSidebar from './workspace/WorkspaceLeftSidebar';",
        "import WorkspaceMainRegion from './workspace/WorkspaceMainRegion';",
        "import ContextInspector from './workspace/ContextInspector';",
        "import { adaptChainCoordinatorWorkspaceContext, adaptConversationWorkspaceContext, adaptDirectAgentWorkspaceContext } from './workspace/adapters';",
    ]:
        require(APP, snippet, 'workspace shell imports')

    require_count(APP, '<GenericAgentWorkspacePage', 3, 'shared generic agent page usage')
    require_count(APP, '<UnifiedWorkspaceShell', 3, 'shared workspace shell usage')
    for snippet in [
        'workspaceInspectorTabsFor(detailWorkspaceContext',
        'workspaceInspectorTabsFor(conversationWorkspaceContext',
        'workspaceInspectorTabsFor(coordinatorWorkspaceContext',
        'detailWorkspaceContext.genericAgent!',
        'conversationWorkspaceContext.genericAgent!',
        'coordinatorWorkspaceContext.genericAgent!',
    ]:
        require(APP, snippet, 'normalized workspace context consumption')

    for snippet in [
        "import ChatHeader from '../chat/ChatHeader';",
        "import ChatMessageList from '../chat/ChatMessageList';",
        "import ChatWorkBanner from '../chat/ChatWorkBanner';",
        "import ChatComposer from '../chat/ChatComposer';",
        '<ChatHeader {...context.header} />',
        '<ChatMessageList {...context.chat} />',
        '{context.workBanner ? <ChatWorkBanner {...context.workBanner} /> : null}',
        '{context.composer ? <ChatComposer {...context.composer} /> : null}',
        'data-debug-id="generic-agent-page"',
        'data-debug-id="generic-agent-page-body"',
        'data-debug-id="generic-agent-page-composer-region"',
    ]:
        require(GENERIC_PAGE, snippet, 'generic page shared chat primitives')

    for snippet in [
        'data-debug-id="workspace-shell"',
        'data-inspector-collapsed={inspectorCollapsed ? \'true\' : \'false\'}',
    ]:
        require(SHELL, snippet, 'workspace shell debug ids')

    for snippet in [
        'data-debug-id="workspace-inspector"',
        'data-debug-id="workspace-inspector-toggle-btn"',
        'data-debug-id="workspace-inspector-tabs"',
        'workspace-inspector-tab-${tab.id}',
        'workspace-inspector-panel-${activeTab.id}',
        'data-debug-id="workspace-inspector-empty"',
    ]:
        require(INSPECTOR, snippet, 'inspector debug ids')

    for snippet in [
        "import { agentDetailChatDebug, chainCoordinatorChatDebug, conversationChatDebug } from '../chat/debugPrefixes';",
        "surfaceKind: 'generic_agent'",
        "routeKind: 'conversation'",
        "routeKind: 'agent'",
        "routeKind: 'chain_coordinator'",
        'visibleInspectorTabs: visibleInspectorTabs(capabilities)',
        'debug: debugPlan(conversationChatDebug)',
        'debug: debugPlan(agentDetailChatDebug)',
        'debug: debugPlan(chainCoordinatorChatDebug)',
        'canShowTasks: false',
        'canShowTasks: true',
        'canShowChainAgents: true',
        'canShowMemory: true',
        'canShowRuntime: true',
    ]:
        require(ADAPTERS, snippet, 'workspace adapter normalization')

    for snippet in [
        "messageList: 'chain-coordinator'",
        "composer: 'chain-coordinator'",
        "messageList: 'conversation-thread'",
        "composer: 'conversation-composer'",
        "messageList: 'agent-detail-chat'",
        "composer: 'agent-detail-chat'",
    ]:
        require(DEBUG_PREFIXES, snippet, 'chat debug prefix registry')

    for snippet in [
        "shellDebugId: detailAgentContext.debug.composerPrefix + '-composer-shell'",
        "shellDebugId: conversationAgentContext.debug.composerPrefix + '-shell'",
        "shellDebugId: coordinatorAgentContext.debug.composerPrefix + '-composer-shell'",
        'debugPrefix: detailAgentContext.debug.messageListPrefix',
        'debugPrefix: conversationAgentContext.debug.messageListPrefix',
        'debugPrefix: coordinatorAgentContext.debug.messageListPrefix',
        'debugPrefix: detailAgentContext.debug.workBannerPrefix',
        'debugPrefix: conversationAgentContext.debug.workBannerPrefix',
        'debugPrefix: coordinatorAgentContext.debug.workBannerPrefix',
        'runtimeControls: { debugPrefix: detailAgentContext.debug.runtimePrefix',
        'runtimeControls: { debugPrefix: conversationAgentContext.debug.runtimePrefix',
        'runtimeControls: { debugPrefix: coordinatorAgentContext.debug.runtimePrefix',
    ]:
        require(APP, snippet, 'per-surface debug wiring')

    for snippet in [
        "export type WorkspaceRouteKind = 'workspace_home' | 'conversation' | 'agent' | 'chain_coordinator' | 'task' | 'project' | 'artifact';",
        "export type WorkspaceSurfaceKind = 'workspace_home' | 'generic_agent' | 'task_detail' | 'project_overview' | 'artifact_viewer';",
        'export type WorkspaceCapabilities = {',
        'export type WorkspaceContext = {',
        'genericAgent?: WorkspaceSelectedAgentContext;',
    ]:
        require(TYPES, snippet, 'workspace types')

    for snippet in [
        "return `/workspace/conversations/${encodePathPart(route.agentInstanceId)}`;",
        "return `/workspace/agents/${encodePathPart(route.agentInstanceId)}`;",
        "return `/workspace/chains/${encodePathPart(route.chainId)}/coordinator`;",
        "return `/workspace/chains/${encodePathPart(route.chainId)}/tasks/${encodePathPart(route.taskId)}`;",
        "if (parts[1] === 'conversations' && parts[2]) return { kind: 'conversation', agentInstanceId: parts[2] };",
        "if (parts[1] === 'agents' && parts[2]) return { kind: 'agent', agentInstanceId: parts[2] };",
        "if (parts[1] === 'chains' && parts[2] && parts[3] === 'coordinator') return { kind: 'chain_coordinator', chainId: parts[2] };",
        "if (parts[1] === 'chains' && parts[2] && parts[3] === 'tasks' && parts[4]) return { kind: 'task', chainId: parts[2], taskId: parts[4] };",
    ]:
        require(ROUTES, snippet, 'workspace routes')

    for debug_id in [
        'workspace-shell',
        'workspace-left-sidebar',
        'workspace-main-region',
        'workspace-top-bar',
        'workspace-content-outlet',
        'workspace-inspector',
        'workspace-inspector-toggle-btn',
        'workspace-inspector-tabs',
        'generic-agent-page',
        'chain-agent-open-btn-${agentId}',
        'chain-agent-chat-btn-${agentId}',
    ]:
        require(AGENTS, debug_id, 'debug id registry')

    print('PASS: unified workspace chat surfaces share one generic page, one shell, and one debug-prefix contract')


if __name__ == '__main__':
    main()
