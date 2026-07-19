#!/usr/bin/env python3
"""Static validation for unified workspace shell routing, tabs, and migrations.

REQ coverage:
- UAW-1/UAW-2: shared shell + inspector primitives keep existing Heimdall styling/debug ids.
- UAW-3/UAW-5: workspace routes normalize through shared route/context helpers.
- UAW-6/UAW-7: inspector tabs are capability-driven and hold migrated context panels.
- UAW-8: migrated shell/inspector/task controls keep debug-id coverage.
- UAW-10/UAW-11: one generic agent page consumes normalized daemon-backed context.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
ADAPTERS = (ROOT / 'src/ui/components/workspace/adapters.ts').read_text(encoding='utf-8')
ROUTES = (ROOT / 'src/ui/components/workspace/routes.ts').read_text(encoding='utf-8')
URL_PARAMS = (ROOT / 'src/ui/components/useUrlParams.ts').read_text(encoding='utf-8')
INSPECTOR = (ROOT / 'src/ui/components/workspace/ContextInspector.tsx').read_text(encoding='utf-8')
LEFT_SIDEBAR = (ROOT / 'src/ui/components/workspace/WorkspaceLeftSidebar.tsx').read_text(encoding='utf-8')
MAIN_REGION = (ROOT / 'src/ui/components/workspace/WorkspaceMainRegion.tsx').read_text(encoding='utf-8')
GENERIC_PAGE = (ROOT / 'src/ui/components/workspace/GenericAgentWorkspacePage.tsx').read_text(encoding='utf-8')
SHELL = (ROOT / 'src/ui/components/workspace/UnifiedWorkspaceShell.tsx').read_text(encoding='utf-8')
AGENTS = (ROOT / 'AGENTS.md').read_text(encoding='utf-8')


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f'missing {label}: {snippet}')


def require_absent(text: str, snippet: str, label: str) -> None:
    if snippet in text:
        raise AssertionError(f'unexpected {label}: {snippet}')


def main() -> None:
    for snippet in [
        "className={`flex h-full min-h-0 ${className}`.trim()}",
        "w-[420px] border-l border-[#262626] p-4",
        'rounded-xl border border-white/[0.06] bg-black/30 p-1',
        "context.className || 'flex h-full min-h-0 flex-col bg-[#090909] text-zinc-100'",
        "context.bodyInnerClassName || 'mx-auto flex h-full max-w-[760px] flex-col'",
    ]:
        require(INSPECTOR + GENERIC_PAGE + SHELL + APP, snippet, 'existing visual-language composition')

    for snippet in [
        'data-debug-id="workspace-left-sidebar"',
        'data-debug-id="workspace-main-region"',
        'data-debug-id="workspace-top-bar"',
        'data-debug-id="workspace-content-outlet"',
        'data-debug-id="workspace-inspector"',
    ]:
        require(LEFT_SIDEBAR + MAIN_REGION + INSPECTOR, snippet, 'three-column shell primitives')

    for snippet in [
        "return { kind: 'conversation', agentInstanceId: parts[2] }",
        "return { kind: 'agent', agentInstanceId: parts[2] }",
        "return { kind: 'chain_coordinator', chainId: parts[2] }",
        "return { kind: 'task', chainId: parts[2], taskId: parts[4] }",
        "return `/workspace/conversations/${encodePathPart(route.agentInstanceId)}`;",
        "return `/workspace/agents/${encodePathPart(route.agentInstanceId)}`;",
        "return `/workspace/chains/${encodePathPart(route.chainId)}/coordinator`;",
        "return `/workspace/chains/${encodePathPart(route.chainId)}/tasks/${encodePathPart(route.taskId)}`;",
        'parseWorkspaceRoute(window.location.pathname)',
        'workspaceRouteToUrlState(route)',
        'urlStateToWorkspaceRoute(nextState)',
    ]:
        require(ROUTES + URL_PARAMS, snippet, 'workspace routing/projection')

    for snippet in [
        'if (capabilities.canShowTasks) tabs.push(\'tasks\')',
        'if (capabilities.canShowTaskChains) tabs.push(\'task-chains\')',
        'if (capabilities.canShowChainAgents) tabs.push(\'chain-agents\')',
        'if (capabilities.canShowArtifacts) tabs.push(\'artifacts\')',
        'if (capabilities.canShowVcs) tabs.push(\'vcs\')',
        'if (capabilities.canShowProject) tabs.push(\'project\')',
        'if (capabilities.canShowMemory) tabs.push(\'memory\')',
        'if (capabilities.canShowRuntime) tabs.push(\'runtime\')',
    ]:
        require(ADAPTERS, snippet, 'capability-driven inspector tabs')

    for snippet in [
        'content: <div className="space-y-4"><AgentTaskList',
        "content: <AgentChatSidebarContent agent={agent}",
        'content: <ChatArtifactsSidePanel embedded',
        'content: <AgentMemoryInspectorContent',
        '<ChainTasksInspectorContent',
        'content: <ChainAgentsInspectorContent',
        '<GlobalRightSidebar',
        'debugId: \'chain-project-name\'',
    ]:
        require(APP, snippet, 'migrated canonical inspector content')

    for snippet in [
        'buttonDebugId: \'workspace-inspector-tab-tasks\'',
        'buttonDebugId: \'workspace-inspector-tab-task-chains\'',
        'buttonDebugId: \'workspace-inspector-tab-chain-agents\'',
        'buttonDebugId: \'workspace-inspector-tab-artifacts\'',
        'buttonDebugId: \'workspace-inspector-tab-vcs\'',
        'buttonDebugId: \'workspace-inspector-tab-project\'',
        'buttonDebugId: \'workspace-inspector-tab-memory\'',
        'buttonDebugId: \'workspace-inspector-tab-runtime\'',
        'data-debug-id={`task-detail-status-block-btn-${task.taskId}`}',
        'data-debug-id={`task-detail-nudge-btn-${task.taskId}`}',
        'data-debug-id={`chain-agent-open-btn-${row.agentId}`}',
        'data-debug-id={`chain-agent-chat-btn-${row.agentId}`}',
    ]:
        require(APP, snippet, 'migrated debug-id coverage')

    for snippet in [
        '| `UnifiedWorkspaceShell` | `workspace-shell` |',
        '| `WorkspaceLeftSidebar` | `workspace-left-sidebar` |',
        '| `WorkspaceMainRegion` | `workspace-main-region`, `workspace-top-bar`, `workspace-content-outlet` |',
        '| `ContextInspector` | `workspace-inspector`, `workspace-inspector-toggle-btn`, `workspace-inspector-tabs`, `workspace-inspector-tab-${tabId}`, `workspace-inspector-panel-${tabId}`, `workspace-inspector-empty` |',
        '| `GenericAgentWorkspacePage` | `generic-agent-page`, `generic-agent-page-body`, `generic-agent-page-composer-region` |',
    ]:
        require(AGENTS, snippet, 'documented debug registry')

    for snippet in [
        'window.localStorage',
        'sessionStorage',
    ]:
        require_absent(ADAPTERS + ROUTES, snippet, 'competing persisted workspace state')

    print('PASS: unified workspace shell routes, capability tabs, migrated panels, and debug ids are statically wired')


if __name__ == '__main__':
    main()
